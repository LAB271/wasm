//! Leg A: Full TCP server in WASM using wasi:sockets.
//!
//! Phase 2: Uses embedded SQLite (via rusqlite with bundled feature).
//! Phase 3: Supports full CRUD operations (GET/POST/PUT/DELETE).
//!
//! This demonstrates the "WASM owns the socket" model — the guest module
//! binds, listens, accepts, reads, and writes directly.
//!
//! Requires: WASI SDK installed at /opt/wasi-sdk (for SQLite C compilation)

use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::net::{TcpListener, TcpStream};
use std::sync::Mutex;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Record {
    id: u32,
    name: String,
    email: String,
    department: String,
}

#[derive(Debug, Deserialize)]
struct RecordInput {
    name: String,
    email: String,
    department: String,
}

struct Database {
    conn: Mutex<Connection>,
}

impl Database {
    fn new() -> Self {
        let conn = Connection::open_in_memory().expect("Failed to open SQLite in memory");

        conn.execute(
            "CREATE TABLE IF NOT EXISTS records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                name TEXT NOT NULL,
                email TEXT NOT NULL,
                department TEXT NOT NULL
            )",
            [],
        )
        .expect("Failed to create table");

        Database {
            conn: Mutex::new(conn),
        }
    }

    fn load_csv(&self, csv_content: &str) {
        let conn = self.conn.lock().unwrap();
        for line in csv_content.lines().skip(1) {
            let parts: Vec<&str> = line.split(',').collect();
            if parts.len() >= 4 {
                if let Ok(id) = parts[0].parse::<i64>() {
                    let _ = conn.execute(
                        "INSERT OR REPLACE INTO records (id, name, email, department) VALUES (?1, ?2, ?3, ?4)",
                        params![id, parts[1], parts[2], parts[3]],
                    );
                }
            }
        }
    }

    fn all(&self) -> Vec<Record> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare("SELECT id, name, email, department FROM records ORDER BY id")
            .unwrap();
        let rows = stmt
            .query_map([], |row| {
                Ok(Record {
                    id: row.get::<_, i64>(0)? as u32,
                    name: row.get(1)?,
                    email: row.get(2)?,
                    department: row.get(3)?,
                })
            })
            .unwrap();
        rows.filter_map(|r| r.ok()).collect()
    }

    fn get(&self, id: u32) -> Option<Record> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(
            "SELECT id, name, email, department FROM records WHERE id = ?1",
            params![id as i64],
            |row| {
                Ok(Record {
                    id: row.get::<_, i64>(0)? as u32,
                    name: row.get(1)?,
                    email: row.get(2)?,
                    department: row.get(3)?,
                })
            },
        )
        .ok()
    }

    fn create(&self, input: &RecordInput) -> Option<Record> {
        let conn = self.conn.lock().unwrap();
        conn.execute(
            "INSERT INTO records (name, email, department) VALUES (?1, ?2, ?3)",
            params![&input.name, &input.email, &input.department],
        )
        .ok()?;
        let id = conn.last_insert_rowid() as u32;
        Some(Record {
            id,
            name: input.name.clone(),
            email: input.email.clone(),
            department: input.department.clone(),
        })
    }

    fn update(&self, id: u32, input: &RecordInput) -> Option<Record> {
        let conn = self.conn.lock().unwrap();
        let rows = conn
            .execute(
                "UPDATE records SET name = ?1, email = ?2, department = ?3 WHERE id = ?4",
                params![&input.name, &input.email, &input.department, id as i64],
            )
            .unwrap_or(0);
        if rows > 0 {
            Some(Record {
                id,
                name: input.name.clone(),
                email: input.email.clone(),
                department: input.department.clone(),
            })
        } else {
            None
        }
    }

    fn delete(&self, id: u32) -> bool {
        let conn = self.conn.lock().unwrap();
        let rows = conn
            .execute("DELETE FROM records WHERE id = ?1", params![id as i64])
            .unwrap_or(0);
        rows > 0
    }

    fn count(&self) -> usize {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT COUNT(*) FROM records", [], |row| {
            row.get::<_, i64>(0)
        })
        .unwrap_or(0) as usize
    }
}

fn load_csv() -> String {
    let path = std::env::var("CSV_PATH").unwrap_or_else(|_| "data/records.csv".to_string());
    std::fs::read_to_string(&path).unwrap_or_else(|e| {
        eprintln!("Failed to load {}: {}", path, e);
        "id,name,email,department\n".to_string()
    })
}

fn parse_body(request: &str) -> Option<&str> {
    if let Some(idx) = request.find("\r\n\r\n") {
        let body = &request[idx + 4..];
        if !body.is_empty() {
            return Some(body);
        }
    }
    None
}

fn handle_request(db: &Database, request: &str) -> (u16, &'static str, String) {
    let first_line = request.lines().next().unwrap_or("");
    let parts: Vec<&str> = first_line.split_whitespace().collect();

    if parts.len() < 2 {
        return (400, "Bad Request", r#"{"error":"invalid request"}"#.to_string());
    }

    let method = parts[0];
    let path = parts[1];

    match (method, path) {
        ("GET", "/health") => (200, "OK", r#"{"status":"ok","db":"sqlite"}"#.to_string()),

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
                            serde_json::to_string(&record).unwrap_or_else(|_| "{}".to_string());
                        (200, "OK", json)
                    }
                    None => (404, "Not Found", r#"{"error":"not found"}"#.to_string()),
                },
                Err(_) => (400, "Bad Request", r#"{"error":"invalid id"}"#.to_string()),
            }
        }

        ("POST", "/records") => {
            if let Some(body) = parse_body(request) {
                match serde_json::from_str::<RecordInput>(body) {
                    Ok(input) => match db.create(&input) {
                        Some(record) => {
                            let json =
                                serde_json::to_string(&record).unwrap_or_else(|_| "{}".to_string());
                            (201, "Created", json)
                        }
                        None => (
                            500,
                            "Internal Server Error",
                            r#"{"error":"insert failed"}"#.to_string(),
                        ),
                    },
                    Err(_) => (400, "Bad Request", r#"{"error":"invalid json"}"#.to_string()),
                }
            } else {
                (400, "Bad Request", r#"{"error":"missing body"}"#.to_string())
            }
        }

        ("PUT", path) if path.starts_with("/records/") => {
            let id_str = path.trim_start_matches("/records/");
            match id_str.parse::<u32>() {
                Ok(id) => {
                    if let Some(body) = parse_body(request) {
                        match serde_json::from_str::<RecordInput>(body) {
                            Ok(input) => match db.update(id, &input) {
                                Some(record) => {
                                    let json = serde_json::to_string(&record)
                                        .unwrap_or_else(|_| "{}".to_string());
                                    (200, "OK", json)
                                }
                                None => {
                                    (404, "Not Found", r#"{"error":"not found"}"#.to_string())
                                }
                            },
                            Err(_) => {
                                (400, "Bad Request", r#"{"error":"invalid json"}"#.to_string())
                            }
                        }
                    } else {
                        (400, "Bad Request", r#"{"error":"missing body"}"#.to_string())
                    }
                }
                Err(_) => (400, "Bad Request", r#"{"error":"invalid id"}"#.to_string()),
            }
        }

        ("DELETE", path) if path.starts_with("/records/") => {
            let id_str = path.trim_start_matches("/records/");
            match id_str.parse::<u32>() {
                Ok(id) => {
                    if db.delete(id) {
                        (204, "No Content", String::new())
                    } else {
                        (404, "Not Found", r#"{"error":"not found"}"#.to_string())
                    }
                }
                Err(_) => (400, "Bad Request", r#"{"error":"invalid id"}"#.to_string()),
            }
        }

        _ => (404, "Not Found", r#"{"error":"not found"}"#.to_string()),
    }
}

fn handle_connection(db: &Database, mut stream: TcpStream) {
    let mut buf = [0u8; 8192];
    let mut request = String::new();

    match std::io::Read::read(&mut stream, &mut buf) {
        Ok(n) if n > 0 => {
            if let Ok(s) = std::str::from_utf8(&buf[..n]) {
                request = s.to_string();
            }
        }
        _ => return,
    }

    let (status, status_text, body) = handle_request(db, &request);

    let response = if body.is_empty() {
        format!(
            "HTTP/1.1 {} {}\r\n\
             Connection: close\r\n\
             \r\n",
            status, status_text
        )
    } else {
        format!(
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
        )
    };

    let _ = stream.write_all(response.as_bytes());
    let _ = stream.flush();
}

#[no_mangle]
pub extern "C" fn _start() {
    eprintln!("Initializing SQLite database...");
    let db = Database::new();

    let csv = load_csv();
    db.load_csv(&csv);
    eprintln!("Loaded {} records into SQLite", db.count());

    let addr = "0.0.0.0:8080";
    let listener = match TcpListener::bind(addr) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("Failed to bind {}: {}", addr, e);
            return;
        }
    };
    eprintln!("Listening on {}", addr);

    for stream in listener.incoming() {
        match stream {
            Ok(s) => handle_connection(&db, s),
            Err(e) => eprintln!("Accept error: {}", e),
        }
    }
}
