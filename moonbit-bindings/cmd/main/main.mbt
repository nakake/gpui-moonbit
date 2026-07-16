fn main {
  // `dispatch` is only ever called from Rust (via its mangled symbol), which
  // MoonBit's dead-code elimination cannot see. Bind it once so it is retained.
  let _keep : (Int, Int, Int, Int) -> Unit = @username/gpui-bindings/app.dispatch
  ignore(_keep)

  @username/gpui-bindings/app.build_tree()
  @username/gpui-bindings.run_window(600.0, 500.0)
}
