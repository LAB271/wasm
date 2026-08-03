// Minimal wasi:io for workerd: poll, streams, error.
//
// These have to live here rather than come from preview2-shim, because jco's
// glue does `e instanceof OutputStream` against the class it was handed at
// instantiation. Mixing the shim's classes with our own http host produces
// "Resource error: Not a valid OutputStream resource" — the two OutputStreams
// are different constructors. One owner for the whole resource graph.

export class Error$ {
  #msg;
  constructor(msg = 'io error') { this.#msg = msg; }
  toDebugString() { return this.#msg; }
  [Symbol.dispose]() {}
}

export class Pollable {
  #ready;
  constructor(ready = () => true) { this.#ready = ready; }
  ready() { return this.#ready(); }
  block() {}
  [Symbol.dispose]() {}
}

export function poll(list) {
  // Everything here is synchronous and always ready, so every index is ready.
  return Uint32Array.from(list.map((_, i) => i));
}

export class InputStream {
  #buf; #pos = 0;
  constructor(bytes = new Uint8Array()) { this.#buf = bytes; }
  read(len) {
    const n = Number(len);
    if (this.#pos >= this.#buf.length) throw { tag: 'closed' };
    const out = this.#buf.subarray(this.#pos, Math.min(this.#pos + n, this.#buf.length));
    this.#pos += out.length;
    return out;
  }
  blockingRead(len) { return this.read(len); }
  skip(len) { return BigInt(this.read(len).length); }
  blockingSkip(len) { return this.skip(len); }
  subscribe() { return new Pollable(); }
  [Symbol.dispose]() {}
}

export class OutputStream {
  chunks = [];
  checkWrite() { return 65536n; }
  write(bytes) { this.chunks.push(bytes.slice()); }
  blockingWrite(bytes) { this.write(bytes); }
  blockingWriteAndFlush(bytes) { this.write(bytes); }
  writeZeroes(n) { this.chunks.push(new Uint8Array(Number(n))); }
  blockingWriteZeroesAndFlush(n) { this.writeZeroes(n); }
  flush() {}
  blockingFlush() {}
  splice(src, len) { const b = src.read(len); this.write(b); return BigInt(b.length); }
  blockingSplice(src, len) { return this.splice(src, len); }
  subscribe() { return new Pollable(); }
  collect() {
    const total = this.chunks.reduce((n, c) => n + c.length, 0);
    const buf = new Uint8Array(total);
    let o = 0; for (const c of this.chunks) { buf.set(c, o); o += c.length; }
    return buf;
  }
  [Symbol.dispose]() {}
}

export const error = { Error: Error$ };
export const poll_ = { Pollable, poll };
export const streams = { InputStream, OutputStream };
