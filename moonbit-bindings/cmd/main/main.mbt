///|
fn main {
  // `dispatch` is only ever called from Rust (via its mangled symbol), which
  // MoonBit's dead-code elimination cannot see. The explicit function type both
  // retains it and anchors the five-Int / Int callback ABI (versioned event
  // envelope: abi_version, event_kind, view, data_a, data_b) during `moon check`.
  let _keep : (Int, Int, Int, Int, Int) -> Int = @nakake/gpui-bindings/app.dispatch
  ignore(_keep)

  @nakake/gpui-bindings.expect_ok(
    @nakake/gpui-bindings/app.build_tree(0),
    "initial build_tree",
  )
  @nakake/gpui-bindings.expect_ok(
    @nakake/gpui-bindings.run_window(0, 600.0, 500.0),
    "run_window",
  )
}
