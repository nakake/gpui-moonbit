# Changelog

本プロジェクトのすべての注目すべき変更はこのファイルに記録する。
形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に従い、バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。
バージョニング方針の詳細は [`docs/versioning.md`](docs/versioning.md) を参照。

## [Unreleased]

### Added

- イベントの view 単位ルーティング: dispatch を 5 スロット envelope `app.dispatch(version, kind, view, data_a, data_b)` に拡張し、`ABI_VERSION` を 4 に bump（#49、24c3809）。
- `moonbit-bindings/moon.mod` のメタデータ整備（`description` / `repository` / `keywords`）と、バージョニング方針文書 `docs/versioning.md`（#48、G1 / G4）。

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
