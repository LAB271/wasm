//! Leg B: Serverless HTTP handler using Spin SDK.
//!
//! Phase 3: Supports full CRUD operations (GET/POST/PUT/DELETE).
//!
//! This demonstrates the "host owns the socket" model — the guest module
//! only implements a request→response handler. Spin manages TCP, TLS, routing.
//!
//! Note: In serverless model, state doesn't persist between requests unless
//! you use Spin's key-value store or an external database. For this demo,
//! we reload CSV on each request (suitable for read-heavy workloads).

use serde::{Deserialize, Serialize};
use spin_sdk::http::{IntoResponse, Request, Response};
use spin_sdk::http_component;
use std::collections::HashMap;

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
    records: HashMap<u32, Record>,
    next_id: u32,
}

impl Database {
    fn from_csv(csv_content: &str) -> Self {
        let mut records = HashMap::new();
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
        Database {
            records,
            next_id: max_id + 1,
        }
    }

    fn all(&self) -> Vec<&Record> {
        let mut v: Vec<_> = self.records.values().collect();
        v.sort_by_key(|r| r.id);
        v
    }

    fn get(&self, id: u32) -> Option<&Record> {
        self.records.get(&id)
    }

    fn create(&mut self, input: &RecordInput) -> Record {
        let id = self.next_id;
        self.next_id += 1;
        let record = Record {
            id,
            name: input.name.clone(),
            email: input.email.clone(),
            department: input.department.clone(),
        };
        self.records.insert(id, record.clone());
        record
    }

    fn update(&mut self, id: u32, input: &RecordInput) -> Option<Record> {
        if self.records.contains_key(&id) {
            let record = Record {
                id,
                name: input.name.clone(),
                email: input.email.clone(),
                department: input.department.clone(),
            };
            self.records.insert(id, record.clone());
            Some(record)
        } else {
            None
        }
    }

    fn delete(&mut self, id: u32) -> bool {
        self.records.remove(&id).is_some()
    }
}

fn load_csv() -> String {
    std::fs::read_to_string("/records.csv").unwrap_or_else(|_| {
        std::fs::read_to_string("data/records.csv")
            .unwrap_or_else(|_| "id,name,email,department\n".to_string())
    })
}

fn json_response(status: u16, body: &str) -> Response {
    Response::builder()
        .status(status)
        .header("content-type", "application/json")
        .body(body.to_string())
        .build()
}

fn empty_response(status: u16) -> Response {
    Response::builder().status(status).body(()).build()
}

/// The HTTP handler entrypoint.
#[http_component]
fn handle_request(req: Request) -> anyhow::Result<impl IntoResponse> {
    // Load data on each request (stateless model)
    // Note: For writes to persist, use Spin's key-value store or external DB
    let csv = load_csv();
    let mut db = Database::from_csv(&csv);

    let path = req.path();
    let method = req.method().to_string();

    let response = match (method.as_str(), path) {
        // Health check
        ("GET", "/health") => json_response(200, r#"{"status":"ok"}"#),

        // List all records
        ("GET", "/records") => {
            let records = db.all();
            let json = serde_json::to_string(&records).unwrap_or_else(|_| "[]".to_string());
            json_response(200, &json)
        }

        // Get single record
        ("GET", path) if path.starts_with("/records/") => {
            let id_str = path.trim_start_matches("/records/");
            match id_str.parse::<u32>() {
                Ok(id) => match db.get(id) {
                    Some(record) => {
                        let json =
                            serde_json::to_string(record).unwrap_or_else(|_| "{}".to_string());
                        json_response(200, &json)
                    }
                    None => json_response(404, r#"{"error":"not found"}"#),
                },
                Err(_) => json_response(400, r#"{"error":"invalid id"}"#),
            }
        }

        // Create new record (POST /records)
        ("POST", "/records") => {
            let body = req.body();
            if body.is_empty() {
                json_response(400, r#"{"error":"missing body"}"#)
            } else {
                match serde_json::from_slice::<RecordInput>(body) {
                    Ok(input) => {
                        let record = db.create(&input);
                        // Note: This create won't persist in serverless model!
                        // In production, write to Spin KV store or external DB
                        let json =
                            serde_json::to_string(&record).unwrap_or_else(|_| "{}".to_string());
                        json_response(201, &json)
                    }
                    Err(_) => json_response(400, r#"{"error":"invalid json"}"#),
                }
            }
        }

        // Update existing record (PUT /records/:id)
        ("PUT", path) if path.starts_with("/records/") => {
            let id_str = path.trim_start_matches("/records/");
            match id_str.parse::<u32>() {
                Ok(id) => {
                    let body = req.body();
                    if body.is_empty() {
                        json_response(400, r#"{"error":"missing body"}"#)
                    } else {
                        match serde_json::from_slice::<RecordInput>(body) {
                            Ok(input) => match db.update(id, &input) {
                                Some(record) => {
                                    let json = serde_json::to_string(&record)
                                        .unwrap_or_else(|_| "{}".to_string());
                                    json_response(200, &json)
                                }
                                None => json_response(404, r#"{"error":"not found"}"#),
                            },
                            Err(_) => json_response(400, r#"{"error":"invalid json"}"#),
                        }
                    }
                }
                Err(_) => json_response(400, r#"{"error":"invalid id"}"#),
            }
        }

        // Delete record (DELETE /records/:id)
        ("DELETE", path) if path.starts_with("/records/") => {
            let id_str = path.trim_start_matches("/records/");
            match id_str.parse::<u32>() {
                Ok(id) => {
                    if db.delete(id) {
                        // Note: This delete won't persist in serverless model!
                        empty_response(204)
                    } else {
                        json_response(404, r#"{"error":"not found"}"#)
                    }
                }
                Err(_) => json_response(400, r#"{"error":"invalid id"}"#),
            }
        }

        _ => json_response(404, r#"{"error":"not found"}"#),
    };

    Ok(response)
}
