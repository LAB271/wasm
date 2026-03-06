use wasi::clocks::wall_clock;
use wasi::exports::wasi::http::incoming_handler::Guest;
use wasi::http::types::{Fields, IncomingRequest, OutgoingBody, OutgoingResponse, ResponseOutparam};

struct Component;

impl Guest for Component {
    fn handle(_request: IncomingRequest, response_out: ResponseOutparam) {
        let now = wall_clock::now();
        let ts = now.seconds as f64 + (now.nanoseconds as f64 / 1_000_000_000.0);
        let body_str = format!(r#"{{"message":"Hello World","timestamp":{ts:.6}}}"#);

        let headers = Fields::new();
        headers
            .append(&"content-type".to_string(), &b"application/json".to_vec())
            .unwrap();

        let response = OutgoingResponse::new(headers);
        response.set_status_code(200).unwrap();

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
}

wasi::http::proxy::export!(Component with_types_in wasi);
