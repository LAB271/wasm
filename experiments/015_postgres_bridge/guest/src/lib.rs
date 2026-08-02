//! pg_guest — WASM module that calls host-provided database functions.
//!
//! This module imports functions from the host (db_query_all, db_insert, etc.)
//! and uses them to perform database operations. The host implements these
//! by calling Postgres directly — no HTTP, no sidecar.
//!
//! Imports from host:
//!   - db_query_all() -> i32 (length of JSON result)
//!   - db_get_result(dest_ptr) -> i32 (copies result to dest_ptr, returns len)
//!   - db_insert(name_ptr, name_len, email_ptr, email_len, dept_ptr, dept_len) -> i32 (new id)
//!   - db_delete(id) -> i32 (1 if deleted, 0 if not found)
//!   - db_count() -> i32

#![no_std]

extern crate alloc;

use alloc::string::String;
use alloc::vec;
use alloc::vec::Vec;

// Host imports
extern "C" {
    fn db_query_all() -> i32;
    fn db_get_result(dest_ptr: i32) -> i32;
    fn db_insert(
        name_ptr: i32,
        name_len: i32,
        email_ptr: i32,
        email_len: i32,
        dept_ptr: i32,
        dept_len: i32,
    ) -> i32;
    fn db_delete(id: i32) -> i32;
    fn db_count() -> i32;
}

// Simple bump allocator for no_std
static mut HEAP: [u8; 65536] = [0; 65536];
static mut HEAP_PTR: usize = 0;

#[global_allocator]
static ALLOCATOR: BumpAllocator = BumpAllocator;

struct BumpAllocator;

unsafe impl alloc::alloc::GlobalAlloc for BumpAllocator {
    unsafe fn alloc(&self, layout: alloc::alloc::Layout) -> *mut u8 {
        let align = layout.align();
        let size = layout.size();

        // Align up
        let ptr = (HEAP_PTR + align - 1) & !(align - 1);
        let new_ptr = ptr + size;

        if new_ptr > HEAP.len() {
            core::ptr::null_mut()
        } else {
            HEAP_PTR = new_ptr;
            HEAP.as_mut_ptr().add(ptr)
        }
    }

    unsafe fn dealloc(&self, _ptr: *mut u8, _layout: alloc::alloc::Layout) {
        // Bump allocator doesn't deallocate
    }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    loop {}
}

/// Buffer for receiving query results from host
static mut RESULT_BUF: [u8; 8192] = [0; 8192];

/// Test CRUD operations
/// Returns 0 on success, non-zero on failure
#[no_mangle]
pub extern "C" fn test_crud() -> i32 {
    unsafe {
        // 1. Check initial count (should be 3 after schema init)
        let initial_count = db_count();
        if initial_count != 3 {
            return 1; // Expected 3 initial records
        }

        // 2. Insert a new record
        let name = b"TestUser";
        let email = b"test@example.com";
        let dept = b"QA";

        let new_id = db_insert(
            name.as_ptr() as i32,
            name.len() as i32,
            email.as_ptr() as i32,
            email.len() as i32,
            dept.as_ptr() as i32,
            dept.len() as i32,
        );

        if new_id <= 0 {
            return 2; // Insert failed
        }

        // 3. Verify count increased
        let new_count = db_count();
        if new_count != 4 {
            return 3; // Expected 4 records after insert
        }

        // 4. Query all and verify we get JSON back
        let json_len = db_query_all();
        if json_len <= 0 {
            return 4; // Query failed
        }

        // Copy result to our buffer
        let copied = db_get_result(RESULT_BUF.as_mut_ptr() as i32);
        if copied != json_len {
            return 5; // Copy mismatch
        }

        // 5. Delete the record we created
        let deleted = db_delete(new_id);
        if deleted != 1 {
            return 6; // Delete failed
        }

        // 6. Verify count is back to 3
        let final_count = db_count();
        if final_count != 3 {
            return 7; // Expected 3 records after delete
        }

        0 // Success
    }
}

/// Benchmark: query a single record by id
/// Just calls db_count as a simple query benchmark
#[no_mangle]
pub extern "C" fn benchmark_query(_id: i32) -> i32 {
    unsafe { db_count() }
}

/// Export memory for host access
#[no_mangle]
pub static mut MEMORY_EXPORT: [u8; 0] = [];
