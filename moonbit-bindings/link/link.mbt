// Link-only package for nakake/gpui-bindings (issue #93, G2).
//
// This package exists solely as the target for the prebuild LinkConfig.
// It carries no code — importing it in your executable's moon.pkg causes
// the Rust staticlib link flags (propagated by build.py via
// --moonbit-unstable-prebuild) to be included in the final link.
//
// Usage in your executable's moon.pkg:
//   import {
//     "nakake/gpui-bindings",
//     "nakake/gpui-bindings/app",   // retain app.dispatch for the callback
//     "nakake/gpui-bindings/link",  // pull in the Rust staticlib link flags
//   }
//
// Do NOT import this from library packages or test files — it would cause
// the link flags to propagate to test executables, which use tcc and cannot
// resolve system C++ libraries.

///|
pub const LINK_MARKER : Int = 0
