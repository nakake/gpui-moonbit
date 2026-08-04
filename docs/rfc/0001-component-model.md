# RFC 0001: コンポーネントモデルと状態管理

| 項目 | 内容 |
|---|---|
| ステータス | 実装済み（#86、Phase A–D）。現行実装の権威は [`architecture.md`](../architecture.md)であり、本 RFC は設計判断とその根拠の記録である |
| 作成日 | 2026-07-25 |
| 対象ギャップ | [`framework-gaps.md`](../framework-gaps.md) `G11`〜`G14`（§3 コンポーネントモデルと状態管理） |
| 関連 issue | #10（インクリメンタル更新、将来）、#41/#49（view スロット）、#9（安定キー） |
| 前提ドキュメント | [`architecture.md`](../architecture.md)（現行実装の権威）、[`moonbit-native-notes.md`](../moonbit-native-notes.md)（native バックエンドの実測挙動） |

本 RFC は、MoonBit 側アプリ記述を「`click_id` の手配線 + グローバル可変配列 + ハードコードされた再構築ループ」から、**再利用可能なコンポーネント・型付きハンドラ・宣言的リアクティブプリミティブ**へ引き上げる設計を定める。実装は含まない。すべてのコード片はスケッチであり、コンパイルされていない。

---

## 1. 背景と動機

現行の Counter デモ（`moonbit-bindings/app/app.mbt`）は「正しく動く」が、第三者がアプリを組むための抽象としては機能しない。問題は 4 点に集約される。

### 1.1 `click_id` の手配線（G11/G12）

クリック可能な div はそれぞれ生の `Int` である `click_id` を持ち（`gpui-bindings.mbt:152-158` の `set_on_click(click_id : Int)`）、アプリ側は定数を手工で割り当てる:

```moonbit
// app.mbt:34-43
const BTN_DECREMENT : Int = 1
const BTN_RESET : Int = 2
const BTN_INCREMENT : Int = 3
const BTN_INCREMENT_10 : Int = 4
```

そして `on_click` が巨大な int switch で意味を復元する:

```moonbit
// app.mbt:109-124
fn on_click(click_id : Int) -> Int {
  if click_id == BTN_DECREMENT { count[0] = count[0] - 1; 1 }
  else if click_id == BTN_RESET { reset_count() }
  else if click_id == BTN_INCREMENT { count[0] = count[0] + 1; 1 }
  else if click_id == BTN_INCREMENT_10 { count[0] = count[0] + 10; 1 }
  else { 0 }
}
```

ボタンを 1 つ追加するたびに「定数の追加 → `make_button` 呼び出し → `on_click` への分岐追加」という 3 箇所の同期編集が発生する。ノードとハンドラの対応がコード上に分散し、型による保証が何もない（存在しない id を分岐に書いてもコンパイルは通る）。

### 1.2 グローバル可変状態（G13）

状態はモジュールトップレベルの可変配列 1 個である:

```moonbit
// app.mbt:29
let count : Array[Int] = [0]
```

`Array[Int]` を使うのは、MoonBit のトップレベル `let` が不変束縛であるため、可変性を配列の要素更新で表現しているからである。これは本質的にシングルトンであり、2 つ目のカウンタ・2 つ目の view・再利用コンポーネントのローカル状態へスケールしない。`make_button`（`app.mbt:212-231`）が引数で `click_id` と色を受け取る「疑似コンポーネント」だが、props の型付けもローカル状態もなく、呼び出し側が `CommandBuffer` を直接操作する手続きのまま。

### 1.3 ハードコードされた再構築ループ（G14）

イベント処理と再構築の接着は `dispatch` 内に直書きされている:

```moonbit
// app.mbt:84-95
pub fn dispatch(version, kind, view, data_a, data_b) -> Int {
  let changed = apply_event(decode(version, kind, data_a, data_b))
  if changed == 1 {
    match build_tree(view) { ... }
  }
  changed
}
```

「どのハンドラが状態を変えたか」を各ハンドラが `0`/`1` の戻り値で手動報告し、`dispatch` がそれを集約して全ツリー再構築を起動する。状態変更の追跡がアプリ作者の責任であり、`changed` を返し忘れると UI が更新されない（サイレントバグ）。signal 等の宣言的プリミティブがなく、「状態が変わったら再描画」が框架ではなく慣習で成立している。

### 1.4 なぜスケールしないか

- **局所性の欠如**: ノード・ハンドラ・状態が 1 ファイルの別々の場所に散在し、コンポーネント単位で閉じない。
- **型保証の欠如**: id の取り違え、`changed` の返し忘れ、状態の書き漏れがすべて実行時バグになる。
- **再利用性の欠如**: `make_button` は `CommandBuffer` と生 id を要求するため、別のアプリで再利用するには内部実装（スタック操作）の知識が要る。
- **マルチ view/コンポーネントへの非拡張**: グローバル配列と単一 `build_tree(view)` は、view ごとに独立した状態を持つ構成（`G17`）と相性が悪い。

---

## 2. 制約

設計は MoonBit native バックエンドの実測挙動（`moonbit-native-notes.md`）と既存の ABI 契約（`architecture.md` §4）の範囲内になければならない。これらは本 RFC が動かせない前提である。

### 2.1 スカラー専用イベント envelope（ABI_VERSION=4）

Rust→MoonBit のコールバックは **1 つだけ**: `app.dispatch(version, kind, view, data_a, data_b) -> Int`。5 つの `i32` スロットがバージョニング済み envelope を運ぶ（`architecture.md` §4b）:

- slot 0 = `ABI_VERSION`（不一致なら `Unknown` を返して stale バイナリを拒否）
- slot 1 = event kind（`EVENT_CLICK=1` / `EVENT_KEY=2` / `EVENT_TEXT=3` / `EVENT_NAMED_KEY=4`）
- slot 2 = view id（`VIEWS` のインデックス、再構築対象のルーティング）
- slot 3–4 = kind 依存ペイロード（`EVENT_CLICK` なら `data_a = click_id, data_b = 0`）

**クロージャやオブジェクトは envelope を越えられない。** 64 ビットポインタは i32 スロットに収まらず、`EVENT_TEXT` が token+copy 方式（`gpui_event_copy_text`）を採用しているのはこのためである。ハンドラの識別子は必ず i32 に収まる整数でなければならない。

### 2.2 クロージャの C 互換 export は存在しない

`moonbit-native-notes.md` §6: MoonBit のクロージャは RC ヒープオブジェクト `{code ptr + 環境}` であり、C の関数ポインタ `void(*)()` ではない。非キャプチャのトップレベル関数のみ内部的に raw fn ptr 化できるが未公開。したがって:

- **Rust→MoonBit は「名前付きマングルシンボルを Rust から参照して呼ぶ」の一択。** `dispatch` が単一エントリであることは設計の自由ではなく強制である。
- **ハンドラのクロージャは MoonBit 側に留め、ABI を越えない。** Rust 側に渡すのは整数 id のみ。本 RFC のハンドラレジストリ（§3.2）はこの制約の直接の帰結である。

### 2.3 単一スレッド・非アトミック RC・total 関数義務

`moonbit-native-notes.md` §4: ランタイムは参照カウント方式（トレース GC ではない）で、RC は**非アトミック**。よってコールバックはメインスレッド限定。`run_window` でブロック中に同一スレッドから MoonBit 関数を呼ぶのはネストした C 呼び出しに過ぎず安全（再入可能）。また **MoonBit の例外は FFI 境界を越えられず panic は process-abort** になるため、`dispatch` を含む export 関数は total に保たなければならない。

含意: signal の通知・再構築はすべて `dispatch` 内の同期処理として完結し、並行性の考慮は不要。ただしハンドラ/再構築経路で panic してはならない（`build_tree` の `Err(status)` は既に値として処理される。`app.mbt:89-92`）。

### 2.4 コマンドバッファのワイヤ形式

UI ツリーは長さ区切りの opcode ストリーム 1 本（`CommandBuffer`、`gpui-bindings.mbt:40-213`）で記述し、`build_tree(view, cb)` **1 回の FFI** で送信・コミットする。スタックマシンであり、`div`/`text` が push、セッターはスタックトップに適用、`add_child` が child→parent の順に pop して parent を再 push、`set_root` がトップを pop する。`set_key(key)`（`gpui-bindings.mbt:164-167`、issue #9）は再構築を跨ぐ安定ノード識別子（GPUI `ElementId`）を設定し、重複は `build_tree` が拒否する。

含意: **現行の commit 単位はツリー全体**である。部分更新（サブツリー単位のパッチ）はワイヤ形式の拡張（新 opcode）を要し、#10 の管轄である。本 RFC のリアクティブ層（§3.4）は、この全体コミットを前提に設計し、将来の部分更新を阻害しないことを保証する。

### 2.5 retained + reactive 実行モデル

`architecture.md` §1/§3: MoonBit がツリーを構築して Rust が保存（retained）、状態変更コールバックがツリーを再構築して `1` を返し、Rust は `1` のときだけ `cx.notify()` する（reactive）。`0` なら再構築も notify もスキップ。この `0`/`1` 戻り値契約は ABI の一部であり、本 RFC も維持する。

---

## 3. 設計

4 つの層を、依存の順（下から）に定義する。

```
(d) signal + 選択的再構築  ← G14  （宣言的リアクティブ）
(c) state cell / store      ← G13  （型付き状態）
(b) handler registry        ← G12  （型付きハンドラ、id ↔ クロージャ）
(a) component               ← G11  （props を取る再利用可能ビルダー）
```

### 3.1 (a) コンポーネント抽象（G11）

**定義**: コンポーネントとは、props（外部から渡す値）と state（store 内の cell、§3.3）から `CommandBuffer` へサブツリーを出力する純粋関数である。retained + 全再構築モデル（§2.4）の下では、コンポーネントは「呼ばれるたびに同じ props/state から同じサブツリーを生成する」ことで十分であり、差分計算は不要である。

`CommandBuffer` がスタックマシンであるため、コンポーネントの契約は「呼び出し後にサブツリーのルートがスタックトップに残り、呼び出し側が `add_child` で親に接続できる」とする。これは現行 `make_button`（`app.mbt:212-231`）の挙動（ボタン div を push したまま返す）を一般化したものである。

```moonbit
// --- スケッチ（コンパイル対象外）---

/// props を持つコンポーネント。呼び出し後、サブツリー根がスタックトップに残る。
/// （型は概念。実際はコンポーネントごとに固有の props 構造体を定義する。）
struct ButtonProps {
  key : String        // 安定識別子（set_key に渡す。再構築を跨ぐ同一性）
  label : String
  r : Int; g : Int; b : Int
  on_click : HandlerId // 生の Int ではなくレジストリが発行する型付き id（§3.2）
}

fn button(cb : CommandBuffer, props : ButtonProps) -> Unit {
  cb.div()
  cb.set_key(props.key)
  cb.set_size(92.0, 56.0)
  cb.set_bg(props.r, props.g, props.b)
  cb.set_rounded(10.0)
  cb.set_flex_col()
  cb.set_center()
  cb.set_on_click(props.on_click.to_int()) // HandlerId は Int へ射す（§3.2）
  cb.text(props.label, 255, 255, 255, 18.0)
  cb.add_child() // ラベルをボタンへ。ボタンはトップに残る
}
```

**ローカル状態を持つコンポーネント**は、`key` で識別されるインスタンスごとに store 内の cell を確保する（§3.3）。レンダリング中は `RenderCtx` を介して store とハンドラレジストリにアクセスする:

```moonbit
// --- スケッチ ---
struct RenderCtx {
  view : Int
  store : Store          // §3.3
  handlers : HandlerRegistry // §3.2
}

/// 状態を持つコンポーネントの例。cell を key でスコープする。
fn counter_card(cb : CommandBuffer, ctx : RenderCtx) -> Unit {
  let cell = ctx.store.cell_for_key("counter-card", init=0) // key スコープの cell
  cb.div()
  cb.set_key("counter-card")
  cb.set_padding(16.0)
  cb.set_border(2.0, 120, 200, 255)
  cb.set_rounded(12.0)
  cb.text("Count: \{ctx.store.get(cell)}", 120, 200, 255, 44.0)
  cb.add_child()
}
```

**設計上の決定**:
- コンポーネントはクラスでもフックでもなく**関数**である。MoonBit に hooks/context の実行時基盤はなく、導入は過剰。props は構造体、副作用（ハンドラ登録・cell 確保）は `RenderCtx` 経由に限定する。
- `key` は再利用可能コンポーネントの同一性の要であり、`set_key`（issue #9）に直結する。将来の部分更新（#10）は `key` でサブツリーをアドレスするため、コンポーネントは必ず `key` を持つことを推奨する。
- 高階コンポーネント（子を受け取る）は、`children : (CommandBuffer) -> Unit` を props に持たせれば表現できる。本 RFC では必須としない。

### 3.2 (b) 型付きハンドラレジストリ（G12）

**核心**: クロージャは ABI を越えられない（§2.2）が、**整数 id は越えられる**。そこで、MoonBit 側にクロージャを登録して id を発行し、その id を `set_on_click` に渡す。`dispatch` は envelope の `(view, click_id)` をレジストリで引き、対応する型付きクロージャを起動する。`click_id` は「アクションの意味」から「レジストリのキー」へ役割が変わる。

```moonbit
// --- スケッチ（コンパイル対象外）---

/// ハンドラ id。中身は Int だが型で区別し、生の click_id と混同させない。
struct HandlerId { raw : Int }
fn HandlerId::to_int(self : HandlerId) -> Int { self.raw }

/// クリックハンドラ。view を受け、状態を変えたら signal を set する（§3.4）。
/// 戻り値は持たない — 「変わったか」は signal が知っている（§3.4 の設計決定）。
type ClickHandler = (view : Int) -> Unit

/// キーハンドラ（アプリ級。ノード級フォーカスモデルは G16/G19 隣接で本 RFC 対象外）。
type KeyHandler = (codepoint : Int, mods : Int) -> Unit
type NamedKeyHandler = (id : Int, mods : Int) -> Unit
type TextHandler = (text : String) -> Unit

struct HandlerRegistry {
  click : Map[Int, ClickHandler]
  key : Map[Int, KeyHandler]
  named_key : Map[Int, NamedKeyHandler]
  text : Map[Int, TextHandler]
  next_id : Int
}

/// クロージャを登録し、set_on_click に渡す id を発行する。
fn HandlerRegistry::on_click(self : HandlerRegistry, h : ClickHandler) -> HandlerId {
  let id = self.next_id
  self.next_id = id + 1
  self.click[id] = h
  { raw = id }
}

/// envelope を型付きハンドラへ配送する。dispatch から呼ばれる。
fn HandlerRegistry::dispatch_click(self : HandlerRegistry, view : Int, click_id : Int) -> Unit {
  match self.click[click_id] {
    Some(h) => h(view)
    None => () // 未知 id は no-op（現行 on_click の else 分岐に相当）
  }
}
```

**アプリ側の姿**（Counter の `-1` ボタン）:

```moonbit
// --- スケッチ: 現行 app.mbt:34, 109-112, 259 を置き換える ---
let dec_id = handlers.on_click(fn(_view) { count.set(count.get() - 1) })
button(cb, { key="btn-decrement", label="-1", r=200, g=80, b=80, on_click=dec_id })
```

`BTN_DECREMENT` 定数も `on_click` の int switch も消え、「このボタンのクリックで何が起きるか」が登録箇所に閉じる。

**設計上の決定**:
- **id はセットアップ時に一度だけ発行し、再構築ごとに再発行しない。** 再構築は `set_on_click` に同じ id を書き直すだけなので、レジストリの id ↔ クロージャ対応は安定する。id 発行が再構築のたびに走ると対応が壊れるため、発行はアプリ初期化時（または cell スコープの初回確保時）に限定する。
- **型付きデコードは envelope 側（`decode`、`app.mbt:55-81`）と協調する。** `decode` が `Event` enum を作り、レジストリが kind ごとに型付きハンドラを引く。`EVENT_TEXT` の token+copy（`gpui_event_copy_text`）は従来どおり `decode` 内で完了し、ハンドラには `String` が渡る。
- **キー/テキスト/名前付きキーのハンドラもレジストリで統一する**が、これらは現行ではフォーカスされた外側コンテナに届くアプリ級イベントである。ノード単位のキーフォーカスは GPUI 側のフォーカスモデル拡張（`G16`/`G19` 隣接）を要するため、本 RFC ではキー系は「アプリ級ハンドラの登録口」に留め、ノード単位とはしない。
- **view スコープ**: envelope は view id を運ぶ（§2.1）。レジストリを view ごとに分けるか、id を `(view, local_id)` でスコープするかは実装時の選択（`G17` と連動）。本 RFC は「view がハンドラ選択に関与できる」ことだけ定め、方式は固定しない。

### 3.3 (c) 状態モデル — cell と store（G13）

グローバル可変配列（`app.mbt:29`）を、**型付き cell を持つ store** で置き換える。cell は phantom type で値型を運び、store が異種格納を実現する。

```moonbit
// --- スケッチ（コンパイル対象外）---

/// 型付き状態セルの識別子。id は Int だが phantom type T で値型を固定する。
struct CellId[T] { raw : Int }

/// 異種状態の格納庫。バックエンドは Array[Any] + downcast、
/// または型別プールのいずれか（§6 未決）。API は型安全に見える。
struct Store {
  values : Array[Any]
  // signal 購読管理は §3.4 で追加される
}

fn Store::new_cell[T](self : Store, init : T) -> CellId[T] {
  let id = self.values.length()
  self.values.push(init as Any)
  { raw = id }
}

fn Store::get[T](self : Store, cell : CellId[T]) -> T {
  self.values[cell.raw] as T // downcast。型は CellId[T] が保証
}

fn Store::set[T](self : Store, cell : CellId[T], value : T) -> Unit {
  self.values[cell.raw] = value as Any
  // §3.4: この cell を購読する signal を dirty にする
}

/// key でスコープした cell を得る（コンポーネントのローカル状態用、§3.1）。
/// 初回呼び出しで確保し、以降は同じ cell を返す。
fn Store::cell_for_key[T](self : Store, key : String, init : T) -> CellId[T]
```

**Counter の状態**は次のように移行する:

```moonbit
// 現行: let count : Array[Int] = [0]            (app.mbt:29)
// 移行: let count : CellId[Int] = store.new_cell(0)
//       読み書きは store.get(count) / store.set(count, v)
```

**設計上の決定**:
- **cell は値の在処であり、コンポーネントは cell を所有しない。** コンポーネントは `key`（§3.1）で cell を参照する。これにより、再構築でコンポーネント関数が何度呼ばれても状態は store に留まる（retained モデルとの整合）。
- **view スコープは store の分割で表現できる。** `G17`（イベントの view ルーティング）が解決すれば、view ごとに store を持つか、cell id を `(view, local)` でスコープする。本 RFC は store の API を view 非依存に保ち、スコープ方針を実装時に選べるようにする。
- **`Any` + downcast のコスト**は、UI の状態変更頻度（人間の操作頻度）では無視できる。型別プールへの最適化は測定後に限る（`G26` のベンチ基盤が前提）。

### 3.4 (d) 宣言的リアクティブプリミティブ（G14）

`dispatch` 内の「`changed == 1` なら再構築」（`app.mbt:85-93`）を、**signal と自動再構築**で置き換える。ハンドラは「変わったか」を返さず、signal を `set` するだけにする。框架が dirty を検知して再構築し、`0`/`1` 契約（§2.5）を満たす。

```moonbit
// --- スケッチ（コンパイル対象外）---

/// 購読可能な状態。中身は store 内の cell。
struct Signal[T] {
  cell : CellId[T]
}

fn Signal::get(self : Signal[T]) -> T {
  // レンダリング中に呼ばれたら依存を記録する（§ 選択的再構築の準備）
  store.get(self.cell)
}

fn Signal::set(self : Signal[T], value : T) -> Unit {
  store.set(self.cell, value) // store が購読表から dirty セットを更新
}

/// フレームワークのイベントループ接着。dispatch を置き換える。
/// 0/1 契約は維持: signal が 1 つでも dirty なら再構築して 1 を返す。
fn framework_dispatch(version, kind, view, data_a, data_b) -> Int {
  if version != ABI_VERSION { return 0 }
  begin_dirty_tracking()                 // この dispatch 内の set を集める
  registry.dispatch(decode(version, kind, data_a, data_b), view)
  if has_dirty_signal() {
    rebuild(view)                        // 現行 build_tree(view)。§ 選択的再構築へ拡張可
    1
  } else {
    0
  }
}
```

**選択的再構築の段階設計**:

- **Phase 1（本 RFC の射程、ABI 変更なし）**: signal は「何かが変わった」の自動検知と再構築スケジューリングを提供する。再構築は**従来どおりツリー全体**（`build_tree(view)`、§2.4）。アプリ作者は `changed` を手動で返す必要がなくなり、`dispatch` のハードコードループ（`app.mbt:85-93`）は框架に移動する。価値は「宣言的になること」と「返し忘れバグの消滅」であり、ワイヤ効率の改善ではない。
- **Phase 2（将来、#10 と連動、要 ABI 拡張）**: signal の依存グラフを `key`（§3.1）でサブツリーに対応付け、dirty なサブツリーだけを再出力する。これには**部分パッチ opcode**（例: `key` でアドレスしたサブツリーを置換する `OP_UPDATE_SUBTREE`）が要る。本 RFC は Phase 2 を実装しないが、**コンポーネントが `key` を持ち・signal が cell を介在する**設計は、Phase 2 が `key` 単位で差分を計算する前提と整合する。つまり本 RFC は #10 の障害にならない。

**設計上の決定**:
- **1 dispatch 内の複数 `set` は 1 回の再構築にバッチする。** 再入は安全だが（§2.3）、同一 dispatch 内で再構築を複数回走らせる無駄を避ける。dirty 判定は dispatch 末尾で一度だけ行う。
- **再構築経路は total に保つ**（§2.3）。`build_tree` の失敗は `Err(status)` として扱い、panic にしない（現行 `app.mbt:89-92` の方針を継承）。
- **`get` 時の依存記録は Phase 2 までのオプション**であり、Phase 1 では「どれか 1 つでも dirty なら全体再構築」で十分。依存記録の実装有無は API を変えない。

---

## 4. ABI 影響

**結論: 本 RFC の射程（G11〜G14 Phase 1）では、新規 opcode も envelope フィールドも ABI 変更も不要である。**

| 要素 | 要否 | 根拠 |
|---|---|---|
| envelope（5×i32, ABI_VERSION=4, view スロット） | **変更なし** | ハンドラ id は `data_a` の `click_id`（i32）に収まる（§2.1, §3.2）。新イベント種別は不要。 |
| `OP_SET_ON_CLICK`（`click_id i32`） | **変更なし** | レジストリ発行 id を既存の `click_id` として渡す（§3.2）。 |
| `OP_SET_KEY` | **変更なし**（既存活用） | コンポーネント同一性（§3.1）と将来の部分更新（#10）のアドレスに使う。issue #9 で導入済み。 |
| 新規 opcode | **不要** | コンポーネント・store・signal はすべて MoonBit 側の抽象で、ワイヤ形式（§2.4）に触れない。 |
| `dispatch` の `0`/`1` 戻り値契約 | **変更なし** | signal の dirty 判定を框架が行い、契約を満たす（§3.4）。 |
| `gpui_event_copy_text`（token+copy） | **変更なし** | `EVENT_TEXT` のデコードは従来どおり `decode` 内で完了（§3.2）。 |

**将来（Phase 2 / #10）に必要な場合がある変更**（本 RFC では実施しない）:
- サブツリー部分パッチ opcode（`key` でアドレス）。`architecture.md` §4a のとおり opcode 追加は後方互換（未知 opcode は `UNKNOWN_OPCODE` で拒否されるだけ）なので、`BUFFER_VERSION` は既存 opcode の意味が変わらない限り bump 不要。
- これは本 RFC の設計（`key` によるコンポーネント識別、cell を介在する signal）と整合し、後戻りを強制しない。

---

## 5. 移行計画（Counter デモ）

既存の `app.mbt` を、依存の下位層から段階的に移行する。各段階は独立に価値を持ち、途中で止まっても壊れない。コードはすべてスケッチである。

### Phase A — ハンドラレジストリ（G12）

最小かつ即効性のある一歩。状態モデルには触れない。

1. `HandlerRegistry` と `HandlerId` を導入（§3.2）。
2. `BTN_*` 定数（`app.mbt:34-43`）を、セットアップ時の `handlers.on_click(...)` 登録に置換。
3. `on_click` の int switch（`app.mbt:109-124`）を `registry.dispatch_click(view, click_id)` に置換。`dispatch` は `decode` → レジストリ配送の形になる。
4. 验收: 4 ボタンが従来どおり動作し、`BTN_*` 定数と switch が消えている。

### Phase B — state cell / store（G13）

1. `Store` と `CellId[T]` を導入（§3.3）。
2. `let count : Array[Int] = [0]`（`app.mbt:29`）を `store.new_cell(0)` に置換。
3. 全 `count[0]` 参照を `store.get(count)` / `store.set(count, v)` に置換（`on_click` / `on_key` / `on_named_key` / `on_text` / `build_tree`）。
4. 验收: 状態が store 経由になり、トップレベル可変配列が消える。

### Phase C — コンポーネント化（G11）

1. `make_button`（`app.mbt:212-231`）を `ButtonProps` を取る `button(cb, props)` に置換（§3.1）。`click_id : Int` 引数は `on_click : HandlerId` になる。
2. `build_tree`（`app.mbt:234-274`）の即値コマンド列を、`counter_card(cb, ctx)` 等のコンポーネント呼び出しに分解する。
3. 验收: `build_tree` がコンポーネント呼び出しの並びになり、`CommandBuffer` の直接操作がコンポーネント内部に閉じる。

### Phase D — signal と自動再構築（G14）

1. `Signal[T]` と dirty 追跡を導入（§3.4）。
2. ハンドラを `store.set` ではなく `signal.set` 経由にし、`changed` 戻り値（`apply_event` / `on_*` の `0`/`1`、`app.mbt:98-205`）を全廃。
3. `dispatch` の `if changed == 1 { build_tree }`（`app.mbt:85-93`）を `framework_dispatch`（§3.4）に置換。
4. 验收: `changed` を返すコードがゼロになり、状態変更が自動的に再描画される。

### ロールアウト方針

- 各 Phase は独立 PR/issue を想定。A→B→C→D の順は依存（C は A の `HandlerId` と B の store を使う。D は B の cell を使う）による。
- `moonbit-bindings/README.mbt.md`（モジュールドキュメント）と `docs/architecture.md` は、各 Phase の完了時に当該節を更新する（`architecture.md` は現行実装の権威であるため、設計ではなく実装が確定した時点で反映する）。
- Phase 2（#10 の部分更新）は本移行の射程外。D 完了後にベンチ基盤（`G26`）を前提として別途設計する。

---

## 6. 未決事項

実装着手前に結論を得るべき問い。いずれも本 RFC の骨格は変えないが、API の細部を決める。

1. **store の異種格納バックエンド**: `Array[Any]` + downcast か、型別プールか。`Any` のボックス化コストと downcast の安全性を実測する（`G26` のベンチ基盤が要る。UI 操作頻度では無視できるという仮説）。
2. **ハンドラ id のスコープと view ルーティング**: レジストリを view ごとに分割するか、id を `(view, local_id)` でスコープするか。`G17`（イベントの view ルーティング）の結論と連動する。本 RFC は「view が選択に関与できる」ことのみ定める。
3. **キー系ハンドラのノード単位化**: 現行キーイベントはフォーカスされた外側コンテナに届くアプリ級。ノード単位のキーハンドラは GPUI 側のフォーカスモデル拡張（`G16`/`G19` 隣接）を要する。本 RFC はキー系をアプリ級に留めるが、将来のノード単位化時にレジストリ API を壊さない設計（`key` でハンドラを引く余地）を確認したい。
4. **コンポーネントの複数インスタンス（リスト）**: 同じコンポーネントが 2 回現れるとき、`key` をどう一意化する（`item-0`, `item-1` 等のパス）。これは #10 の部分更新アドレスと共通の課題。本 RFC は `key` 一意性を `set_key` の重複拒否（`architecture.md` §3）に委ねるが、リスト用の id 生成規約は別途定める。
5. **`get` 時の依存記録を Phase 1 で入れるか**: 「どれか dirty なら全体再構築」には不要。Phase 2 まで遅らせるのが最小だが、signal API の互換性を保ったまま後挿入できることを確認する（§3.4 の設計はこれを保証する）。
6. **`RenderCtx` の受け渡し方**: コンポーネントが `ctx` を明示引数で受けるか、レンダリング中の暗黙のコンテキストにするか。MoonBit に暗黙のコンテキスト機構はなく、明示引数が素直だが、入れ子コンポーネントでの伝播が冗長になりうる。

---

## 付録: 現行コードとの対応表

| 現行（`app.mbt` / `gpui-bindings.mbt`） | 本 RFC の対応 |
|---|---|
| `BTN_*` 定数（`app.mbt:34-43`） | `HandlerRegistry::on_click` の発行 id（§3.2） |
| `on_click` の int switch（`app.mbt:109-124`） | `registry.dispatch_click(view, click_id)`（§3.2） |
| `let count : Array[Int] = [0]`（`app.mbt:29`） | `store.new_cell(0)` → `CellId[Int]`（§3.3） |
| `count[0]` の直接更新（`app.mbt:111` 等） | `signal.set(...)` / `store.set(...)`（§3.3, §3.4） |
| `make_button(cb, key, label, click_id, r, g, b)`（`app.mbt:212-231`） | `button(cb, ButtonProps)`（§3.1） |
| `dispatch` の `if changed == 1 { build_tree }`（`app.mbt:85-93`） | `framework_dispatch` の dirty 判定 + 自動再構築（§3.4） |
| `apply_event` / `on_*` の `0`/`1` 戻り値（`app.mbt:98-205`） | 廃止。signal の dirty で代替（§3.4） |
| `set_on_click(click_id : Int)`（`gpui-bindings.mbt:152-158`） | 変更なし。レジストリ id を渡す（§3.2, §4） |
| `set_key(key : String)`（`gpui-bindings.mbt:164-167`） | 変更なし。コンポーネント同一性 + 将来の部分更新アドレス（§3.1, §4） |
