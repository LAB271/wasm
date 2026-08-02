// FFI Guest — AssemblyScript module that calls Rust host functions
//
// This demonstrates the FFI boundary: AS handles orchestration, Rust handles
// heavy lifting (crypto with hardware acceleration).

// Host imports (implemented in Rust)
@external("env", "host_noop")
declare function host_noop(): void;

@external("env", "host_sha256")
declare function host_sha256(ptr: i32, len: i32): void;

@external("env", "host_get_result")
declare function host_get_result(dest_ptr: i32): i32;

@external("env", "host_get_call_count")
declare function host_get_call_count(): i64;

// Test SHA256 against known vector
// Input: "hello" (5 bytes)
// Expected: 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824
export function test_sha256(): i32 {
  // Create input buffer with "hello"
  const testInput = new StaticArray<u8>(5);
  unchecked(testInput[0] = 0x68); // 'h'
  unchecked(testInput[1] = 0x65); // 'e'
  unchecked(testInput[2] = 0x6c); // 'l'
  unchecked(testInput[3] = 0x6c); // 'l'
  unchecked(testInput[4] = 0x6f); // 'o'

  // Result buffer (32 bytes for SHA256)
  const resultBuffer = new StaticArray<u8>(32);

  // Expected SHA256 of "hello"
  const expectedHash = new StaticArray<u8>(32);
  const expected: u8[] = [
    0x2c, 0xf2, 0x4d, 0xba, 0x5f, 0xb0, 0xa3, 0x0e,
    0x26, 0xe8, 0x3b, 0x2a, 0xc5, 0xb9, 0xe2, 0x9e,
    0x1b, 0x16, 0x1e, 0x5c, 0x1f, 0xa7, 0x42, 0x5e,
    0x73, 0x04, 0x33, 0x62, 0x93, 0x8b, 0x98, 0x24
  ];
  for (let i = 0; i < 32; i++) {
    unchecked(expectedHash[i] = unchecked(expected[i]));
  }

  // Call host to compute SHA256 of "hello"
  host_sha256(changetype<i32>(testInput), 5);

  // Get result back
  const len = host_get_result(changetype<i32>(resultBuffer));
  if (len != 32) {
    return 1; // Wrong length
  }

  // Compare with expected
  for (let i = 0; i < 32; i++) {
    if (unchecked(resultBuffer[i]) != unchecked(expectedHash[i])) {
      return 2; // Hash mismatch
    }
  }

  return 0; // Success
}

// Benchmark: pure FFI overhead (empty calls)
export function bench_noop(iterations: i32): void {
  for (let i: i32 = 0; i < iterations; i++) {
    host_noop();
  }
}

// Benchmark: SHA256 of 32-byte buffer
export function bench_sha256_small(iterations: i32): void {
  const buffer = new StaticArray<u8>(32);
  for (let i = 0; i < 32; i++) {
    unchecked(buffer[i] = <u8>(i & 0xff));
  }
  const ptr = changetype<i32>(buffer);
  for (let i: i32 = 0; i < iterations; i++) {
    host_sha256(ptr, 32);
  }
}

// Benchmark: SHA256 of 1KB buffer
export function bench_sha256_1k(iterations: i32): void {
  const buffer = new StaticArray<u8>(1024);
  for (let i = 0; i < 1024; i++) {
    unchecked(buffer[i] = <u8>(i & 0xff));
  }
  const ptr = changetype<i32>(buffer);
  for (let i: i32 = 0; i < iterations; i++) {
    host_sha256(ptr, 1024);
  }
}

// Get total host call count (for verification)
export function getCallCount(): i64 {
  return host_get_call_count();
}
