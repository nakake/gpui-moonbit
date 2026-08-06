///|
fn main {
  // Install this app's dispatch into the library-owned entry point Rust links
  // (RFC 0004). Registration must happen before `run_window`, and the parameter
  // type anchors the five-Int / Int callback ABI (versioned event envelope:
  // abi_version, event_kind, view, data_a, data_b) during `moon check`.
  @nakake/gpui-bindings.register_dispatch(@nakake/gpui-bindings/app.dispatch)

  @nakake/gpui-bindings.expect_ok(
    @nakake/gpui-bindings/app.build_tree(0),
    "initial build_tree",
  )
  @nakake/gpui-bindings.expect_ok(
    @nakake/gpui-bindings.run_window(0, 600.0, 500.0),
    "run_window",
  )
}
