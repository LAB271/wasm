//! Fastly Compute via Fastly's OWN SDK — the supported path.
//!
//! Contrast with portability leg 4: the portable wasi:http component cannot run
//! on Viceroy at all, because Viceroy implements no `wasi:http` at any version.
//! Its ABI is `fastly:compute/*`, and this is what targeting that looks like.
//! Same observable behaviour, entirely different interface — and NOT the same
//! bytes, which is exactly the point.
use fastly::{Error, Request, Response};

#[fastly::main]
fn main(_req: Request) -> Result<Response, Error> {
    Ok(Response::from_status(200).with_body_text_plain("Hello from wasmCloud!\n"))
}
