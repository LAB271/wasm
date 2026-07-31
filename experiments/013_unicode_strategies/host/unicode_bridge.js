/**
 * JavaScript host bridge for WASM Unicode operations.
 *
 * Provides native Unicode support to WASM modules via imports.
 * Uses browser's built-in String methods and Intl APIs.
 */

// TextEncoder/TextDecoder for UTF-8 handling
const encoder = new TextEncoder();
const decoder = new TextDecoder();

// Grapheme segmenter for accurate character counting (emoji, etc.)
const segmenter = typeof Intl !== 'undefined' && Intl.Segmenter
  ? new Intl.Segmenter('en', { granularity: 'grapheme' })
  : null;

/**
 * Create import object for WASM module.
 * @param {WebAssembly.Memory} memory - WASM linear memory
 * @returns {Object} Import object for WebAssembly.instantiate
 */
export function createImports(memory) {
  return {
    env: {
      /**
       * Convert string to uppercase.
       * @param {number} ptr - Pointer to UTF-8 string in WASM memory
       * @param {number} len - Length of input string in bytes
       * @param {number} outPtr - Pointer to output buffer
       * @param {number} outCap - Capacity of output buffer
       * @returns {number} Length of result in bytes
       */
      _host_to_upper(ptr, len, outPtr, outCap) {
        const input = readString(memory, ptr, len);
        const result = input.toUpperCase();
        return writeString(memory, outPtr, outCap, result);
      },

      /**
       * Convert string to lowercase.
       */
      _host_to_lower(ptr, len, outPtr, outCap) {
        const input = readString(memory, ptr, len);
        const result = input.toLowerCase();
        return writeString(memory, outPtr, outCap, result);
      },

      /**
       * Check if code point is whitespace.
       * @param {number} cp - Unicode code point
       * @returns {number} 1 if whitespace, 0 otherwise
       */
      _host_is_whitespace(cp) {
        const char = String.fromCodePoint(cp);
        // Use regex with Unicode property escape
        return /^\s$/.test(char) ? 1 : 0;
      },

      /**
       * Count grapheme clusters in string.
       * Uses Intl.Segmenter for accurate emoji counting.
       */
      _host_char_count(ptr, len) {
        const input = readString(memory, ptr, len);

        if (segmenter) {
          // Use grapheme segmenter for accurate counting
          return [...segmenter.segment(input)].length;
        } else {
          // Fallback to code point counting
          return [...input].length;
        }
      },
    },
  };
}

/**
 * Read UTF-8 string from WASM memory.
 */
function readString(memory, ptr, len) {
  const bytes = new Uint8Array(memory.buffer, ptr, len);
  return decoder.decode(bytes);
}

/**
 * Write UTF-8 string to WASM memory.
 * @returns {number} Length of written bytes
 */
function writeString(memory, ptr, cap, str) {
  const bytes = encoder.encode(str);
  const len = Math.min(bytes.length, cap);
  const dest = new Uint8Array(memory.buffer, ptr, len);
  dest.set(bytes.subarray(0, len));
  return len;
}

/**
 * Load and instantiate a WASM module with Unicode bridge.
 * @param {string|URL|ArrayBuffer} source - WASM source
 * @returns {Promise<{instance: WebAssembly.Instance, memory: WebAssembly.Memory}>}
 */
export async function loadWithUnicodeBridge(source) {
  // Create shared memory
  const memory = new WebAssembly.Memory({ initial: 2, maximum: 10 });

  // Fetch and compile
  let bytes;
  if (source instanceof ArrayBuffer) {
    bytes = source;
  } else {
    const response = await fetch(source);
    bytes = await response.arrayBuffer();
  }

  // Instantiate with imports
  const imports = createImports(memory);
  imports.env.memory = memory;

  const { instance } = await WebAssembly.instantiate(bytes, imports);

  return { instance, memory };
}

/**
 * High-level wrapper for string operations.
 */
export class UnicodeLib {
  constructor(instance, memory) {
    this.instance = instance;
    this.memory = memory;
    this.exports = instance.exports;

    // Get buffer pointer from WASM
    this.bufferPtr = this.exports.get_buffer_ptr();
  }

  /**
   * Write string to WASM buffer.
   */
  writeInput(str) {
    const bytes = encoder.encode(str);
    const view = new Uint8Array(this.memory.buffer, this.bufferPtr, 4096);
    view.set(bytes);
    return bytes.length;
  }

  /**
   * Read string from WASM buffer.
   */
  readOutput(len) {
    const bytes = new Uint8Array(this.memory.buffer, this.bufferPtr, len);
    return decoder.decode(bytes);
  }

  /**
   * Convert string to uppercase.
   */
  toUpper(str) {
    const inputLen = this.writeInput(str);
    const outputLen = this.exports.wasm_to_upper(inputLen);
    return this.readOutput(outputLen);
  }

  /**
   * Convert string to lowercase.
   */
  toLower(str) {
    const inputLen = this.writeInput(str);
    const outputLen = this.exports.wasm_to_lower(inputLen);
    return this.readOutput(outputLen);
  }

  /**
   * Check if character is whitespace.
   */
  isWhitespace(char) {
    const cp = char.codePointAt(0);
    return this.exports.wasm_is_whitespace(cp) !== 0;
  }

  /**
   * Count characters in string.
   */
  charCount(str) {
    const inputLen = this.writeInput(str);
    return this.exports.wasm_char_count(inputLen);
  }
}

/**
 * Create UnicodeLib from WASM source.
 */
export async function createUnicodeLib(source) {
  const { instance, memory } = await loadWithUnicodeBridge(source);
  return new UnicodeLib(instance, memory);
}
