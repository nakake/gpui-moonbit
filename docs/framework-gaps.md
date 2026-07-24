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
| **text 空白パディングのコンテンツ汚染** | P2 | ✅ #16 解決済み: 空白パディングを撤廃し、paint-time の ¼px 描画オフセット（`TextGlyphInset`）で先頭グリフのサブピクセル欠けを回避 | #16 |

結論: 「正しく動く demo」の土台（ABI 契約・panic 安全性・ビルド再現性・テスト）は固い。残るのは**「第三者が使える」にするための軸**で、これは codex レビューの射程外だった。

---

## 1. パッケージング — ライブラリとして消費できない【最重要】

**現状、これはライブラリではなく「ビルドスクリプト付きリポジトリ」である。** 第三者が依存関係として追加し、自分のアプリからビルドする手段がない。

- **`G1` [完了 2026-07-25] モジュールマニフェスト整備。** `moonbit-bindings/moon.mod` の `description` / `repository` / `keywords` を埋め、`moon check` 通過を確認（#48）。
- **`G2` [保留] ビルドがリポジトリ固有のドライバに依存。** Rust staticlib のリンク・マングルシンボル抽出・`native-static-libs` 注入はすべて `build.sh`/`build.ps1` の仕業で、**パッケージ機構で表現されていない**。利用者は `gpui-sys` の Rust ビルド + シンボル抽出 + リンクフラグ生成を自前で再現する必要がある。保留理由: prebuild パイプラインの実装は別トラック（#48 の G2）で扱う。
- **`G3` [検証済み 2026-07-24] MoonBit native のパッケージ機構で Rust staticlib 依存の配布は原理的に可能。** `cc-link-flags` は依存から伝播しない（[moon#1595](https://github.com/moonbitlang/moon/issues/1595)）。唯一の経路は実験的機能 `--moonbit-unstable-prebuild`（`moon.mod` に登録した JS/Python スクリプトが依存として消費された場合でも実行され、LinkConfig の `link_libs`/`link_search_paths` が dependents へ伝播する）。2 モジュール構成で実機検証済み（[スパイレポート](spikes/2026-07-24-packaging-feasibility.md)）。リスク: API が「extremely experimental」で変更の可能性。フォールバックとしてテンプレートリポジトリ方式（現状の `build.sh`）を併記する。
- **`G4` [完了 2026-07-25] バージョニング方針の整備。** [`versioning.md`](versioning.md) で `ABI_VERSION`（現在 4）とモジュール/クレート semver（現在 0.1.0）の関係・バンプ規則・changelog 方針・リリースチェックリストを定義し、[`CHANGELOG.md`](../CHANGELOG.md) を導入（#48）。
- **`G5` [保留] macOS 配布用の署名・entitlement・icon・パッケージングがない。** codex §3。現状の `.app` バンドルは開発専用（`build.sh` の `--bundle`、issue #40）。保留理由: 署名・配布整備は別トラックで扱う。

---

## 2. API 表現力 — widget / style 表面

フレームワークとしての最大の実機能ギャップ。現状の描画要素は **div と text のみ**（`moonbit-bindings/gpui-bindings.mbt`）。

- **`G6` widget 種の不足。** image / text input（編集可能ボックス）/ scroll / list（仮想化）/ stack（z-index）/ absolute 配置 / checkbox・toggle 等。✅ #51 part 3 で gpui 0.2.2 で実現可能な範囲を充足: **scroll** — `OP_SET_OVERFLOW` の `SCROLL` 軸が実際のスクロールになり、`render_node` が保持された `ScrollHandle` を割り当てる。`set_key` 付き div は再構築をまたいでスクロール位置を維持（ハンドルは `Rc` ベースで `Send` でないため、`Mutex` 下の `VIEWS` ではなく view ごとの `FfiView.scroll_handles` に保持。キーなしスクロール div は毎再構築で先頭に戻る）。**checkbox** — `moonbit-bindings/widgets.mbt` の合成ヘルパー `checkbox`（☐/☑ グリフ＋ラベル＋`set_on_click`、既存 opcode のみで ABI 変更なし）。`labeled_row` も追加。**stack（z-index）** — 新規 opcode 不要: gpui は子をペイント順に描画し、絶対配置の兄弟はペイント順で重なるため、`set_absolute`＋`set_inset`（part 1）＋子の追加順がそのまま z-index 相当になる。**absolute 配置** — part 1 で充足（`OP_SET_POSITION`/`OP_SET_INSET`）。未実装（前提条件あり）: **image/svg** — パス/バイト列からの `ImageSource` を生成するアセットパイプラインが必要。**text input（編集可能）** — `EntityInputHandler`＋`Window::handle_input`＋フォーカス/IME 配線が必要（#52 の IME 作業で対応）。**list（仮想化）** — gpui の `list`/`uniform_list` は Rust の render callback を要求し、スカラのコマンドバッファではブリッジ不能なため恒久的に見送り。
- **`G7` style 表面の不足。** 現状は `size / bg / flex(row|col) / center / gap / rounded / padding / border` のみ。margin、辺別 padding/border、min/max/auto サイズ、flex-grow/shrink/basis、align/justify、overflow、opacity、shadow、transform、cursor 指定がない。✅ #51 part 1 で margin・min/max サイズ・flex-grow/shrink/basis・align/justify・overflow・opacity・shadow・cursor・absolute 配置+inset を追加（`OP_SET_MARGIN`/`OP_SET_MIN_SIZE`/`OP_SET_MAX_SIZE`/`OP_SET_FLEX_ITEM`/`OP_SET_ALIGN`/`OP_SET_OVERFLOW`/`OP_SET_OPACITY`/`OP_SET_SHADOW`/`OP_SET_CURSOR`/`OP_SET_POSITION`/`OP_SET_INSET`）。未実装: 辺別 padding/border（均一のみ）、transform（gpui 0.2.2 に Style レベルの transform フィールドが無いため意図的に見送り）。
- **`G8` typography の不足。** text は単一 size + 単一 color のみ。weight / line-height / align / wrap 制御 / font family / rich text（部分装飾）がない。✅ #51 part 2 で font size・text color（alpha 付き）・font weight・line height・text align・whitespace（折り返し制御）・font family を追加（`OP_SET_TEXT_SIZE`/`OP_SET_TEXT_COLOR`/`OP_SET_FONT_WEIGHT`/`OP_SET_LINE_HEIGHT`/`OP_SET_TEXT_ALIGN`/`OP_SET_WHITESPACE`/`OP_SET_FONT_FAMILY`）。いずれも div の `Style.text` に設定され子孫テキストへ継承される。制限: gpui 0.2.2 の enum 制約で `TEXT_ALIGN_JUSTIFY` は左揃えに、`WHITESPACE_PRE`/`PRE_WRAP` は NOWRAP/NORMAL にフォールバック。未実装: rich text（部分装飾）— `StyledText::with_highlights` は 1 テキストノード内の複数 run 設計が必要なため先送り。
- **`G9` 色の抽象がない。** 全域が生の RGB `Int`（`set_bg(r, g, b)` 等）。alpha 通道なし、`Color` 型なし、テーマ/デザイントークンなし。✅ #51 part 1 で `Color` 型（`rgb`/`rgba` + 命名プリセット）と alpha 付きの `set_bg_color`（`OP_SET_BG_COLOR`）を追加。既存の `set_bg(r, g, b)` は後方互換で維持。未実装: テーマ/デザイントークン。
- **`G10` text 空白パディング hack。** #16 解決済み: `render_node` の `format!(" {content} ")` を撤廃し、paint-time 専用の `TextGlyphInset`（prepaint 原点を ¼px 右オフセット、レイアウト・コンテンツは不変）で先頭グリフのサブピクセル欠けを回避（`docs/troubleshooting.md` §2）。

---

## 3. コンポーネントモデルと状態管理

- **`G11` コンポーネント抽象がない。** アプリは `click_id` の int を手配線し（`moonbit-bindings/app/app.mbt:108`）、状態はグローバル可変 `count : Array[Int]`（`app.mbt:28`）。props / local state / hooks / context / 再利用可能コンポーネントが皆無。 **RFC**: [`docs/rfc/0001-component-model.md`](rfc/0001-component-model.md) 設計済み、実装未着手。
- **`G12` イベントルーティングが手動 int switch。** ノード単位の型付きハンドラ/クロージャを張れない。根因は MoonBit native の callback 制約（スカラーのみ、クロージャの C 互換 export がない、codex §2）。 **RFC**: [`docs/rfc/0001-component-model.md`](rfc/0001-component-model.md) 設計済み、実装未着手。
- **`G13` 状態がグローバル可変配列。** 複数 view / 複数コンポーネントへスケールしない。 **RFC**: [`docs/rfc/0001-component-model.md`](rfc/0001-component-model.md) 設計済み、実装未着手。
- **`G14` reactive ループが `dispatch` 内にハードコード。** `changed == 1 → ツリー再構築`（`app.mbt:85-93`）。signal 等の宣言的リアクティブプリミティブがない。 **RFC**: [`docs/rfc/0001-component-model.md`](rfc/0001-component-model.md) 設計済み、実装未着手。

---

## 4. マルチウィンドウ / アプリライフサイクル

- **`G15` 単一ウィンドウ・永久ブロック実行。** `run_window` は 1 ウィンドウを開きイベントループでブロックする（`moonbit-bindings/cmd/main/main.mbt:14`）。複数ウィンドウ、非ブロッキング実行、アプリ級ループ、quit 処理がない。
- **`G16` ウィンドウ/アプリイベントの欠如。** resize / close / focus / menu / tray 等のイベント経路がない。
- **`G17` ~~イベントが view 単位でルーティングされない。~~** ✅ #49 解決済み（2026-07-25）: dispatch envelope を 5 スロット `(abi_version, event_kind, view, data_a, data_b)` に拡張（`ABI_VERSION=4`）。slot 2 が view id を運び、`app.dispatch` は view 単位で rebuild をルーティングする。

---

## 5. 堅牢性 / 本番品質

- **`G18` アクセシビリティ（a11y）が皆無。**
- **`G19` IME 合成 API が不十分。** `EVENT_TEXT` は確定テキストを運ぶが、preedit（合成中）イベント・候補ウィンドウ制御がない。
- **~~`G20` エラーのアプリ側露出が貧弱。~~** ✅ #54 解決済み: `GpuiError` enum + `classify_status` / `status_message` / `expect_ok` を追加し、demo の `println`・`abort` を構造化メッセージに置換。
- **~~`G21` logging / diagnostics API がない。~~** ✅ #54 解決済み: `status_message`（コードごとの 1 行診断）と `debug_dump_text(view)` ラッパを公開。
- **~~`G22` MoonBit native の実行時制約を API が強制も文書化もしていない。~~** ✅ #54 解決済み: `docs/architecture.md`「MoonBit native 実行時制約」と `moonbit-bindings/README.md` 制約・注意に文書化（codex §2 を引用）。
- **~~`G23` MoonBit `Int` == `i32` の ABI 互換が実験的前提。~~** ✅ #54 解決済み: `gpui_abi_probe` の境界値往復（round-trip、ビルドのたび実行）+ 32-bit wrap セマンティクスの wbtest で機械的に検証。

---

## 6. テスト / QA（フレームワーク規模向け）

- **~~`G24` ヘッドレスなレイアウト/描画検証がない。~~** ✅ #53 解決済み: `gpui-sys/src/headless.rs` ハーネス（`test-support` 時のみコンパイル、staticlib には漏れない）が実デコーダ → 実 `render_node` で headless `TestAppContext` に描画し、gpui の `debug_bounds` でジオメトリを読み戻す。`headless_tests.rs` に golden layout テスト（sized div / flex-row+gap / padding+border / テキストノードの既知サイズ）を配置。`NoopTextSystem`（advance 0.6·size、line height `phi()`）で決定的に再現。
- **~~`G25` コマンドバッファデコーダの体系的ファジングがない。~~** ✅ #53 解決済み: `fuzz_tests.rs` にシード固定 xorshift64* PRNG による決定的ファジング（ランダム 10k + 構造的にもっともらしいバッファ 10k + エッジケース）。デコーダが panic せず `GPUI_STATUS_*` のみを返すことを検証。nightly 向け `cargo-fuzz` スキャフォールド（`gpui-sys/fuzz/`、ASan + カバレッジ誘導）も追加（メインビルドからは隔離）。
- **~~`G26` 性能ベンチ/回帰 harness がない。~~** ✅ #53 解決済み: `gpui-sys/benches/decode_bench.rs`（criterion、`[[bench]] harness = false`）。現実的なツリーのデコード + headless レイアウトを計測。issue #10（インクリメンタル更新）の着手前提を満たした。

---

## 7. ドキュメント / DX

- **`G27` 消費者向け getting-started がない。** `README.md` はリポジトリビルダー向け。counter 以外の example がない。
- **`G28` API リファレンスがない。** `///|` doc comment はあるが生成ドキュメントサイトがない。`architecture.md` は AI 向け内部文書。
- **`G29` `moonbit-bindings/README.md` が空（0 バイト）。**

---

## クリティカルパス（推奨順序）

「ライブラリ/フレームワークを目指す」なら、機能追加より**消費可能性の確立**が先。

1. **~~【調査・最優先】`G3` パッケージングの成立性。~~** ✅ 検証済み（2026-07-24）。`--moonbit-unstable-prebuild` で成立。[スパイレポート](spikes/2026-07-24-packaging-feasibility.md)参照。次のアクション: 実際の gpui-sys で prebuild スクリプトのプロトタイプ実装（#48 の G2 に接続）。
2. **~~`G17` マルチ view/ウィンドウのイベントルーティング。~~** ✅ 完了（#49、2026-07-25）。5 スロット envelope（`ABI_VERSION=4`）で確定済み。
3. **`G11`〜`G14` コンポーネント/状態抽象の設計。** click_id int 配線とグローバル可変状態を再利用可能な層へ。フレームワークの骨格。
4. **`G6`〜`G10` API 表現力の拡充** と **`G18`/`G19` a11y/IME。** 3 の抽象の上に乗せる。
5. **~~`G24`〜`G26` テスト基盤~~** ✅ #53 完了（ヘッドレス layout 検証・ファジング・ベンチ）。4 と #10 の安全網。
6. **`G1`/`G2`/`G4`/`G5`/`G27`〜`G29` 配布整備**（マニフェスト・署名・semver・docs・example）。

既存の残り issue は自然に合流する: **#10（インクリメンタル更新）は ~~5 のベンチ後~~ ✅ `G26` ベンチ harness 整備済み（#53）で着手可能**、~~**#16（text padding = `G10`）は 4 のテキスト API 設計時**~~ ✅ #16 解決済み。

---

## 起票の目安

各 `G*` を issue 化する際の粒度案:

- 単独 issue 向き: `G1`（マニフェスト整備）✅、~~`G3`（パッケージング調査・スパイク）~~ ✅ 完了（#47）、`G17`（view ルーティング ABI）✅ 完了（#49）、`G29`（空 README）✅。
- 設計 RFC 向き（単一 issue では大きすぎる）: `G11`〜`G14`（コンポーネントモデル）、`G6`〜`G9`（widget/style 体系）。
- 既存 issue に統合: `G10` → #16、~~`G26` → #10 の前提~~ ✅ `G26` 完了（#53）で #10 の前提充足。
