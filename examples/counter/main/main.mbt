// Executable entry point for the Counter demo.
//
// Everything this package does is what any consumer's `main` does: register the
// app's dispatch into the library-owned entry point Rust links (RFC 0004),
// commit the first tree, and hand the thread to the GPUI event loop.
//
// The app itself lives in the sibling `counter` package. That split is not
// cosmetic: this package imports `nakake/gpui-bindings/link` to receive the
// prebuild's link flags, and those flags reach the test executable of any
// package that imports it — which moon links with tcc, where they fail to
// resolve. Keeping the tested code out of here is what lets `moon test` run.

///|
fn main {
  @nakake/gpui-bindings.register_dispatch(@nakake/gpui-counter-example/counter.dispatch)
  @nakake/gpui-bindings.expect_ok(
    @nakake/gpui-counter-example/counter.build_tree(0),
    "initial build_tree",
  )
  @nakake/gpui-bindings.expect_ok(
    @nakake/gpui-bindings.run_window(0, 600.0, 500.0),
    "run_window",
  )
}
