# フレームワーク化に向けたギャップ分析

本プロジェクトを「ローカル向け実験」から**第三者が利用できるライブラリ/フレームワーク**へ発展させるにあたり、解決すべき内容を洗い出した分析文書。2026-07-23 時点のコード・`docs/architecture.md`・`docs/reviews/2026-07-16-codex-gpt5.6-sol.md` に基づく。各ギャップには後で issue 化しやすいよう安定 ID（`G1`〜）を付す。

**読み方の注意**: 事実（コード/ドキュメントで確認できるもの）と `[推測]` を区別する。特に §1 のパッケージング成立性はツールチェーン調査が未実施であり、本分析最大の不確実性である。

関連ドキュメント: [`architecture.md`](architecture.md)（現行実装）、[`roadmap.md`](roadmap.md)（進捗・現況）、[`reviews/2026-07-16-codex-gpt5.6-sol.md`](reviews/2026-07-16-codex-gpt5.6-sol.md)（codex アーキレビュー）。

---

## 0. 前提: codex レビューの P0/P1 はほぼ消化済み

2026-07-16 の codex レビューが挙げた改善項目は、その後の issue 対応で大部分が解決している。フレームワーク化の議論は、この土台の上に乗る。

| レビュー指摘 | 優先度 | 現状 | 対応 issue |
|---|---|---|---|
| ABI 不一致・stale/wrong callback 選択 | P0 | ✅ `abi.toml` からの定数生成 + drift guard + 最終バイナリの nm 検証 | — |
| C export の panic-safe 化・handle 検証 | P0 | ✅ status code 体系（`GPUI_STATUS_*`）・checked access・atomic commit | — |
| 絶対ビルドパスの除去 | P0 | ✅ 生成 `moon.pkg` + `native-static-libs` 自動取得・正規化 | — |
| builder transaction と明示 root | P1 | ✅ コマンドバッファ + `OP_SET_ROOT` + view 別 `VIEWS` | #5 |
| property-per-call → バッチ化ノード記述 | P1 | ✅ コマンドバッファ（1 FFI でツリー全体） | #5 |
| バージョン付きイベント envelope | P1 | ✅ slot 0 = `ABI_VERSION`、`EVENT_TEXT` は token+copy、named key 対応 | #39 |
| native ライブラリフラグの自動検証 | P1 | ✅ `cargo rustc --print native-static-libs` の捕捉・注入 | — |
| 境界横断統合テスト | P1 | ✅ ヘッドレス往復テスト + 3 OS CI | #34 |
| click ID に依存しない安定 ID | P2 | ✅ `OP_SET_KEY`（重複拒否） | #9 |
| **計測で正当化できるインクリメンタル更新** | P2 | ❌ 未着手 | #10 |
| **text 空白パディングのコンテンツ汚染** | P2 | ❌ 未着手 | #16 |

結論: 「正しく動く demo」の土台（ABI 契約・panic 安全性・ビルド再現性・テスト）は固い。残るのは**「第三者が使える」にするための軸**で、これは codex レビューの射程外だった。

---

## 1. パッケージング — ライブラリとして消費できない【最重要】

**現状、これはライブラリではなく「ビルドスクリプト付きリポジトリ」である。** 第三者が依存関係として追加し、自分のアプリからビルドする手段がない。

- **`G1` モジュールマニフェストがプレースホルダ。** `moonbit-bindings/moon.mod:12-26` は `name = "username/gpui-bindings"`、`repository = ""`、`description = ""`、`keywords = []`。このままでは mooncakes への公開・`moon add` による消費ができない。
- **`G2` ビルドがリポジトリ固有のドライバに依存。** Rust staticlib のリンク・マングルシンボル抽出・`native-static-libs` 注入はすべて `build.sh`/`build.ps1` の仕業で、**パッケージ機構で表現されていない**。利用者は `gpui-sys` の Rust ビルド + シンボル抽出 + リンクフラグ生成を自前で再現する必要がある。
- **`G3` [検証済み 2026-07-24] MoonBit native のパッケージ機構で Rust staticlib 依存の配布は原理的に可能。** `cc-link-flags` は依存から伝播しない（[moon#1595](https://github.com/moonbitlang/moon/issues/1595)）。唯一の経路は実験的機能 `--moonbit-unstable-prebuild`（`moon.mod` に登録した JS/Python スクリプトが依存として消費された場合でも実行され、LinkConfig の `link_libs`/`link_search_paths` が dependents へ伝播する）。2 モジュール構成で実機検証済み（[スパイレポート](spikes/2026-07-24-packaging-feasibility.md)）。リスク: API が「extremely experimental」で変更の可能性。フォールバックとしてテンプレートリポジトリ方式（現状の `build.sh`）を併記する。
- **`G4` バージョニング/release/changelog/semver が未整備。** C ABI（`abi.toml` の `ABI_VERSION`）と MoonBit モジュールバージョン（`moon.mod` の `0.1.0`）の関係が未定義。
- **`G5` macOS 配布用の署名・entitlement・icon・パッケージングがない。** codex §3。現状の `.app` バンドルは開発専用（`build.sh` の `--bundle`、issue #40）。

---

## 2. API 表現力 — widget / style 表面

フレームワークとしての最大の実機能ギャップ。現状の描画要素は **div と text のみ**（`moonbit-bindings/gpui-bindings.mbt`）。

- **`G6` widget 種の不足。** image / text input（編集可能ボックス）/ scroll / list（仮想化）/ stack（z-index）/ absolute 配置 / checkbox・toggle 等が皆無。
- **`G7` style 表面の不足。** 現状は `size / bg / flex(row|col) / center / gap / rounded / padding / border` のみ。margin、辺別 padding/border、min/max/auto サイズ、flex-grow/shrink/basis、align/justify、overflow、opacity、shadow、transform、cursor 指定がない。
- **`G8` typography の不足。** text は単一 size + 単一 color のみ。weight / line-height / align / wrap 制御 / font family / rich text（部分装飾）がない。
- **`G9` 色の抽象がない。** 全域が生の RGB `Int`（`set_bg(r, g, b)` 等）。alpha 通道なし、`Color` 型なし、テーマ/デザイントークンなし。
- **`G10` text 空白パディング hack。** `render_node` が全テキストを `format!(" {content} ")` で包み先頭グリフのサブピクセル欠けを回避（`docs/troubleshooting.md`）。パディングがコンテンツ本体を汚染し、将来の選択/コピー/計測 API を阻害する（issue #16）。

---

## 3. コンポーネントモデルと状態管理

- **`G11` コンポーネント抽象がない。** アプリは `click_id` の int を手配線し（`moonbit-bindings/app/app.mbt:108`）、状態はグローバル可変 `count : Array[Int]`（`app.mbt:28`）。props / local state / hooks / context / 再利用可能コンポーネントが皆無。
- **`G12` イベントルーティングが手動 int switch。** ノード単位の型付きハンドラ/クロージャを張れない。根因は MoonBit native の callback 制約（スカラーのみ、クロージャの C 互換 export がない、codex §2）。
- **`G13` 状態がグローバル可変配列。** 複数 view / 複数コンポーネントへスケールしない。
- **`G14` reactive ループが `dispatch` 内にハードコード。** `changed == 1 → ツリー再構築`（`app.mbt:85-93`）。signal 等の宣言的リアクティブプリミティブがない。

---

## 4. マルチウィンドウ / アプリライフサイクル

- **`G15` 単一ウィンドウ・永久ブロック実行。** `run_window` は 1 ウィンドウを開きイベントループでブロックする（`moonbit-bindings/cmd/main/main.mbt:14`）。複数ウィンドウ、非ブロッキング実行、アプリ級ループ、quit 処理がない。
- **`G16` ウィンドウ/アプリイベントの欠如。** resize / close / focus / menu / tray 等のイベント経路がない。
- **`G17` イベントが view 単位でルーティングされない。** `architecture.md:85`「dispatch の 4 スロットに view id は無い」。issue #41 で `run_window` に view id を追加したが、**イベント側の view ルーティングは未解決**。マルチ view 化すると dispatch の配送先が曖昧になる。後戻りしにくい ABI 変更なので、API 表面が膨らむ前に確定させるべき。

---

## 5. 堅牢性 / 本番品質

- **`G18` アクセシビリティ（a11y）が皆無。**
- **`G19` IME 合成 API が不十分。** `EVENT_TEXT` は確定テキストを運ぶが、preedit（合成中）イベント・候補ウィンドウ制御がない。
- **`G20` エラーのアプリ側露出が貧弱。** demo は `build_tree` 失敗を `println` するだけ（`app.mbt:90`）。アプリ作者向けの構造化エラー型/診断 API がない。
- **`G21` logging / diagnostics API がない。**
- **`G22` MoonBit native の実行時制約を API が強制も文書化もしていない。** callback は main-thread 限定かつ全関数である必要（非 atomic RC・panic は process-abort、codex §2）。
- **`G23` MoonBit `Int` == `i32` の ABI 互換が実験的前提。** 自動 ABI サイズチェックがない（codex §2）。`main.mbt:7` の型アノテーションは `moon check` 上のアンカーだが、ABI サイズ保証ではない。

---

## 6. テスト / QA（フレームワーク規模向け）

- **`G24` ヘッドレスなレイアウト/描画検証がない。** GUI なしで layout/style の出力を測れない。既存の往復テスト（issue #34）はテキスト忠実度のみ。golden / screenshot テストなし。
- **`G25` コマンドバッファデコーダの体系的ファジングがない。** 敵対的長は単体テスト済みだが、系統的ファジングではない。
- **`G26` 性能ベンチ/回帰 harness がない。** issue #10（インクリメンタル更新）の着手前提。

---

## 7. ドキュメント / DX

- **`G27` 消費者向け getting-started がない。** `README.md` はリポジトリビルダー向け。counter 以外の example がない。
- **`G28` API リファレンスがない。** `///|` doc comment はあるが生成ドキュメントサイトがない。`architecture.md` は AI 向け内部文書。
- **`G29` `moonbit-bindings/README.md` が空（0 バイト）。**

---

## クリティカルパス（推奨順序）

「ライブラリ/フレームワークを目指す」なら、機能追加より**消費可能性の確立**が先。

1. **~~【調査・最優先】`G3` パッケージングの成立性。~~** ✅ 検証済み（2026-07-24）。`--moonbit-unstable-prebuild` で成立。[スパイレポート](spikes/2026-07-24-packaging-feasibility.md)参照。次のアクション: 実際の gpui-sys で prebuild スクリプトのプロトタイプ実装（#48 の G2 に接続）。
2. **`G17` マルチ view/ウィンドウのイベントルーティング。** view id をイベント envelope に載せる。後戻りしにくい ABI 変更なので、API 表面が膨らむ前に確定。
3. **`G11`〜`G14` コンポーネント/状態抽象の設計。** click_id int 配線とグローバル可変状態を再利用可能な層へ。フレームワークの骨格。
4. **`G6`〜`G10` API 表現力の拡充** と **`G18`/`G19` a11y/IME。** 3 の抽象の上に乗せる。
5. **`G24`〜`G26` テスト基盤**（ヘッドレス layout 検証・ベンチ）。4 と #10 の安全網。
6. **`G1`/`G2`/`G4`/`G5`/`G27`〜`G29` 配布整備**（マニフェスト・署名・semver・docs・example）。

既存の残り issue は自然に合流する: **#10（インクリメンタル更新）は 5 のベンチ後**、**#16（text padding = `G10`）は 4 のテキスト API 設計時**。

---

## 起票の目安

各 `G*` を issue 化する際の粒度案:

- 単独 issue 向き: `G1`（マニフェスト整備）、~~`G3`（パッケージング調査・スパイク）~~ ✅ 完了（#47）、`G17`（view ルーティング ABI）、`G29`（空 README）。
- 設計 RFC 向き（単一 issue では大きすぎる）: `G11`〜`G14`（コンポーネントモデル）、`G6`〜`G9`（widget/style 体系）。
- 既存 issue に統合: `G10` → #16、`G26` → #10 の前提。
