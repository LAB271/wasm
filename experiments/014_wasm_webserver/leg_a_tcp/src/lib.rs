//! Leg A: Full TCP server in WASM using wasi:sockets.
//!
//! This demonstrates the "WASM owns the socket" model — the guest module
//! binds, listens, accepts, reads, and writes directly. The host runtime
//! (wasmtime) provides the wasi:sockets capability.
//!
//! Note: wasi:sockets in preview2 is still maturing. This implementation
//! uses the synchronous blocking API for simplicity.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Record {
    id: u32,
    name: String,
    email: String,
    department: String,
}

struct Database {
    records: HashMap<u32, Record>,
}

impl Database {
    fn from_csv(csv_content: &str) -> Self {
        let mut records = HashMap::new();
        for line in csv_content.lines().skip(1) {
            // skip header
            let parts: Vec<&str> = line.split(',').collect();
            if parts.len() >= 4 {
                if let Ok(id) = parts[0].parse::<u32>() {
                    records.insert(
                        id,
                        Record {
                            id,
                            name: parts[1].to_string(),
                            email: parts[2].to_string(),
                            department: parts[3].to_string(),
                        },
                    );
                }
            }
        }
        Database { records }
    }

    fn all(&self) -> Vec<&Record> {
        let mut v: Vec<_> = self.records.values().collect();
        v.sort_by_key(|r| r.id);
        v
    }

    fn get(&self, id: u32) -> Option<&Record> {
        self.records.get(&id)
    }
}

fn load_csv() -> String {
    // Read from env var or default path
    let path = std::env::var("CSV_PATH").unwrap_or_else(|_| "data/records.csv".to_string());
    std::fs::read_to_string(&path).unwrap_or_else(|e| {
        eprintln!("Failed to load {}: {}", path, e);
        // Return minimal CSV so server can still start
        "id,name,email,department\n".to_string()
    })
}

fn handle_request(db: &Database, request: &str) -> (u16, &'static str, String) {
    // Parse the request line
    let first_line = request.lines().next().unwrap_or("");
    let parts: Vec<&str> = first_line.split_whitespace().collect();

    if parts.len() < 2 {
        return (400, "Bad Request", r#"{"error":"invalid request"}"#.to_string());
    }

    let method = parts[0];
    let path = parts[1];

    match (method, path) {
        ("GET", "/health") => (200, "OK", r#"{"status":"ok"}"#.to_string()),

        ("GET", "/records") => {
            let records = db.all();
            let json = serde_json::to_string(&records).unwrap_or_else(|_| "[]".to_string());
            (200, "OK", json)
        }

        ("GET", path) if path.starts_with("/records/") => {
            let id_str = path.trim_start_matches("/records/");
            match id_str.parse::<u32>() {
                Ok(id) => match db.get(id) {
                    Some(record) => {
                        let json =
                            serde_json::to_string(record).unwrap_or_else(|_| "{}".to_string());
                        (200, "OK", json)
                    }
                    None => (404, "Not Found", r#"{"error":"not found"}"#.to_string()),
                },
                Err(_) => (400, "Bad Request", r#"{"error":"invalid id"}"#.to_string()),
            }
        }

        _ => (404, "Not Found", r#"{"error":"not found"}"#.to_string()),
    }
}

fn handle_connection(db: &Database, mut stream: TcpStream) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut request = String::new();

    // Read headers (until blank line)
    loop {
        let mut line = String::new();
        match reader.read_line(&mut line) {
            Ok(0) => break,
            Ok(_) => {
                if line == "\r\n" || line == "\n" {
                    break;
                }
                request.push_str(&line);
            }
            Err(_) => break,
        }
    }

    let (status, status_text, body) = handle_request(db, &request);

    let response = format!(
        "HTTP/1.1 {} {}\r\n\
         Content-Type: application/json\r\n\
         Content-Length: {}\r\n\
         Connection: close\r\n\
         \r\n\
         {}",
        status,
        status_text,
        body.len(),
        body
    );

    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

#[no_mangle]
pub extern "C" fn _start() {
    // Load data
    let csv = load_csv();
    let db = Database::from_csv(&csv);
    eprintln!("Loaded {} records", db.records.len());

    // Bind and listen
    let addr = "0.0.0.0:8080";
    let listener = match TcpListener::bind(addr) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("Failed to bind {}: {}", addr, e);
            return;
        }
    };
    eprintln!("Listening on {}", addr);

    // Accept loop
    for stream in listener.incoming() {
        match stream {
            Ok(s) => handle_connection(&db, s),
            Err(e) => eprintln!("Accept error: {}", e),
        }
    }
}
