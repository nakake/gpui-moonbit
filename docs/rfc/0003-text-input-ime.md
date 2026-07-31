# RFC 0003: テキスト入力 widget + IME preedit

| 項目 | 内容 |
|---|---|
| ステータス | 設計済み(実装未着手) |
| 作成日 | 2026-08-01 |
| 対象ギャップ | [`framework-gaps.md`](../framework-gaps.md) `G6`(text input widget)/ `G19`(IME preedit) |
| 関連 issue | #87(本 RFC)、#88(実装)、#52(フォーカス/Tab トラバース)、#86(RFC 0001 実装)、#91(rich text run) |
| 前提ドキュメント | [`a11y-ime.md`](../a11y-ime.md)(必要 API の調査完了)、[`architecture.md`](../architecture.md)、[`0001-component-model.md`](0001-component-model.md) |

本 RFC は、**編集可能なテキスト入力 widget** と **IME preedit(合成中テキスト)** の設計を定める。確定テキストは `EVENT_TEXT`(`key_char` 経路)で動作済みだが、編集可能ボックス・合成中表示・候補ウィンドウ連携は未設計だった。日本語入力はハーネスのプロンプト入力に必須である。実装は #88 の管轄であり、すべてのコード片はスケッチである。

---

## 1. 背景と gpui 側の前提(調査済みの事実)

`a11y-ime.md` §2.2 の調査で、必要な gpui 0.2.2 API は特定済みである(参照はすべて crates.io の `gpui-0.2.2/src/`):

- **`EntityInputHandler` trait**(`input.rs:10`)— プラットフォーム IME とテキストモデルの間の契約。`text_for_range` / `selected_text_range` / `marked_text_range` / `unmark_text` / `replace_text_in_range` / `replace_and_mark_text_in_range` / `bounds_for_range` / `character_index_for_point` の 8 メソッド。範囲はすべて **UTF-16 オフセット**である。
- **`Window::handle_input(focus_handle, input_handler, cx)`**(`window.rs:3400`)— paint 段階で登録。フォーカスされた要素に対してのみ有効。
- **`ElementInputHandler::new(bounds, entity)`**(`input.rs:78`)— `EntityInputHandler` 実装エンティティを `InputHandler` に適合させる標準アダプタ。
- **preedit 装飾**: `TextRun.underline`(`text_system.rs:733,743`)で合成中区間に下線を引ける(#91 の複数 run と同じ機構)。
- **カーソル/候補ウィンドウ位置**: `x_for_index` / `index_for_x`(`text_system/line_layout.rs:105,58`)でバイト位置 ↔ ピクセルを相互変換できる。`bounds_for_range` の実装に使う。
- **リファレンス実装**: gpui 同梱の `examples/input.rs` が「エンティティ所有のテキストモデル + `EntityInputHandler` + カスタム paint」の全体像を示す。#88 はこれを土台にする。

これらが要求する中核は**ステートフルな Rust 側テキストモデル**(buffer / selection / marked range を保持し、IME の同期クエリに即答できる状態)である。

## 2. 中核決定: Rust 側テキストモデルを正とする

issue #87 の第一の論点「どちらを正とするか」への回答: **Rust が正(source of truth)、MoonBit は明示的に読み書きする**(uncontrolled model)。

理由は制約の帰結である:

1. **IME クエリは同期・高頻度・文字列返し**である。`EntityInputHandler` の 8 メソッドはプラットフォーム IME からメインスレッドで同期に呼ばれ、`Option<String>` や `Range<usize>` を返す。MoonBit を正にすると、クエリごとに MoonBit を呼んで文字列を返す往復が要るが、Rust→MoonBit は単一の `mb_dispatch`(5×i32 スカラ)しかなく、**MoonBit から Rust へ文字列を「返す」経路は存在しない**(RFC 0001 §2.2)。逆方向のコールバック追加はマングルシンボル抽出の仕組み上 1 本に限定されている(`architecture.md` §4b)。
2. **preedit は本質的に Rust 側の状態**である。marked range は `replace_and_mark_text_in_range` で更新され、確定(`replace_text_in_range`)まで MoonBit のアプリ状態に属さない。合成中テキストをアプリ状態に混ぜると「確定前の値でアプリロジックが走る」事故を招く。
3. **`ScrollHandle` の前例**(`architecture.md` §3)。再構築を跨いで生存するメインスレッド専用状態は view エンティティ側に保持する、という既存パターンにそのまま従う。

含意: MoonBit の store(RFC 0001 §3.3)は入力値のミラーを持たず、**必要なときに pull する**(§3.5)。controlled input(MoonBit が毎キーストロークで値を検証・書き戻す形)は v1 では提供しない(§6-1)。

## 3. 設計

### 3.1 新ノード種別 `TextInput`

`UiNode` に第 3 の種別を追加する(現行は `Div` / `Text` の 2 種。`architecture.md` §3):

```
OP_TEXT_INPUT  u8 | input_id i32 | len u32 | utf8[len] (placeholder)
```

- **leaf ノード**である(子を持たない)。スタックマシン上は `OP_TEXT` と同様に push され、`add_child` で親 div に接続する。
- `input_id` は click_id と同格の **i32 識別子**で、envelope(§3.4)と読み書き ABI(§3.5)で widget を指す。RFC 0001 のハンドラレジストリが id を発行する形(§3.2)とそのまま噛み合う。
- スタイル(サイズ・枠・フォント)は**親 div のスタイル opcode をそのまま使う**。`TextInput` 自体はテキスト内容の描画と入力処理だけを担い、装飾は既存の style 表面に委ねる(新 opcode の増殖を避ける)。
- 同一 `input_id` のノードが再構築で再送されても、**テキストモデルは保持される**(§3.2)。`OP_TEXT_INPUT` のペイロードは placeholder(空欄時の薄表示)であり、初期値・現在値ではない(値の設定は §3.5 の `gpui_input_set_text`)。

### 3.2 Rust 側テキストモデルと保持先

```rust
// --- スケッチ ---
struct TextInputState {
    content: String,               // 確定済み全文 (UTF-8)
    selection: Range<usize>,       // UTF-16 オフセット (IME 契約に合わせる)
    marked: Option<Range<usize>>,  // preedit 区間 (UTF-16)
    focus: FocusHandle,
}
// FfiView 内 (scroll_handles と同居):
inputs: Rc<RefCell<HashMap<i32 /* input_id */, Entity<TextInputModel>>>>
```

- 保持先は `FfiView` の **view エンティティ内**(メインスレッド専用。`ScrollHandle` と同じ理由で `Mutex` 下のグローバルには置けない)。再構築を跨いで `input_id` で引き、初出時に生成する。
- ウィンドウ破棄で view エンティティごと解放される(寿命管理は gpui に委ねる)。
- モデル自体を小さな `Entity<TextInputModel>` にするのは `ElementInputHandler::new(bounds, entity)` が entity を要求するためで、`examples/input.rs` と同じ構成である。

### 3.3 描画と入力の配線

`render_node` が `TextInput` ノードに対して行うこと:

1. `input_id` でモデルを取得(なければ生成)し、テキストを **3 区間の run** で組む: 確定部 / preedit 部(下線付き `TextRun`)/ 確定部。選択範囲は背景 quad、カーソルは縦線 quad として paint する(`examples/input.rs` の方式)。
2. paint 段階で `Window::handle_input(&model.focus, ElementInputHandler::new(bounds, model.clone()), cx)` を登録する。
3. 要素はモデルの `focus` で focusable になり、**#52 の Tab トラバースにそのまま参加する**(`OP_SET_FOCUSABLE` 系の合成 id 経路とは独立に、モデル所有の `FocusHandle` を使う。key 未設定でもフォーカスが再構築を跨いで安定する — モデルが生存するため)。クリックでのフォーカス取得は `on_mouse_down` → `window.focus(&model.focus)`。
4. `EntityInputHandler` 実装は `TextInputState` を同期更新し、`replace_text_in_range`(確定)のタイミングで MoonBit へイベントを発火する(§3.4)。`replace_and_mark_text_in_range`(preedit 更新)は **Rust 内で完結**し、`cx.notify()` で再描画だけ起こす — 合成中は MoonBit に届かない(§2 の含意)。
5. `bounds_for_range` は `x_for_index` で候補ウィンドウのアンカー矩形を返す。OS がその位置に候補ウィンドウを出す。

### 3.4 MoonBit へのイベント(push)

`abi.toml` `[events]` に追加:

```toml
EVENT_INPUT_CHANGED = 6   # 確定テキストが変化した (IME 確定・タイプ・delete・set_text)
EVENT_INPUT_SUBMIT  = 7   # フォーカス中の input で Enter (改行を挿入しない単一行の既定動作)
```

envelope: `(ABI_VERSION, kind, view, input_id, 0)`。**ペイロードを運ばない**(§3.5 の pull で取得)。`EVENT_TEXT` の token+copy を使わないのは、変化通知のたびに全文を積むとペイロードが単調に肥大するためで(#70 の教訓)、「通知は軽く、取得は明示的に」へ倒す。

二重配送の遮断: 現行はルートコンテナの `on_key_down` が `key_char` を `EVENT_TEXT` として**アプリ級**に配送している(`architecture.md` §5)。text input がフォーカスを持つ間、同じ打鍵が (a) `handle_input` 経由で widget に入り、(b) `EVENT_TEXT` でアプリにも届く、の二重処理になる。**ルートの key/text 配送は、いずれかの `TextInputState.focus` がフォーカス中なら抑止する**(`focus.is_focused(window)` で判定)。`EVENT_NAMED_KEY` の Escape/矢印等も widget 編集(カーソル移動)と競合するため同様に抑止し、widget が処理しないキー(Tab は従来どおりトラバース)は素通しする。抑止の正確な範囲は #88 で確定する(§6-3)。

### 3.5 MoonBit からの読み書き(pull)

新しい C export(すべてメインスレッド前提 — `dispatch` 内から呼ぶ既存 ABI と同じ契約):

```c
// content の UTF-8 バイト長を返す (バッファ確保用)。負値は GPUI_STATUS_*
int32_t gpui_input_text_len(int32_t view, int32_t input_id);
// content を buf へコピーし、書き込んだバイト数を返す (gpui_event_copy_text と同じ契約)
int32_t gpui_input_copy_text(int32_t view, int32_t input_id, uint8_t *buf, int32_t len);
// content を差し替え、selection を末尾へ。preedit 中 (marked あり) は
// GPUI_STATUS_BUSY_COMPOSING を返して拒否する (合成を壊さない)
int32_t gpui_input_set_text(int32_t view, int32_t input_id, const uint8_t *ptr, int32_t len);
```

```rust
pub const GPUI_STATUS_BUSY_COMPOSING: i32 = -13; // RFC 0002 の -11/-12 に続く
```

MoonBit 側ラッパー(`gpui-bindings.mbt`)は `input_text(view, input_id) -> Result[String, Int]` / `input_set_text(...)` を提供し、len→copy の 2 段呼び出しを隠蔽する。典型的な利用は `EVENT_INPUT_SUBMIT` ハンドラ内で `input_text` を読み、`input_set_text("")` でクリアする(ハーネスのプロンプト送信そのもの)。

### 3.6 RFC 0001(コンポーネントモデル)との統合

issue #87 第 4 の論点「input widget の state 保持先」への回答: **buffer/selection/marked は Rust のテキストモデルに属し、store(RFC 0001 §3.3)には置かない。** store に置くのは「アプリが最後に pull した値」等のアプリ都合のミラーだけである。

```moonbit
// --- スケッチ: RFC 0001 の抽象で書いた input コンポーネント ---
struct TextInputProps {
  key : String            // 親 div の安定キー
  input_id : InputId      // レジストリ発行 (HandlerId と同様の型付き i32)
  placeholder : String
  on_submit : HandlerId   // EVENT_INPUT_SUBMIT → レジストリ配送
}

fn text_input(cb : CommandBuffer, props : TextInputProps) -> Unit {
  cb.div()
  cb.set_key(props.key)
  cb.set_border(1.0, 120, 120, 140)
  cb.set_rounded(6.0)
  cb.set_padding(8.0)
  cb.text_input(props.input_id.to_int(), props.placeholder) // OP_TEXT_INPUT
  cb.add_child()
}
```

- `HandlerRegistry` に `submit : Map[Int, SubmitHandler]` と `input_changed : Map[Int, ChangedHandler]` を追加し、`framework_dispatch` が `EVENT_INPUT_CHANGED` / `EVENT_INPUT_SUBMIT` を配送する(RFC 0001 §3.2 の kind 追加。構造変更なし)。
- **#86 への設計余地の要求は「Event enum と registry が kind 追加に閉じていないこと」のみ**であり、RFC 0001 の設計はこれを既に満たす(§3.2「キー/テキスト/名前付きキーのハンドラもレジストリで統一」)。#86 実装時に追加の考慮は不要である。

## 4. ABI 影響

| 要素 | 変更 | 後方互換性 |
|---|---|---|
| opcode | `OP_TEXT_INPUT`(38)を**追加** | 追加のみ。古い Rust は `UNKNOWN_OPCODE` で拒否(#42 方針)。`BUFFER_VERSION` 据え置き |
| `[events]` | `EVENT_INPUT_CHANGED = 6` / `EVENT_INPUT_SUBMIT = 7` を**追加** | 古い MoonBit は `Unknown`/0。`ABI_VERSION=4` 据え置き |
| C export | `gpui_input_text_len` / `gpui_input_copy_text` / `gpui_input_set_text` を**追加** | 追加のみ |
| status code | `-13` を**追加** | 負値の追加のみ |
| envelope / `[callback]` | **変更なし** | 5×i32 のまま |
| `EVENT_TEXT` | ワイヤ上は**変更なし**。text input フォーカス中はルート配送を抑止(挙動変更) | アプリ級 `EVENT_TEXT` は input 非フォーカス時は従来どおり |
| `UiNode` | `TextInput` 種別を**追加** | 内部表現。ABI 非該当 |

RFC 0002 と合わせて新 export が 4 本増える。**#71(ヘッダ生成デッドロック)の修正が実装の前提**である(#92 の推奨どおり)。

## 5. 実装計画(#88 のスコープ)

1. **テキストモデル + `EntityInputHandler`**: `TextInputModel` エンティティ、UTF-16/UTF-8 変換、`examples/input.rs` を参照実装として 8 メソッドを実装。
2. **`OP_TEXT_INPUT` + デコーダ + `render_node`**: leaf ノード追加、run 分割描画(確定/preedit 下線/カーソル/選択 quad)、`handle_input` 登録。
3. **フォーカス配線**: クリックフォーカス、Tab トラバース参加、ルート配送の抑止。
4. **イベント + 読み書き ABI**: `EVENT_INPUT_*`、`gpui_input_*` 3 本、MoonBit ラッパーと `Event` enum 拡張。
5. **テスト**: ヘッドレス(#53 基盤)で `EntityInputHandler` を直接呼び、preedit → 確定 → changed 発火 → pull の全系列を GUI なしで固定。`set_text` の合成中拒否、UTF-16/UTF-8 境界(サロゲートペア・絵文字)、二重配送の抑止。
6. **デモ + 3 OS 手動検証**: Counter デモに入力ボックスを足し、**日本語 IME(preedit 下線・候補ウィンドウ位置・確定)を macOS / Windows / Linux(fcitx/ibus)で手動確認**。
7. **ドキュメント**: `architecture.md`(§3 ノード種別・§4 ABI・§5 データフロー)、`a11y-ime.md` §2.2 を「実装済み」へ、`framework-gaps.md` G6/G19。

順序は 1 → 2 → 3 → 4 → 5 → 6 で段階 PR 可能。#86(コンポーネントモデル)とは独立に実装でき、§3.6 のコンポーネント化は #86 マージ後の薄い後付けで足りる。

## 6. 未決事項

1. **controlled input**: MoonBit が値を検証しながら毎打鍵で書き戻すモード。v1 は uncontrolled のみ(§2)。必要になった時点で `EVENT_INPUT_CHANGED` + `set_text` の組で近似できるが、IME 合成中の書き戻し(`BUSY_COMPOSING`)との相性を含めて別途設計する。
2. **複数行 / 折り返し**: v1 は単一行(ハーネスのプロンプト入力に十分)。複数行は wrap 計算とスクロールが要るため `G6` の別項として扱う。
3. **ルート配送抑止の正確な範囲**: 抑止するのは `EVENT_TEXT` / `EVENT_KEY` と、widget が消費する `EVENT_NAMED_KEY`(矢印・Backspace/Delete・Home/End・Escape)まで。Enter は `EVENT_INPUT_SUBMIT` に変換。この表は #88 で実測して確定し、`architecture.md` §5 に記載する。
4. **`input_id` の発行規約**: click_id と同じく「レジストリ発行 + 型付きラッパー」(RFC 0001)を推奨とするが、RFC 0001 実装(#86)前に #88 が完了した場合は生 i32 で暫定運用し、#86 で型を被せる。
5. **候補ウィンドウ位置の精度**: `bounds_for_range` は単一行前提なら `x_for_index` で正確に出せる。折り返し導入時に `line_layout` の行分解と合わせて再訪する。

---

## 付録: イベントフロー(日本語入力の 1 系列)

```
「にほんご」と打って変換・確定し Enter する場合:

打鍵 n → OS IME → replace_and_mark_text_in_range("ｎ", …)     [Rust 内で完結、再描画のみ]
…(合成が進む。preedit 下線付きで描画。MoonBit には届かない)…
変換候補選択 → replace_and_mark_text_in_range("日本語", …)      [同上]
確定       → replace_text_in_range("日本語")                    [content に反映]
             → mb_dispatch(4, EVENT_INPUT_CHANGED, view, input_id, 0)
             → (アプリが必要なら gpui_input_copy_text で pull)
Enter      → EVENT_INPUT_SUBMIT
             → ハンドラが input_text() で全文取得 → set_text("") でクリア → 1 を返す
```
