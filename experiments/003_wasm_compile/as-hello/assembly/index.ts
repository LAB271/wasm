/**
 * Hello World HTTP handler — AssemblyScript compiled to WASM component.
 *
 * This module implements the wasi:http/incoming-handler interface using
 * raw canonical ABI calls. AssemblyScript has no wit-bindgen support,
 * so all WASI imports are declared manually with their canonical ABI
 * signatures.
 *
 * Build:
 *   npm run asbuild
 *   wasm-tools component embed ../python-raw/wit --world proxy build/hello-as-core.wasm -o build/hello-as-embed.wasm
 *   wasm-tools component new build/hello-as-embed.wasm -o build/hello-as.wasm
 *
 * Run:
 *   wasmtime serve build/hello-as.wasm --addr 127.0.0.1:5036
 */

// ── Override AS runtime abort to avoid env.abort import ──────────────────────
function abort(
  message: string | null,
  fileName: string | null,
  lineNumber: u32,
  columnNumber: u32
): void {
  unreachable();
}

// ── Static data in linear memory ────────────────────────────────────────────
// We store constant strings at fixed offsets for the canonical ABI.
// AS memory starts at offset 0; we use a high offset region for our data.

const DATA_BASE: u32 = 60000; // High within page 1 (64KB), above AS heap base

// "content-type" (12 bytes) at DATA_BASE
const CT_NAME_PTR: u32 = DATA_BASE;
const CT_NAME_LEN: u32 = 12;

// "application/json" (16 bytes) at DATA_BASE + 16
const CT_VALUE_PTR: u32 = DATA_BASE + 16;
const CT_VALUE_LEN: u32 = 16;

// JSON template buffer at DATA_BASE + 64 (256 bytes reserved)
const JSON_BUF_PTR: u32 = DATA_BASE + 64;

// Return value scratch area at DATA_BASE + 320
const RET_AREA: u32 = DATA_BASE + 320;

// ── WASI Imports (canonical ABI, legacy naming) ─────────────────────────────

// wall-clock now: writes {seconds: u64, nanoseconds: u32} to retptr
@external("wasi:clocks/wall-clock@0.2.9", "now")
declare function clock_now(retptr: u32): void;

// fields constructor: () -> handle
@external("wasi:http/types@0.2.9", "[constructor]fields")
declare function fields_new(): u32;

// fields.append: (self, name_ptr, name_len, value_ptr, value_len, retptr) -> void
@external("wasi:http/types@0.2.9", "[method]fields.append")
declare function fields_append(self: u32, name_ptr: u32, name_len: u32, value_ptr: u32, value_len: u32, retptr: u32): void;

// outgoing-response constructor: (headers_handle) -> response_handle
@external("wasi:http/types@0.2.9", "[constructor]outgoing-response")
declare function outgoing_response_new(headers: u32): u32;

// set-status-code: (self, code) -> i32 (0=ok)
@external("wasi:http/types@0.2.9", "[method]outgoing-response.set-status-code")
declare function outgoing_response_set_status(self: u32, code: u32): u32;

// outgoing-response.body: (self, retptr) -> void
@external("wasi:http/types@0.2.9", "[method]outgoing-response.body")
declare function outgoing_response_body(self: u32, retptr: u32): void;

// outgoing-body.write: (self, retptr) -> void
@external("wasi:http/types@0.2.9", "[method]outgoing-body.write")
declare function outgoing_body_write(self: u32, retptr: u32): void;

// outgoing-body.finish: (this, trailers_is_some, trailers_val, retptr) -> void
@external("wasi:http/types@0.2.9", "[static]outgoing-body.finish")
declare function outgoing_body_finish(body: u32, trailers_is_some: u32, trailers_val: u32, retptr: u32): void;

// response-outparam.set: (outparam, disc, ok_val, e1, e2:i64, e3, e4, e5, e6) -> void
// For OK: (outparam, 0, response_handle, 0, 0, 0, 0, 0, 0)
@external("wasi:http/types@0.2.9", "[static]response-outparam.set")
declare function response_outparam_set(
  outparam: u32, disc: u32, ok_or_err: u32,
  e1: u32, e2: u64, e3: u32, e4: u32, e5: u32, e6: u32
): void;

// output-stream.blocking-write-and-flush: (self, ptr, len, retptr) -> void
@external("wasi:io/streams@0.2.9", "[method]output-stream.blocking-write-and-flush")
declare function stream_write(self: u32, ptr: u32, len: u32, retptr: u32): void;

// Resource drops
@external("wasi:http/types@0.2.9", "[resource-drop]fields")
declare function fields_drop(handle: u32): void;

@external("wasi:http/types@0.2.9", "[resource-drop]outgoing-body")
declare function outgoing_body_drop(handle: u32): void;

@external("wasi:io/streams@0.2.9", "[resource-drop]output-stream")
declare function output_stream_drop(handle: u32): void;

@external("wasi:http/types@0.2.9", "[resource-drop]incoming-request")
declare function incoming_request_drop(handle: u32): void;

@external("wasi:http/types@0.2.9", "[resource-drop]outgoing-response")
declare function outgoing_response_drop(handle: u32): void;

// ── Initialization: write static strings into memory ────────────────────────

function initStaticData(): void {
  // "content-type"
  const ct: StaticArray<u8> = [0x63,0x6f,0x6e,0x74,0x65,0x6e,0x74,0x2d,0x74,0x79,0x70,0x65];
  for (let i: u32 = 0; i < 12; i++) {
    store<u8>(CT_NAME_PTR + i, unchecked(ct[i]));
  }
  // "application/json"
  const av: StaticArray<u8> = [0x61,0x70,0x70,0x6c,0x69,0x63,0x61,0x74,0x69,0x6f,0x6e,0x2f,0x6a,0x73,0x6f,0x6e];
  for (let i: u32 = 0; i < 16; i++) {
    store<u8>(CT_VALUE_PTR + i, unchecked(av[i]));
  }
}

// ── u64 to decimal string ───────────────────────────────────────────────────

function writeU64(value: u64, offset: u32): u32 {
  if (value == 0) {
    store<u8>(offset, 0x30); // '0'
    return 1;
  }
  // Write digits in reverse, then flip
  let len: u32 = 0;
  let v = value;
  while (v > 0) {
    store<u8>(offset + len, <u8>((v % 10) + 48));
    v /= 10;
    len++;
  }
  // Reverse in place
  for (let i: u32 = 0; i < len / 2; i++) {
    const a = load<u8>(offset + i);
    const b = load<u8>(offset + len - 1 - i);
    store<u8>(offset + i, b);
    store<u8>(offset + len - 1 - i, a);
  }
  return len;
}

// ── Build JSON response body ────────────────────────────────────────────────

function buildJson(seconds: u64): u32 {
  // {"message":"Hello World","timestamp":NNNN}
  let off: u32 = JSON_BUF_PTR;
  const prefix: StaticArray<u8> = [
    0x7b, 0x22, 0x6d, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65, 0x22, 0x3a,
    0x22, 0x48, 0x65, 0x6c, 0x6c, 0x6f, 0x20, 0x57, 0x6f, 0x72, 0x6c,
    0x64, 0x22, 0x2c, 0x22, 0x74, 0x69, 0x6d, 0x65, 0x73, 0x74, 0x61,
    0x6d, 0x70, 0x22, 0x3a
  ]; // {"message":"Hello World","timestamp":
  for (let i: u32 = 0; i < 37; i++) {
    store<u8>(off + i, unchecked(prefix[i]));
  }
  off += 37;
  off += writeU64(seconds, off);
  store<u8>(off, 0x7d); // }
  off++;
  return off - JSON_BUF_PTR; // length
}

// ── cabi_realloc — required by component model ──────────────────────────────

let bump_ptr: u32 = DATA_BASE + 1024;

export function cabi_realloc(
  old_ptr: u32, old_size: u32, align: u32, new_size: u32
): u32 {
  // Simple bump allocator — sufficient for short-lived request handling
  const aligned = (bump_ptr + align - 1) & ~(align - 1);
  bump_ptr = aligned + new_size;
  return aligned;
}

// ── HTTP handler ────────────────────────────────────────────────────────────

export function handle(request: u32, response_out: u32): void {
  initStaticData();

  // Get wall clock time (seconds since epoch)
  clock_now(RET_AREA);
  const seconds = load<u64>(RET_AREA);

  // Build JSON body
  const json_len = buildJson(seconds);

  // Drop the incoming request (we don't read it)
  incoming_request_drop(request);

  // Create response headers
  const headers = fields_new();
  fields_append(headers, CT_NAME_PTR, CT_NAME_LEN, CT_VALUE_PTR, CT_VALUE_LEN, RET_AREA);

  // Create outgoing response with headers
  const response = outgoing_response_new(headers);
  outgoing_response_set_status(response, 200);

  // Get outgoing body
  outgoing_response_body(response, RET_AREA);
  const body = load<u32>(RET_AREA + 4); // skip discriminant at offset 0

  // Send response via outparam (OK variant)
  response_outparam_set(response_out, 0, response, 0, 0, 0, 0, 0, 0);

  // Get output stream from body
  outgoing_body_write(body, RET_AREA);
  const stream = load<u32>(RET_AREA + 4); // skip discriminant

  // Write JSON body
  stream_write(stream, JSON_BUF_PTR, json_len, RET_AREA);

  // Clean up
  output_stream_drop(stream);
  outgoing_body_finish(body, 0, 0, RET_AREA);
}
