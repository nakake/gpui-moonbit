//! Coverage-guided fuzz target for the command-buffer decoder (G25).
//!
//! Feeds arbitrary bytes to the real decoder through the public FFI entry point.
//! Under `cargo fuzz` (ASan + libFuzzer) this surfaces memory-safety bugs and
//! drives the decoder down paths the seeded in-crate fuzzer may miss. Rust
//! panics are caught by `ffi_export` and reported as `GPUI_STATUS_INTERNAL_PANIC`
//! (the in-crate `fuzz_tests` cover panic-freedom directly by calling the
//! decoder without that wrapper); here a non-`GPUI_STATUS_*` return or an
//! ASan-detected fault fails the run.

#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    // Cap the length at i32::MAX so the `len as i32` FFI argument never wraps
    // (libFuzzer bounds inputs well below this, but be explicit).
    let len = data.len().min(i32::MAX as usize) as i32;
    // Slot 9999 keeps fuzzing off the golden tests' slot 0.
    let status = gpui_sys::gpui_build_tree(9999, data.as_ptr(), len);
    // The decoder is total over its input: every byte sequence yields a
    // `GPUI_STATUS_*` code. Assert the contract so a corrupted return value is
    // itself a finding.
    assert!(
        (-9..=0).contains(&status),
        "decoder returned out-of-range status {status}"
    );
});
