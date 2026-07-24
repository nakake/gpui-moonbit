# アクセシビリティと IME 合成 — 現状と境界

gpui 0.2.2 が実際に公開している API の範囲で、本ブリッジがどこまで対応でき、どこからが上流（gpui 本体）の制約で実現できないかを整理した文書。`docs/framework-gaps.md` の `G18`（a11y）と `G19`（IME）の詳細根拠をここに集約する。

**方針**: 事実（gpui のソース / 本リポジトリのコードで確認できるもの）を、該当するソース位置の参照とともに記す。gpui の参照は crates.io の `gpui-0.2.2` ソース（`src/`）に対するものである。

---

## 1. アクセシビリティ（a11y）

### 1.1 role / label / スクリーンリーダー — 上流ブロック（実装不能）

gpui 0.2.2 には、アクセシビリティの role・label・スクリーンリーダー連携に相当する API が**存在しない**。

- `Element` trait（`gpui-0.2.2/src/element.rs:51`）が要素に要求するのは `id()` / `request_layout()` / `prepaint()` / `paint()` のみである。role や accessible name、ARIA 相当の属性を要素に付与する手段が trait にも要素ビルダーにもない。
- div のインタラクティブ builder（`gpui-0.2.2/src/elements/div.rs`）を grep しても `role` / `label` / `aria` / `accessib*` に該当するメソッドは存在しない。

したがって「この div はボタンである」「この div の読み上げ名は X である」といった意味情報は gpui 0.2.2 では表現できず、本ブリッジからも送出できない。これは本プロジェクトの実装不足ではなく **gpui 上流の API 欠如**であり、gpui 側に該当 API が追加されない限り対応不能である。`framework-gaps.md` では `G18` として「role/label は上流ブロック、文書化済み」と記録する。

### 1.2 キーボードナビゲーション — 実装済み（issue #52）

gpui 0.2.2 はフォーカスと Tab トラバースの機構を**完全に公開**しており、本ブリッジはこれを配線済みである。

gpui 側の根拠:

- フォーカス builder（`gpui-0.2.2/src/elements/div.rs`）:
  - `.focusable()`（`div.rs:1043`、`StatefulInteractiveElement`）— 要素をフォーカス可能にする。
  - `.tab_index(index: isize)`（`div.rs:637`）— Tab 順序を設定し、同時に focusable かつ tab stop にする。
  - `.tab_stop(bool)`（`div.rs:628`）— tab index 順序には残しつつ、キーボードナビゲーションで到達できるかどうかを制御する。
- Tab トラバース本体（`gpui-0.2.2/src/window.rs`）:
  - `Window::focus_next()`（`window.rs:1413`）/ `Window::focus_prev()`（`window.rs:1424`）— 次の / 前の tab stop へフォーカスを移動する。
- フォーカスイベント（`gpui-0.2.2/src/window.rs`）:
  - `Window::on_focus_in()`（`window.rs:3481`）/ `Window::on_focus_out()`（`window.rs:3501`）— `FocusHandle` 単位で購読する。

本ブリッジの実装:

- **opcode**: `OP_SET_FOCUSABLE`(35) / `OP_SET_TAB_INDEX`(36) / `OP_SET_TAB_STOP`(37) を `gpui-sys/abi.toml` に追加（後方互換の追加分のみ、`ABI_VERSION` / `BUFFER_VERSION` のバンプなし、issue #42 方針）。Rust デコーダ（`gpui-sys/src/lib.rs`）がこれらを `UiNode::Div` の `focusable` / `tab_index` / `tab_stop` フィールドへ格納し、`render_node` が対応する gpui builder を適用する。
- **要素 id の要件**: `.focusable()` 等は `StatefulInteractiveElement` に属するため、要素が id（element state）を持つ必要がある。`render_node` は、キー（`set_key`）もクリック id（`set_on_click`）も持たないフォーカス可能 div に対し、毎レンダー一時 id（`gpui_focus:N`）を合成する（キーなしスクロール div と同じ方式）。**再構築をまたいでフォーカスを維持したい場合は `set_key` を付けること**（一時 id は毎レンダーリセットされる）。
- **Tab トラバース**: ルート要素の `on_key_down` ハンドラ（`gpui-sys/src/lib.rs`、`FfiView::render`）が `Tab` キーを捕捉し、`Shift` 修飾の有無で `Window::focus_prev()` / `Window::focus_next()` を呼び、Tab を MoonBit へは転送しない（トラバースはフレームワークが所有する）。Tab 以外のキーは従来どおり `EVENT_KEY` / `EVENT_NAMED_KEY` / `EVENT_TEXT` として配送される。
- **MoonBit API**: `CommandBuffer::set_focusable` / `set_tab_index` / `set_tab_stop`（`moonbit-bindings/gpui-bindings.mbt`）。

### 1.3 フォーカス可視化 — `.focus` スタイルで対応可（未配線）

gpui 0.2.2 はフォーカス時のスタイル変更を公開している:

- `.focus(f)`（`div.rs:1020`）— 要素そのものがフォーカスされたときのスタイル。
- `.in_focus(f)`（`div.rs:1030`）— フォーカスされた要素の内側にあるときのスタイル。

これらは `StyleRefinement` を取るため、本ブリッジの style 表面（`framework-gaps.md` `G7`）に focus 状態のスタイル opcode を追加すれば配線できる。現状、本 issue（#52）ではナビゲーション本体に集中し、フォーカスリングの描画は `G7` 側の style 拡張として扱う（未実装）。

### 1.4 フォーカスイベント（EVENT_FOCUS / EVENT_BLUR）— 見送り

`Window::on_focus_in` / `on_focus_out` は `FocusHandle` 単位の購読であり、`render_node` が各フォーカス可能 div に対して `FocusHandle` を生成・保持し、購読の `Subscription` をビューの寿命に紐付けて管理する設計が必要になる。本ブリッジの現状のイベント機構（5×`i32` envelope、`EVENT_CLICK` / `EVENT_KEY` / `EVENT_TEXT` / `EVENT_NAMED_KEY`）は、要素生成時に click_id をクロージャへキャプチャして配送する方式であり、フォーカス購読のライフサイクル管理とは噛み合わない。

加えて、キーなしフォーカス div の id は毎レンダー合成されるため、フォーカスイベントに載せる安定した node 識別子（click_id や key）が保証されない。

以上の理由から、本 issue では **EVENT_FOCUS / EVENT_BLUR を追加しない**。envelope / drift-guard を危険にさらす部分的な実装より、クリーンでテスト済みの部分集合（ナビゲーション本体）を優先する（issue の指示方針）。フォーカスイベントは、`FocusHandle` の保持と安定 id の設計を伴うテキスト入力 widget（#51c、`G6`）の実装時に合わせて検討する。

---

## 2. IME 合成

### 2.1 確定テキスト — 動作済み

IME で確定（コミット）されたテキストは既存の経路で動作している。

- ルート要素の `on_key_down` ハンドラが `ev.keystroke.key_char` を読み、`typed_text()`（`gpui-sys/src/lib.rs`）が確定文字列（IME 合成結果・マルチ文字キーを含む）を抽出して `EVENT_TEXT` として配送する。MoonBit 側は `gpui_event_copy_text` でペイロードを同期的にコピーする（`moonbit-bindings/app/app.mbt` の `decode` / `on_text`）。

### 2.2 preedit（合成中）/ 候補ウィンドウ — テキスト入力 widget へ繰延（#51c）

合成中のテキスト（preedit / marked text）や候補ウィンドウの制御は、gpui のテキスト入力機構そのものであり、以下が必要になる:

- `EntityInputHandler` trait の実装（`gpui-0.2.2/src/input.rs:10`）— `text_for_range` / `selected_text_range` / `marked_text_range` / `unmark_text` / `replace_text_in_range` 等、編集可能なテキストモデルを gpui とプラットフォーム IME の間に提供する。
- `Window::handle_input(focus_handle, input_handler, cx)`（`gpui-0.2.2/src/window.rs:3400`）— paint 段階で入力ハンドラを登録する。フォーカスされた要素に対してのみ有効。
- **ステートフルな Rust 側のテキストモデル** — 選択範囲・marked range・テキスト内容を保持し、再構築をまたいで生存する状態。

これはすなわち「編集可能なテキスト入力 widget」の実装そのものであり、`framework-gaps.md` の `G6`（widget 種の不足）で **#51c へ繰延済み**の項目である。本 issue（#52、a11y/IME の境界整理）の射程外であり、ここでは実装しない。

確定テキスト（2.1）は widget なしでも配送できているため、IME の「確定結果を受け取る」用途は現状で満たせる。「合成中の表示・候補選択」が必要な本格的なテキスト入力は、#51c のテキスト入力 widget として実装する。

---

## 3. まとめ

| 領域 | 状態 | 根拠 / 対応 |
|---|---|---|
| a11y: role / label / スクリーンリーダー | ❌ 上流ブロック | gpui 0.2.2 に API なし（`element.rs:51` の Element trait は id/layout/paint のみ） |
| a11y: キーボードナビゲーション | ✅ 実装済み（#52） | `focusable`/`tab_index`/`tab_stop`（`div.rs:1043/637/628`）+ Tab トラバース（`window.rs:1413/1424`） |
| a11y: フォーカス可視化 | ⏳ 対応可・未配線 | `.focus`/`.in_focus`（`div.rs:1020/1030`）、`G7` の style 拡張で対応 |
| a11y: フォーカスイベント | ⏭ 見送り | `on_focus_in/out`（`window.rs:3481/3501`）は FocusHandle 購読、安定 id とライフサイクル設計が必要。#51c で再検討 |
| IME: 確定テキスト | ✅ 動作済み | `key_char` → `EVENT_TEXT`（既存経路） |
| IME: preedit / 候補ウィンドウ | ⏭ #51c へ繰延 | `EntityInputHandler`（`input.rs:10`）+ `Window::handle_input`（`window.rs:3400`）+ ステートフルなテキストモデル = テキスト入力 widget（`G6`） |
