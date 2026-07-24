# Changelog

本プロジェクトのすべての注目すべき変更はこのファイルに記録する。
形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に従い、バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。
バージョニング方針の詳細は [`docs/versioning.md`](docs/versioning.md) を参照。

## [Unreleased]

### Added

- イベントの view 単位ルーティング: dispatch を 5 スロット envelope `app.dispatch(version, kind, view, data_a, data_b)` に拡張し、`ABI_VERSION` を 4 に bump（#49、24c3809）。
- `moonbit-bindings/moon.mod` のメタデータ整備（`description` / `repository` / `keywords`）と、バージョニング方針文書 `docs/versioning.md`（#48、G1 / G4）。
- コンポーネントモデルと状態管理の設計 RFC `docs/rfc/0001-component-model.md`（#50、G11–G14）。
- 消費者向け getting-started: `moonbit-bindings/README.md` 充填、`examples/hello` 追加、公開 API への `///|` doc comment（#55、G27–G29）。
- 構造化エラー `GpuiError` / `classify_status` / `status_message` / `expect_ok`、診断 `debug_dump_text`、MoonBit native 実行時制約の文書化（architecture.md §11）、`gpui_abi_probe` による自動 Int==i32 チェック（#54、G20–G23）。
- widget / style 体系の拡充（#51）: `Color` 型（alpha 付き、G9）、margin / min-max / flex / align / overflow / opacity / shadow / cursor / absolute / inset / per-side padding の 13 opcode（G7、15–27）、typography 7 opcode（text size/color/weight/line-height/align/whitespace/family、G8、28–34）、keyed `ScrollHandle` 保持による本物の scroll と `checkbox` / `labeled_row` 合成 widget（G6）。
- テスト基盤（#53）: gpui `test-support` によるヘッドレス layout golden テスト（G24）、in-crate シード PRNG ファジング + 任意の `fuzz/` scaffold（G25）、criterion ベンチ harness（G26）。
- キーボードナビゲーション: `OP_SET_FOCUSABLE` / `OP_SET_TAB_INDEX` / `OP_SET_TAB_STOP`（35–37）と Tab / Shift+Tab トラバース。a11y / IME の境界を `docs/a11y-ime.md` に文書化（#52、G18 / G19）。
- 計測で正当化したインクリメンタル更新: keyed in-place `gpui_update_text` FFI。24 行ツリーで full rebuild 比 約440x（11.4µs → 25.9ns）。汎用 vdom diff は意図的に未実装（#10）。

### Fixed

- テキストの空白パディング workaround を撤廃し、paint-time ¼px オフセット（`TextGlyphInset`）に置換。コンテンツ汚染を解消（#16、G10）。

## [0.1.0] - 2026-07-24

### Added

- パッケージング成立性スパイクの結論文書: `--moonbit-unstable-prebuild` で Rust staticlib 依存の配布が原理的に可能であることを検証（#47、403d189）。
- macOS 向け `.app` バンドル生成を `build.sh` に統合（#40 / #46、078e094）。
- `gpui_run_window` に view id を追加（#41 / #45、12db74e）。
- `OP_SET_PADDING` / `OP_SET_BORDER` スタイル opcode を追加。opcode の追加は後方互換（#42 / #44、4913925）。
- 名前付きキーを `EVENT_NAMED_KEY` で dispatch（#39 / #43、068f6f3）。
- `build_tree` / `run_window` のステータスを `Result[Unit, Int]` として伝播（#38、2d537b2）。
- ヘッドレスな MoonBit→C→Rust テキスト往復テスト（#34 / #37、e3de3bb）。
- バージョン付きイベント envelope と `EVENT_TEXT`（token+copy）サポート（#6 / #36、6847963）。
- 3 OS（ubuntu / macos / windows）のクロスプラットフォーム CI: コールドビルド、テスト、Rust 単独変更後の再ビルド（#33、0f5ce3b）。
- click id に依存しない安定ノードキー（#9、2885129）。
- 境界横断の ABI 定数 drift guard テスト（#8、39ebc5c）。
- property-per-call FFI を置換するバッチ化コマンドバッファ（#5、40f1f36）。
- 明示的 builder transaction と view ごとのノードストア（#4、19e7865）。
- 共有 ABI 定義（`abi.toml`）の強制とビルド時検証（#1、06a4818）。

### Fixed

- macOS の `native-static-libs` に欠けていた `-framework IOSurface` の追加（d646408）。
- Windows で `cargo rustc --print` の後に `cargo build` を実行し `gpui_sys.lib` の存在を保証（3ec1aba）。
- cargo 出力の ANSI コード除去、`-lc` / `-lm` の正規化、macOS の libm shim、システムライブラリ検索パスの注入など native リンクフラグの正規化（29d9be8、5f90439、b4f16cd、c30fe37、e57fae0、bbe1541、4c35d65）。
