// Deprecated API surface (issue #81).
//
// Kept as thin aliases so existing callers keep working; new code should use
// the renamed/Color-taking forms. Each alias forwards to the current API, so
// the wire format is unchanged.

///|
/// 非推奨: `set_position(mode)` を使ってください。実態は position-mode setter
/// （`POSITION_RELATIVE` / `POSITION_ABSOLUTE`）であり、「absolute にするだけ」の
/// 名前は誤解を招くため改名しました（issue #81）。
#deprecated("use set_position(mode) instead")
pub fn CommandBuffer::set_absolute(self : CommandBuffer, mode : Int) -> Unit {
  self.set_position(mode)
}
