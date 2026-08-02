//! Leg A: Full TCP server in WASM using wasi:sockets.
//!
//! Phase 3: Supports full CRUD operations (GET/POST/PUT/DELETE).
//!
//! Note: Phase 2 (SQLite) deferred — WASM SQLite crates are still maturing
//! for wasip2. The HashMap-based approach works for this experiment.
//!
//! This demonstrates the "WASM owns the socket" model — the guest module
//! binds, listens, accepts, reads, and writes directly.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
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
    records: Mutex<HashMap<u32, Record>>,
    next_id: Mutex<u32>,
}

impl Database {
    fn new() -> Self {
        Database {
            records: Mutex::new(HashMap::new()),
            next_id: Mutex::new(1),
        }
    }

    fn load_csv(&self, csv_content: &str) {
        let mut records = self.records.lock().unwrap();
        let mut next_id = self.next_id.lock().unwrap();
        let mut max_id = 0u32;

        for line in csv_content.lines().skip(1) {
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
                    if id > max_id {
                        max_id = id;
                    }
                }
            }
        }
        *next_id = max_id + 1;
    }

    fn all(&self) -> Vec<Record> {
        let records = self.records.lock().unwrap();
        let mut v: Vec<_> = records.values().cloned().collect();
        v.sort_by_key(|r| r.id);
        v
    }

    fn get(&self, id: u32) -> Option<Record> {
        let records = self.records.lock().unwrap();
        records.get(&id).cloned()
    }

    fn create(&self, input: &RecordInput) -> Record {
        let mut records = self.records.lock().unwrap();
        let mut next_id = self.next_id.lock().unwrap();

        let id = *next_id;
        *next_id += 1;

        let record = Record {
            id,
            name: input.name.clone(),
            email: input.email.clone(),
            department: input.department.clone(),
        };
        records.insert(id, record.clone());
        record
    }

    fn update(&self, id: u32, input: &RecordInput) -> Option<Record> {
        let mut records = self.records.lock().unwrap();
        if records.contains_key(&id) {
            let record = Record {
                id,
                name: input.name.clone(),
                email: input.email.clone(),
                department: input.department.clone(),
            };
            records.insert(id, record.clone());
            Some(record)
        } else {
            None
        }
    }

    fn delete(&self, id: u32) -> bool {
        let mut records = self.records.lock().unwrap();
        records.remove(&id).is_some()
    }

    fn count(&self) -> usize {
        let records = self.records.lock().unwrap();
        records.len()
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
        // Health check
        ("GET", "/health") => (200, "OK", r#"{"status":"ok"}"#.to_string()),

        // List all records
        ("GET", "/records") => {
            let records = db.all();
            let json = serde_json::to_string(&records).unwrap_or_else(|_| "[]".to_string());
            (200, "OK", json)
        }

        // Get single record
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

        // Create new record (POST /records)
        ("POST", "/records") => {
            if let Some(body) = parse_body(request) {
                match serde_json::from_str::<RecordInput>(body) {
                    Ok(input) => {
                        let record = db.create(&input);
                        let json =
                            serde_json::to_string(&record).unwrap_or_else(|_| "{}".to_string());
                        (201, "Created", json)
                    }
                    Err(_) => (400, "Bad Request", r#"{"error":"invalid json"}"#.to_string()),
                }
            } else {
                (400, "Bad Request", r#"{"error":"missing body"}"#.to_string())
            }
        }

        // Update existing record (PUT /records/:id)
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

        // Delete record (DELETE /records/:id)
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
    let mut buf = [0u8; 8192]; // Larger buffer for POST bodies
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
    // Initialize database
    let db = Database::new();

    // Load initial data from CSV
    let csv = load_csv();
    db.load_csv(&csv);
    eprintln!("Loaded {} records", db.count());

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
