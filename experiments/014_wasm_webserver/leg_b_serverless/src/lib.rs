//! Leg B: Serverless HTTP handler using Spin SDK.
//!
//! This demonstrates the "host owns the socket" model — the guest module
//! only implements a request→response handler. Spin (or any wasi:http host)
//! manages TCP, TLS, routing, and connection lifecycle.
//!
//! Benefits:
//! - Simpler code (no socket management)
//! - Host can optimize (connection pooling, keep-alive, TLS termination)
//! - Portable across Spin, Cloudflare Workers, Fastly Compute, etc.

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

struct Database {
    records: HashMap<u32, Record>,
}

impl Database {
    fn from_csv(csv_content: &str) -> Self {
        let mut records = HashMap::new();
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
    // Spin mounts files from spin.toml [component.api.files]
    // The data directory is mounted at /
    std::fs::read_to_string("/records.csv").unwrap_or_else(|_| {
        // Fallback: try relative path for local dev
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

/// The HTTP handler entrypoint.
/// Spin calls this for every incoming request matching our route.
#[http_component]
fn handle_request(req: Request) -> anyhow::Result<impl IntoResponse> {
    // Load data on each request (stateless model)
    // In production, you'd use Spin's key-value store or external DB
    let csv = load_csv();
    let db = Database::from_csv(&csv);

    let path = req.path();
    let method = req.method().to_string();

    let response = match (method.as_str(), path) {
        ("GET", "/health") => json_response(200, r#"{"status":"ok"}"#),

        ("GET", "/records") => {
            let records = db.all();
            let json = serde_json::to_string(&records).unwrap_or_else(|_| "[]".to_string());
            json_response(200, &json)
        }

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

        _ => json_response(404, r#"{"error":"not found"}"#),
    };

    Ok(response)
}
