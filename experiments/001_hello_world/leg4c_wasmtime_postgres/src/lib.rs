use wasi::clocks::wall_clock;
use wasi::exports::wasi::http::incoming_handler::Guest;
use wasi::http::outgoing_handler;
use wasi::http::types::{
    Fields, IncomingRequest, Method, OutgoingBody, OutgoingRequest, OutgoingResponse,
    ResponseOutparam, Scheme,
};

struct Component;

const SIDECAR_PORT: u16 = 5007;

impl Guest for Component {
    fn handle(request: IncomingRequest, response_out: ResponseOutparam) {
        let path = request.path_with_query().unwrap_or_default();

        if path.starts_with("/db") {
            handle_db(&path, response_out);
        } else {
            let now = wall_clock::now();
            let ts = now.seconds as f64 + (now.nanoseconds as f64 / 1_000_000_000.0);
            let body_str = format!(
                r#"{{"message":"Hello from leg4c (Rust/Wasmtime + Postgres via sidecar)","timestamp":{ts:.6}}}"#
            );
            send_response(response_out, 200, &body_str);
        }
    }
}

fn handle_db(path: &str, response_out: ResponseOutparam) {
    let sidecar_url = format!("/query{}", path.strip_prefix("/db").unwrap_or(""));

    let outgoing = OutgoingRequest::new(Fields::new());
    outgoing.set_method(&Method::Get).unwrap();
    outgoing.set_scheme(Some(&Scheme::Http)).unwrap();
    outgoing
        .set_authority(Some(&format!("127.0.0.1:{SIDECAR_PORT}")))
        .unwrap();
    outgoing.set_path_with_query(Some(&sidecar_url)).unwrap();

    let out_body = outgoing.body().unwrap();
    OutgoingBody::finish(out_body, None).unwrap();

    let future_resp = outgoing_handler::handle(outgoing, None).unwrap();
    let pollable = future_resp.subscribe();
    pollable.block();

    let resp_option = future_resp
        .get()
        .expect("future already taken")
        .expect("request failed")
        .expect("HTTP error from sidecar");
    let status = resp_option.status();
    let resp_body = resp_option.consume().unwrap();
    let stream = resp_body.stream().unwrap();

    let mut body_bytes = Vec::new();
    loop {
        match stream.read(64 * 1024) {
            Ok(chunk) => {
                if chunk.is_empty() {
                    break;
                }
                body_bytes.extend_from_slice(&chunk);
            }
            Err(_) => break,
        }
    }
    drop(stream);

    let now = wall_clock::now();
    let ts = now.seconds as f64 + (now.nanoseconds as f64 / 1_000_000_000.0);

    let sidecar_json = String::from_utf8_lossy(&body_bytes);

    // Inject timestamp into the sidecar response.
    // Assumes sidecar returns flat JSON (no nested objects) so rfind('}') is safe.
    let body_str = if status == 200 {
        if let Some(pos) = sidecar_json.rfind('}') {
            format!("{},\"timestamp\":{ts:.6}}}", &sidecar_json[..pos])
        } else {
            sidecar_json.to_string()
        }
    } else {
        sidecar_json.to_string()
    };

    send_response(response_out, status, &body_str);
}

fn send_response(response_out: ResponseOutparam, status: u16, body_str: &str) {
    let headers = Fields::new();
    headers
        .append(&"content-type".to_string(), &b"application/json".to_vec())
        .unwrap();

    let response = OutgoingResponse::new(headers);
    response.set_status_code(status).unwrap();

    let out_body = response.body().unwrap();
    {
        let stream = out_body.write().unwrap();
        stream
            .blocking_write_and_flush(body_str.as_bytes())
            .unwrap();
    }
    OutgoingBody::finish(out_body, None).unwrap();
    ResponseOutparam::set(response_out, Ok(response));
}

wasi::http::proxy::export!(Component with_types_in wasi);
