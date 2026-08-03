// Running a wasi:http COMPONENT on Cloudflare Workers.
//
// workerd/V8 only loads core modules, so the component is transpiled by jco
// into core wasm + JS glue. Two extra constraints workerd imposes:
//   1. no unsettled top-level await  -> `jco transpile --instantiation sync`
//   2. wasm must be a static import  -> the three cores are imported directly,
//      which gives WebAssembly.Module objects synchronously
// The wasi:http server host is ours (wasi-http-host.js) because preview2-shim
// only implements the client half.
import core1 from './gen/hello_world.core.wasm';
import core2 from './gen/hello_world.core2.wasm';
import core3 from './gen/hello_world.core3.wasm';
import { instantiate } from './gen/hello_world.js';

import * as cli from '@bytecodealliance/preview2-shim/cli';
import * as clocks from '@bytecodealliance/preview2-shim/clocks';
import { error as ioError, poll_ as ioPoll, streams as ioStreams } from './wasi-io-host.js';
import * as random from '@bytecodealliance/preview2-shim/random';
import * as httpHost from './wasi-http-host.js';
import { IncomingRequest, ResponseOutparam } from './wasi-http-host.js';

const CORES = {
  'hello_world.core.wasm': core1,
  'hello_world.core2.wasm': core2,
  'hello_world.core3.wasm': core3,
};

const imports = {
  './../wasi-http-host.js': httpHost,
  'wasi:cli/environment': cli.environment,
  'wasi:cli/exit': cli.exit,
  'wasi:cli/stdin': cli.stdin,
  'wasi:cli/stdout': cli.stdout,
  'wasi:cli/stderr': cli.stderr,
  'wasi:cli/terminal-input': cli.terminalInput,
  'wasi:cli/terminal-output': cli.terminalOutput,
  'wasi:cli/terminal-stdin': cli.terminalStdin,
  'wasi:cli/terminal-stdout': cli.terminalStdout,
  'wasi:cli/terminal-stderr': cli.terminalStderr,
  'wasi:clocks/monotonic-clock': clocks.monotonicClock,
  // Ours, not the shim's: the http host and the glue must agree on one
  // OutputStream/InputStream constructor or `instanceof` checks fail.
  'wasi:io/error': ioError,
  'wasi:io/poll': ioPoll,
  'wasi:io/streams': ioStreams,
  'wasi:random/insecure-seed': random.insecureSeed,
};

const guest = instantiate((name) => CORES[name], imports);

export default {
  async fetch(request) {
    const bytes = ['GET', 'HEAD'].includes(request.method.toUpperCase())
      ? new Uint8Array()
      : new Uint8Array(await request.arrayBuffer());

    const outparam = new ResponseOutparam();
    guest.incomingHandler.handle(new IncomingRequest(request, bytes), outparam);

    const result = ResponseOutparam.take();
    if (!result) return new Response('guest set no response', { status: 500 });
    if (result.tag === 'err') return new Response('guest error: ' + JSON.stringify(result.val), { status: 502 });
    return result.val.toResponse();
  },
};
