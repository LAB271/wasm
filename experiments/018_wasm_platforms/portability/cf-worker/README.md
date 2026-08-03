# Running a wasi:http component on Cloudflare Workers

Leg 5 of `scripts/portability-test.sh` shows the unmodified component being
rejected by workerd:

```
Uncaught CompileError: WasmModuleObject::Compile():
    expected version 01 00 00 00, found 0d 00 01 00 @+4
```

Those bytes are the whole story. A core module starts `\0asm 01 00 00 00`; a
component starts `\0asm 0d 00 01 00`. V8 reads the container header, finds a
component, and stops.

This directory is leg 6: the *same* component, made to run. It does, and it
takes four distinct things — each one a separate constraint workerd imposes.

## 1. Transpile the component to a core module — `jco transpile`

```
jco transpile hello_world.wasm -o gen \
    --map 'wasi:http/types@0.2.9=./../wasi-http-host.js' \
    --instantiation sync
```

Produces `hello_world.core{,2,3}.wasm` plus JS glue. Header check:

```
component: 0061 736d 0d00 0100
core:      0061 736d 0100 0000   <- what V8 wanted
```

## 2. `--instantiation sync`, because workerd forbids top-level await

jco's default output instantiates at module scope with `await`. workerd rejects
that at startup:

```
Uncaught Error: Top-level await in module is unsettled.
```

`--instantiation sync` emits `instantiate(getCoreModule, imports)` instead, so
instantiation happens under our control.

## 3. Static `.wasm` imports

`import core1 from './gen/hello_world.core.wasm'` gives a `WebAssembly.Module`
synchronously, which is what sync instantiation needs. (Do **not** add a
`[[rules]]` block for this — wrangler already has a `CompiledWasm` rule for
`**/*.wasm`, and a second one errors with "a previous rule with the same type
was not marked as fallthrough".)

## 4. A wasi:http **server** host — `wasi-http-host.js`

The real blocker, and deeper than the binary format. `preview2-shim` implements
only the *client* half of wasi:http. Its server-side types are empty stubs:

```js
export const incomingHandler = { handle() {} };
export const types = {
  IncomingRequest:  class IncomingRequest {},   // empty
  OutgoingResponse: class OutgoingResponse {},  // empty
  ResponseOutparam: class ResponseOutparam {},  // empty
};
```

`jco serve` works only because it uses the **Node** shim plus `node:http`, which
workerd cannot provide — a Worker *is* the server and never listens on a socket.
So `wasi-http-host.js` implements the server side against the platform's own
`Request`/`Response`.

## 5. And a wasi:io host — `wasi-io-host.js`

Mixing our http host with the shim's io produces:

```
TypeError: Resource error: Not a valid "OutputStream" resource.
```

because the glue does `e instanceof OutputStream` against the class handed to it
at instantiation. Two `OutputStream` constructors cannot satisfy one check, so
the whole resource graph needs a single owner.

## Result

```
$ curl -i http://127.0.0.1:19111/
HTTP/1.1 200 OK
Content-Length: 22

Hello from wasmCloud!
```

**Portable, but not unmodified.** The guest is byte-identical to the one running
on wasmtime, Spin and wasmCloud — no source change, no recompile. What it needs
is a ~180-line host adapter and a transpilation step. That is a materially
different claim from either "it works" or "it doesn't", which is why the
portability table reports it as its own outcome.
