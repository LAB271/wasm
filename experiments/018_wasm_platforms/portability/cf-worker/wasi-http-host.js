import { InputStream, OutputStream, Pollable } from './wasi-io-host.js';
// Minimal browser/workerd-compatible wasi:http SERVER host.
//
// preview2-shim only implements the client half (outgoingHandler). Its
// server-side types — IncomingRequest, ResponseOutparam, OutgoingResponse —
// are empty stubs, and jco's own `serve` sidesteps this by using the Node
// shim plus node:http, which workerd cannot provide because a Worker *is*
// the server and never listens on a socket.
//
// So this file is the missing piece: enough of wasi:http/types, backed by
// the platform's own Request/Response, to let a wasi-http component be
// driven from a Worker fetch handler.

export class Fields {
  #m;
  constructor(entries = []) { this.#m = new Map(); for (const [k, v] of entries) this.append(k, v); }
  static fromList(entries) { return new Fields(entries.map(([k, v]) => [k, v])); }
  get(name) { return this.#m.get(name.toLowerCase()) ?? []; }
  has(name) { return this.#m.has(name.toLowerCase()); }
  set(name, values) { this.#m.set(name.toLowerCase(), values.slice()); }
  delete(name) { this.#m.delete(name.toLowerCase()); }
  append(name, value) {
    const k = name.toLowerCase();
    const cur = this.#m.get(k) ?? [];
    cur.push(value instanceof Uint8Array ? value : new TextEncoder().encode(String(value)));
    this.#m.set(k, cur);
  }
  entries() { const out = []; for (const [k, vs] of this.#m) for (const v of vs) out.push([k, v]); return out; }
  clone() { return Fields.fromList(this.entries()); }
  toHeaders() {
    const h = new Headers();
    const dec = new TextDecoder();
    for (const [k, vs] of this.#m) for (const v of vs) h.append(k, dec.decode(v));
    return h;
  }
}

export class IncomingBody {
  #bytes; #taken = false;
  constructor(bytes) { this.#bytes = bytes; }
  stream() { if (this.#taken) throw new Error('body stream already taken'); this.#taken = true; return new InputStream(this.#bytes); }
  static finish() { return new FutureTrailers(); }
  [Symbol.dispose]() {}
}

export class IncomingRequest {
  #req; #fields; #bytes;
  constructor(request, bytes) { this.#req = request; this.#bytes = bytes; this.#fields = Fields.fromList([...request.headers].map(([k, v]) => [k, new TextEncoder().encode(v)])); }
  method() { const m = this.#req.method.toUpperCase(); const known = ['GET','HEAD','POST','PUT','DELETE','CONNECT','OPTIONS','TRACE','PATCH']; return known.includes(m) ? { tag: m.toLowerCase() } : { tag: 'other', val: m }; }
  pathWithQuery() { const u = new URL(this.#req.url); return u.pathname + u.search; }
  scheme() { const p = new URL(this.#req.url).protocol; return p === 'https:' ? { tag: 'HTTPS' } : { tag: 'HTTP' }; }
  authority() { return new URL(this.#req.url).host; }
  headers() { return this.#fields; }
  consume() { return new IncomingBody(this.#bytes); }
  [Symbol.dispose]() {}
}

export class OutgoingBody {
  stream_ = new OutputStream();
  write() { return this.stream_; }
  static finish(_body, _trailers) {}
  [Symbol.dispose]() {}
}


// The glue imports this even for a request-only path; the guest never sends
// trailers here, so an always-ready empty future is sufficient.
export class FutureTrailers {
  subscribe() { return new Pollable(); }
  get() { return { tag: 'ok', val: { tag: 'ok', val: undefined } }; }
  [Symbol.dispose]() {}
}

export class OutgoingResponse {
  #status = 200; #headers; #body = new OutgoingBody();
  constructor(headers) { this.#headers = headers ?? new Fields(); }
  statusCode() { return this.#status; }
  setStatusCode(c) { this.#status = c; }
  headers() { return this.#headers; }
  body() { return this.#body; }
  // Collapse into a platform Response once the guest is done with it.
  toResponse() {
    const buf = this.#body.stream_.collect();
    return new Response(buf.length ? buf : null, { status: this.#status, headers: this.#headers.toHeaders() });
  }
  [Symbol.dispose]() {}
}

export class ResponseOutparam {
  static #slot = null;
  static set(_param, result) { ResponseOutparam.#slot = result; }
  static take() { const r = ResponseOutparam.#slot; ResponseOutparam.#slot = null; return r; }
  [Symbol.dispose]() {}
}

export function httpErrorCode() { return undefined; }
export const types = { Fields, FutureTrailers, IncomingBody, IncomingRequest, OutgoingBody, OutgoingResponse, ResponseOutparam, httpErrorCode };
