//! pg_host — Rust host that embeds wasmtime and provides Postgres access
//! via host imports. No HTTP sidecar, no IPC — direct function calls.
//!
//! The guest WASM module imports functions like `db_query_all`, `db_insert`, etc.
//! The host implements these by calling postgres (sync).
//!
//! Architecture:
//!   ┌─────────────┐  host   ┌─────────────┐  pg wire  ┌─────────────┐
//!   │ WASM Guest  │────────▶│  Rust Host  │──────────▶│  Postgres   │
//!   │ (wasmtime)  │ imports │  (this)     │           │  (Podman)   │
//!   └─────────────┘         └─────────────┘           └─────────────┘

use postgres::{Client, NoTls};
use serde::{Deserialize, Serialize};
use std::sync::{Arc, Mutex};
use std::time::Instant;
use wasmtime::*;

const WASM_PATH: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../guest/target/wasm32-unknown-unknown/release/pg_guest.wasm"
);

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Record {
    id: i32,
    name: String,
    email: String,
    department: String,
}

/// Host state shared with WASM via Linker
struct HostState {
    /// Buffer for returning data to WASM (JSON-encoded for simplicity)
    result_buffer: Vec<u8>,
}

impl HostState {
    fn new() -> Self {
        Self {
            result_buffer: Vec::new(),
        }
    }
}

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("--test");

    // Connect to Postgres (sync)
    let conn_str = std::env::var("DATABASE_URL")
        .unwrap_or_else(|_| "host=localhost user=postgres password=secret dbname=postgres".into());

    let mut client = Client::connect(&conn_str, NoTls).expect("Failed to connect to Postgres");

    // Initialize schema
    init_schema(&mut client)?;

    // Wrap client for shared access (Arc+Mutex for Send+Sync)
    let client_arc = Arc::new(Mutex::new(client));

    // Create wasmtime engine and module
    let engine = Engine::default();
    let module = Module::from_file(&engine, WASM_PATH).expect("Failed to load WASM module");

    // Create store with host state
    let state = HostState::new();
    let mut store = Store::new(&engine, state);

    // Create linker with host functions
    let mut linker = Linker::new(&engine);
    add_host_functions(&mut linker, client_arc)?;

    // Instantiate
    let instance = linker.instantiate(&mut store, &module)?;

    match mode {
        "--test" => {
            println!("Running CRUD test via WASM...\n");
            run_crud_test(&mut store, &instance)?;
        }
        "--benchmark" => {
            let n: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(100);
            run_benchmark(&mut store, &instance, n)?;
        }
        _ => {
            eprintln!("Usage: pg_host [--test | --benchmark N]");
        }
    }

    Ok(())
}

fn init_schema(client: &mut Client) -> Result<()> {
    client
        .execute(
            "CREATE TABLE IF NOT EXISTS records (
                id SERIAL PRIMARY KEY,
                name TEXT NOT NULL,
                email TEXT NOT NULL,
                department TEXT NOT NULL
            )",
            &[],
        )
        .map_err(|e| anyhow::anyhow!("Schema init failed: {}", e))?;

    // Clear and seed
    client.execute("DELETE FROM records", &[]).ok();
    client
        .execute(
            "INSERT INTO records (name, email, department) VALUES
             ('Alice', 'alice@example.com', 'Engineering'),
             ('Bob', 'bob@example.com', 'Marketing'),
             ('Carol', 'carol@example.com', 'Engineering')",
            &[],
        )
        .ok();

    println!("Schema initialized with 3 seed records");
    Ok(())
}

fn add_host_functions(linker: &mut Linker<HostState>, client: Arc<Mutex<Client>>) -> Result<()> {
    let client_query = client.clone();
    // db_query_all() -> length of JSON result
    linker.func_wrap(
        "env",
        "db_query_all",
        move |mut caller: Caller<'_, HostState>| -> i32 {
            let mut client = client_query.lock().unwrap();
            let rows = client
                .query(
                    "SELECT id, name, email, department FROM records ORDER BY id",
                    &[],
                )
                .unwrap_or_default();

            let records: Vec<Record> = rows
                .iter()
                .map(|row| Record {
                    id: row.get(0),
                    name: row.get(1),
                    email: row.get(2),
                    department: row.get(3),
                })
                .collect();

            let json = serde_json::to_vec(&records).unwrap_or_default();
            let len = json.len() as i32;
            caller.data_mut().result_buffer = json;
            len
        },
    )?;

    // db_get_result(dest_ptr) -> copies result to dest_ptr, returns len
    linker.func_wrap(
        "env",
        "db_get_result",
        |mut caller: Caller<'_, HostState>, dest_ptr: i32| -> i32 {
            let data = caller.data().result_buffer.clone();
            let memory = caller.get_export("memory").unwrap().into_memory().unwrap();
            memory
                .write(&mut caller, dest_ptr as usize, &data)
                .expect("Failed to write to WASM memory");
            data.len() as i32
        },
    )?;

    let client_insert = client.clone();
    // db_insert(name_ptr, name_len, email_ptr, email_len, dept_ptr, dept_len) -> id
    linker.func_wrap(
        "env",
        "db_insert",
        move |mut caller: Caller<'_, HostState>,
              name_ptr: i32,
              name_len: i32,
              email_ptr: i32,
              email_len: i32,
              dept_ptr: i32,
              dept_len: i32|
              -> i32 {
            let memory = caller.get_export("memory").unwrap().into_memory().unwrap();
            let data = memory.data(&caller);

            let name =
                std::str::from_utf8(&data[name_ptr as usize..(name_ptr + name_len) as usize])
                    .unwrap_or("")
                    .to_string();
            let email =
                std::str::from_utf8(&data[email_ptr as usize..(email_ptr + email_len) as usize])
                    .unwrap_or("")
                    .to_string();
            let dept =
                std::str::from_utf8(&data[dept_ptr as usize..(dept_ptr + dept_len) as usize])
                    .unwrap_or("")
                    .to_string();

            let mut client = client_insert.lock().unwrap();
            let row = client.query_one(
                "INSERT INTO records (name, email, department) VALUES ($1, $2, $3) RETURNING id",
                &[&name, &email, &dept],
            );

            match row {
                Ok(row) => row.get::<_, i32>(0),
                Err(_) => -1,
            }
        },
    )?;

    let client_delete = client.clone();
    // db_delete(id) -> 1 if deleted, 0 if not found
    linker.func_wrap(
        "env",
        "db_delete",
        move |_caller: Caller<'_, HostState>, id: i32| -> i32 {
            let mut client = client_delete.lock().unwrap();
            let result = client.execute("DELETE FROM records WHERE id = $1", &[&id]);

            match result {
                Ok(n) => n as i32,
                Err(_) => 0,
            }
        },
    )?;

    let client_count = client.clone();
    // db_count() -> number of records
    linker.func_wrap(
        "env",
        "db_count",
        move |_caller: Caller<'_, HostState>| -> i32 {
            let mut client = client_count.lock().unwrap();
            let row = client.query_one("SELECT COUNT(*) FROM records", &[]);

            match row {
                Ok(row) => row.get::<_, i64>(0) as i32,
                Err(_) => -1,
            }
        },
    )?;

    Ok(())
}

fn run_crud_test(store: &mut Store<HostState>, instance: &Instance) -> Result<()> {
    // Get exported functions from WASM guest
    let test_crud = instance
        .get_typed_func::<(), i32>(&mut *store, "test_crud")
        .expect("test_crud not found");

    let t0 = Instant::now();
    let result = test_crud.call(&mut *store, ())?;
    let elapsed = t0.elapsed();

    println!("test_crud returned: {} (0 = success)", result);
    println!("Total time: {:?}", elapsed);

    if result == 0 {
        println!("\n✓ All CRUD operations passed!");
    } else {
        println!("\n✗ Test failed with code: {}", result);
        println!("  1 = initial count != 3");
        println!("  2 = insert failed");
        println!("  3 = count after insert != 4");
        println!("  4 = query_all failed");
        println!("  5 = get_result copy mismatch");
        println!("  6 = delete failed");
        println!("  7 = count after delete != 3");
    }

    Ok(())
}

fn run_benchmark(store: &mut Store<HostState>, instance: &Instance, n: usize) -> Result<()> {
    let benchmark_query = instance
        .get_typed_func::<i32, i32>(&mut *store, "benchmark_query")
        .expect("benchmark_query not found");

    println!("Running {} iterations of query benchmark...", n);
    println!("(Each iteration: WASM calls host -> host queries Postgres -> returns to WASM)\n");

    let mut times_us: Vec<u128> = Vec::with_capacity(n);
    for _ in 0..n {
        let t0 = Instant::now();
        let _ = benchmark_query.call(&mut *store, 1)?;
        times_us.push(t0.elapsed().as_micros());
    }

    let mut sorted = times_us.clone();
    sorted.sort_unstable();

    let min = sorted[0];
    let median = sorted[sorted.len() / 2];
    let p99 = sorted[(sorted.len() as f64 * 0.99) as usize];
    let max = *sorted.last().unwrap();
    let avg: u128 = sorted.iter().sum::<u128>() / sorted.len() as u128;

    println!("Results (microseconds):");
    println!("  min:    {}μs", min);
    println!("  median: {}μs", median);
    println!("  avg:    {}μs", avg);
    println!("  p99:    {}μs", p99);
    println!("  max:    {}μs", max);

    Ok(())
}
