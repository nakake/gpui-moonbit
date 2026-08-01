// Declarative reactive primitive (RFC 0001 §3.4, G14).
//
// A `Signal[T]` is a subscribable view over a store cell. Handlers `set`
// signals instead of returning "changed" flags; the framework detects dirt
// through the store's dirty tracking and schedules the rebuild, so the
// "return 1 or the UI silently does not update" bug class disappears.
//
// Phase 1 (this implementation, no ABI change): dirt detection is global —
// any `set` during a dispatch marks the store dirty and the whole tree is
// rebuilt (RFC 0001 §2.4). Phase 2 (#10, needs a subtree-patch opcode) would
// record dependencies at `get` time and rebuild only dirty subtrees; the
// Signal API does not change when that lands.

///|
/// 購読可能な状態。中身は store 内の cell です（RFC 0001 §3.4）。ハンドラは
/// 「変わったか」を戻り値で報告する代わりに `set` を呼び、框架が dirty を検知して
/// 再構築します。
pub(all) struct Signal[T] {
  cell : CellId[T]
}

///|
/// store のセルを購読する signal を作ります。
pub fn[T] Store::signal(self : Store, cell : CellId[T]) -> Signal[T] {
  ignore(self)
  { cell, }
}

///|
/// signal の現在値を読み出します。
pub fn[T] Signal::get(self : Signal[T], store : Store) -> T {
  store.get(self.cell)
}

///|
/// signal の値を書き換えます。store の dirty 追跡を起動し、dispatch 末尾の判定で
/// 再構築がスケジュールされます（RFC 0001 §3.4）。
pub fn[T] Signal::set(self : Signal[T], store : Store, value : T) -> Unit {
  store.set(self.cell, value)
}
