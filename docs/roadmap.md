# GPUI + MoonBit ロードマップ

## 現況 (2026-07-19)

この節は 2026-07-19 時点の現行状況であり、後続のフェーズ一覧と進捗メモは当時の計画・履歴として保持する。

### 実装済み
- retained UI と MoonBit 側の Counter (`-1` / `Reset` / `+1` / `+10`)。
- click/key callback。コールバック ABI は固定の `app.dispatch(kind, id, a, b)` (4 × `i32`) で、実マングル表記のみを build driver が自動検出する。
- `abi.toml` からの共有 ABI 定数生成、C ヘッダーからの MoonBit FFI 生成・検証、および macOS/Linux/Windows の build 経路。
- Windows と WSL/Linux は 2026-07-19 に手動検証済み。macOS は最近再検証していない。

### 未完了
- 安定した利用者向け API と、より広い GPUI surface。
- アクティブな root CI（現在は無い）。
- Web/WASM を含む将来の展開。

## 目標
MoonBit から GPUI を呼び出して、ネイティブ GPU アクセラレーション UI を構築する。

## フェーズ 1: gpui-sys (C FFI ラッパー)
**期間**: 1-2ヶ月  
**目的**: GPUI の主要 API を C ABI で公開する Rust クレートを作る

### タスク
- [ ] GPUI のコア API 調査 (Entity, View, Element, App)
- [ ] cbindgen で C ヘッダー自動生成の設定
- [ ] 基本 API の FFI ラッパー実装
  - [ ] アプリケーション起動 (`gpui_app_run`)
  - [ ] ウィンドウ作成 (`gpui_open_window`)
  - [ ] 基本的な要素 (`gpui_div_*`)
  - [ ] テキスト描画 (`gpui_text`)
  - [ ] イベントハンドリング
- [ ] サンプルプログラムで動作確認

### 成果物
- `gpui-sys` クレート (Rust)
- `include/gpui_sys.h` (C ヘッダー)
- 動作するデモアプリ

---

## フェーズ 2: MoonBit バインディング
**期間**: 1ヶ月  
**目的**: MoonBit から gpui-sys を呼び出すバインディング層を作る

### タスク
- [ ] MoonBit の extern "C" で gpui-sys の関数を宣言
- [ ] 高レベル API の設計 (宣言的 UI DSL)
- [ ] サンプルアプリ作成
- [ ] ドキュメント整備

### 成果物
- MoonBit パッケージ `gpui-bindings`
- Hello World デモ
- 基本的な UI コンポーネント

---

## フェーズ 3: gpui_web への貢献
**期間**: 継続  
**目的**: GPUI の Web 対応を推進し、MoonBit WASM 連携も視野に入れる

### タスク
- [ ] Zed Discord に参加して現状把握
- [ ] 小さな PR から始める (ドキュメント、example)
- [ ] PR #59583 (アプリ起動維持) のレビュー・貢献
- [ ] テキスト描画の Web 対応
- [ ] MoonBit WASM → gpui_web の実験

### 成果物
- gpui_web への PR マージ実績
- MoonBit WASM で動く GPUI デモ (将来的)

---

## 参考リンク
- GPUI: https://github.com/zed-industries/zed/tree/main/crates/gpui
- gpui_web: https://github.com/zed-industries/zed/tree/main/crates/gpui_web
- MoonBit: https://www.moonbitlang.com
- Zed Discord: https://zed.dev/community-links

---

## 進捗メモ
- 2026-07-14: プロジェクト初期化完了
- 2026-07-14: gpui-sys ビルド成功 (gpui v0.2.2)
- 2026-07-14: MoonBit FFI バインディング動作確認完了
  - `extern "C"` で gpui-sys の関数を呼び出し成功
  - `moon run cmd/main` で `gpui_px()` と `gpui_rgb()` が正常に動作
- 2026-07-14: **Hello World デモ完成!**
  - `gpui_run_simple_window()` でウィンドウ表示成功
  - C スタブファイルで MoonBit String → C const char* 変換を実現
  - ウィンドウが開いてイベントループが動作確認済み
- 2026-07-14: **ネストしたUIツリーデモ完成!** (フェーズ 1 完了)
  - ハンドルベースのビルダー API を実装
  - `create_div()`, `set_bg()`, `set_flex_row/col()`, `set_center()`, `set_gap()`, `set_rounded()`
  - `create_text()` でテキストノード作成
  - `add_child()` でネストしたUIツリーを構築
  - 600x500 のウィンドウに以下を表示:
    - タイトルテキスト ("GPUI + MoonBit")
    - サブタイトル
    - 5色のカラーボックス (Red, Green, Blue, Yellow, Purple)
    - フッターテキスト
  - Metal GPU レンダリングで動作確認済み
- 2026-07-15: **テキスト描画の不具合を修正** (詳細は `troubleshooting.md`)
  - **旧 ABI の記録**: String が先頭1文字に切れる問題。MoonBit native の String は UTF-16 非NUL終端であり、当時は UTF-8+NUL の `Bytes` へ変換していた。現行は NUL を使わない ptr+len の borrowed `Bytes` ABI。
  - 先頭グリフの左端が1px欠ける問題: taffy の整数丸めで先頭グリフが subpixel 0 になる GPUI 特性。前後に空白を挟んで回避
- 2026-07-16: **対話機能 (クリック → 再描画) 完成!** — 実機でクリック挙動まで確認済み
  - アーキテクチャ: MoonBit が `fn main` を維持し、gpui-sys を静的 `.a` でリンク。クリック時の Rust→MoonBit 呼び出しは MoonBit のマングルシンボルを参照(反転案は MoonBit native の foreign_library 出力未成熟で却下)
  - `gpui_set_on_click` / `gpui_reset` を追加、`render_node` に GPUI の `on_click` リスナ配線、`cx.notify()` で再描画
  - 対話ロジックは MoonBit 側 (`app` パッケージ) に実装
  - **イベントは単一 dispatch + スカラ payload** (`dispatch(kind, id, a, b)`): FFI 表面を1シンボルに固定し、種別/ボタンは MoonBit 側だけで拡張。`Event` enum で型付き分岐
  - **クリックカウンタ (複数ボタン)**: `-1 / Reset / +1 / +10` の4ボタン。ボタン追加は MoonBit のみ(Rust/FFI 変更なし)
  - **旧説明の注記**: `build.sh` は MoonBit のマングル名を `nm` で抽出し、`build.rs` が `#[link_name]` extern を生成する。現行で自動追従するのは実マングル表記だけであり、改名・引数数・型・ABI 方針には自動追従しない。
  - 低レベル仕様の観測は `moonbit-native-notes.md` に蓄積
- 2026-07-16: **キーイベント対応 完成!** — k / j / r で +1 / -1 / reset(実機確認済み)
  - `FfiView` に `FocusHandle`、ルートに `track_focus` + `on_key_down`、**ビュー構築時に `window.focus`**(render 内フォーカスでは OS の first-responder が立たない)
  - 単一文字キーは codepoint を payload の `a` に載せ `mb_dispatch(EVENT_KEY, 0, code, mods)`(FFI は単一 dispatch のまま)。意味づけは MoonBit `on_key`
  - **macOS 固有の当時の要件**: キーボードには `.app` バンドルが必要だった。非バンドルのターミナル起動バイナリには macOS がキーボードを配送しない(マウスは届く)。`bundle.sh` で最小バンドル化 → `open dist/Counter.app` or 直接実行。この要件を Linux/Windows に一般化しない（Windows の素の exe ではキー入力を確認済み）。
  - IMK ログ(`IMKCFRunLoopWakeUpReliable`)は IME 全角モードで出るが無害
  - **build.sh の再リンク修正**: moon は外部 `libgpui_sys.a` を追跡しないため、gpui-sys だけ変更しても exe が再リンクされず古いバイナリが残っていた(キーが効かない主因)。step 4 で link 成果物を削除して強制再リンクするよう修正
