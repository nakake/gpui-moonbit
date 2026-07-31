// Typed state store (RFC 0001 §3.3, G13).
//
// Replaces the module-top mutable arrays (`let count : Array[Int] = [0]`)
// that apps used to fake mutability out of MoonBit's immutable top-level
// bindings. A `Store` owns typed cells; a `CellId[T]` is the only way to
// reach a cell's value, and its phantom type `T` fixes the value type.
//
// Backend (RFC 0001 §6-1 resolution): this MoonBit toolchain has no `Any`
// type, so the RFC's `Array[Any]` + downcast sketch is not expressible.
// Instead each cell is a `Ref[T]` captured by two typed closures
// (get / set) inside the `CellId[T]` itself: the store holds nothing but
// bookkeeping, the value and its type never leave the closure environment,
// and there is no downcast anywhere. `Store` stays in the API (as the RFC
// §3.3 shape requires) as the creation site and — from Phase D on — the
// dirty-tracking coordinator.
//
// `cell_for_key` scopes cells by string key for reusable components with
// local state (RFC 0001 §3.1): the first call allocates, later calls return
// the same cell. The per-type pool is selected by trait dispatch
// (`KeyedCell`), so the pool map is typed and the API stays downcast-free.

///|
/// 型付き状態セルの識別子です。内部にそのセルの値へアクセスする型付きクロージャを
/// 保持し、phantom type `T` が値の型を固定します。`Store::get` / `Store::set`（および
/// Phase D 以降の `Signal`）だけがこの値を読み書きする正規の経路です。
pub(all) struct CellId[T] {
  /// セルの現在値を読み出します。
  get : () -> T
  /// セルの値を書き換えます。
  set : (T) -> Unit
}

///|
/// 異種状態の格納庫です。`new_cell` で型付きセルを確保し、`cell_for_key` でキーに
/// スコープしたセル（再利用コンポーネントのローカル状態用）を得ます。値の在処は
/// `CellId[T]` に閉じ込められたクロージャ環境であり、store 自体は生成と（Phase D
/// 以降の）dirty 追跡の調整点を担います。
pub(all) struct Store {
  int_cells : Map[String, Ref[Int]]
  bool_cells : Map[String, Ref[Bool]]
  string_cells : Map[String, Ref[String]]
  float_cells : Map[String, Ref[Float]]
  /// dispatch 内で `set` が 1 度でも起きたことを示すフラグ（RFC 0001 §3.4 の
  /// dirty 判定。`begin_dirty_tracking` でクリアし、`has_dirty` で読みます）。
  mut dirty : Bool
}

///|
/// 空の store を作成します。
pub fn Store::new() -> Store {
  {
    int_cells: Map([]),
    bool_cells: Map([]),
    string_cells: Map([]),
    float_cells: Map([]),
    dirty: false,
  }
}

///|
/// キーでスコープするセルの値型が持つべき性質です。`cell_for_key` が値型ごとに
/// 型付きプールを選ぶために使います。組み込みでは `Int` / `Bool` / `String` / `Float`
/// に実装されており、アプリは独自の値型に impl を追加して `cell_for_key` を利用
/// できます。
pub trait KeyedCell {
  /// この値型のキー付きセルプールを store から取得します。
  keyed_pool(Store) -> Map[String, Ref[Self]]
}

///|
pub impl KeyedCell for Int with fn keyed_pool(store : Store) -> Map[String, Ref[Int]] {
  store.int_cells
}

///|
pub impl KeyedCell for Bool with fn keyed_pool(store : Store) -> Map[String, Ref[Bool]] {
  store.bool_cells
}

///|
pub impl KeyedCell for String with fn keyed_pool(store : Store) -> Map[String, Ref[String]] {
  store.string_cells
}

///|
pub impl KeyedCell for Float with fn keyed_pool(store : Store) -> Map[String, Ref[Float]] {
  store.float_cells
}

///|
/// 初期値 `init` で新しい型付きセルを確保し、その `CellId[T]` を返します。
pub fn[T] Store::new_cell(self : Store, init : T) -> CellId[T] {
  ignore(self)
  let box : Ref[T] = { val: init }
  {
    get: fn() { box.val },
    set: fn(v) { box.val = v },
  }
}

///|
/// セルの現在値を読み出します。
pub fn[T] Store::get(self : Store, cell : CellId[T]) -> T {
  ignore(self)
  (cell.get)()
}

///|
/// セルの値を書き換えます。store の dirty フラグを立て、signal の自動再構築
/// （RFC 0001 §3.4）に接続します。
pub fn[T] Store::set(self : Store, cell : CellId[T], value : T) -> Unit {
  self.dirty = true
  (cell.set)(value)
}

///|
/// dirty 追跡を開始します（dispatch の先頭で呼び、この dispatch 内の `set` だけを
/// 集めます。RFC 0001 §3.4）。
pub fn Store::begin_dirty_tracking(self : Store) -> Unit {
  self.dirty = false
}

///|
/// 追跡開始以降に `set` が 1 度でも起きたかを返します（dispatch 末尾で一度だけ判定
/// し、1 回の再構築にバッチします。RFC 0001 §3.4）。
pub fn Store::has_dirty(self : Store) -> Bool {
  self.dirty
}

///|
/// キーでスコープしたセルを得ます（コンポーネントのローカル状態用、RFC 0001 §3.1）。
/// 初回呼び出しで `init` をもって確保し、以降の同じキーの呼び出しは同じセルを返します
/// （`init` は無視されます）。値型 `T` は `KeyedCell` を実装している必要があります。
pub fn[T : KeyedCell] Store::cell_for_key(self : Store, key : String, init : T) -> CellId[T] {
  let pool = KeyedCell::keyed_pool(self)
  match pool.get(key) {
    Some(box) => {
      get: fn() { box.val },
      set: fn(v) { box.val = v },
    }
    None => {
      let box : Ref[T] = { val: init }
      pool[key] = box
      {
        get: fn() { box.val },
        set: fn(v) { box.val = v },
      }
    }
  }
}

///|
/// `Signal[T]` を通じた `set` も同じ dirty 追跡に載るよう、signal 経由の書き込みは
/// 必ず `Store::set` を経ます（`signal.mbt` 参照）。
