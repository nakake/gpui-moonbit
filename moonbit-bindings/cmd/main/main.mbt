///|
fn main {
  // `dispatch` is only ever called from Rust (via its mangled symbol), which
  // MoonBit's dead-code elimination cannot see. The explicit function type both
  // retains it and anchors the four-Int / Int callback ABI (versioned event
  // envelope: abi_version, event_kind, data_a, data_b) during `moon check`.
  let _keep : (Int, Int, Int, Int) -> Int = @username/gpui-bindings/app.dispatch
  ignore(_keep)

  match @username/gpui-bindings/app.build_tree() {
    Ok(_) => ()
    Err(status) => abort("initial build_tree failed with status \{status}")
  }
  match @username/gpui-bindings.run_window(600.0, 500.0) {
    Ok(_) => ()
    Err(status) => abort("run_window failed with status \{status}")
  }
}
