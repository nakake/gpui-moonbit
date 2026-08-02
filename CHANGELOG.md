# Changelog

本プロジェクトのすべての注目すべき変更はこのファイルに記録する。
形式は [Keep a Changelog](https://keepachangelog.com/ja/1.1.0/) に従い、バージョニングは [Semantic Versioning](https://semver.org/lang/ja/) に従う。
バージョニング方針の詳細は [`docs/versioning.md`](docs/versioning.md) を参照。

## [Unreleased]

### Added

- テキスト入力 widget と IME 合成の実装（#88、RFC 0003、G6 / G19）:
  - **Rust 側**（`gpui-sys`）: `UiNode::TextInput` leaf ノード（`OP_TEXT_INPUT` = 38、operand は `input_id i32 | len u32 | utf8[len]` の placeholder）。編集バッファ・選択範囲・preedit は view ごとの `TextInputModel` エンティティ（`FfiView.inputs`、再構築を跨いで生存）が保持し、Rust を正とする。`EntityInputHandler` 実装（UTF-16↔UTF-8 境界変換、preedit は下線付きで Rust 内に留まる）。確定で `EVENT_INPUT_CHANGED`（6）、フォーカス中の Enter で `EVENT_INPUT_SUBMIT`（7）を配送（envelope `(4, kind, view, input_id, 0)`、ペイロードなしの pull 型）。pull ABI `gpui_input_text_len` / `gpui_input_copy_text` / `gpui_input_set_text`（メインスレッド更新のミラー経由。`set_text` は合成中に `GPUI_STATUS_BUSY_COMPOSING`（`-13`）で拒否し、widget の次回 prepaint で適用）。input フォーカス中はルートコンテナが `EVENT_KEY` / `EVENT_NAMED_KEY` / `EVENT_TEXT` を抑止（二重配送の防止、Tab トラバースは継続）。8 本の unit test + drift guard。
  - **MoonBit 側**（`moonbit-bindings`）: `CommandBuffer::text_input(input_id, placeholder)` opcode ラッパー、`input_text(view, input_id)` / `input_set_text(view, input_id, text)` pull ラッパー、`GpuiError::BusyComposing`（`-13`）、`Event::InputChanged` / `InputSubmit` デコード、`HandlerRegistry` の `InputId` newtype + `new_input_id` / `on_input_changed` / `on_submit`（id ごとの単一配送）、`text_input(cb, props)` コンポーネント（`components.mbt`）。Counter デモにテキストボックスを追加: 数字を入力して Enter でカウントにセットしボックスをクリア（`parse_digits` を `on_text` と共有、i32 オーバーフローガード付き）。`cmd/roundtrip` に headless input smoke を追加（pull ABI のリンク・submit のルーティング・headless での `INVALID_HANDLE` を検証）。wire format ピンニング test・registry test・コンポーネント test を追加。
- コンポーネントモデルと状態管理の実装（#86、RFC 0001 Phase A–D、G11–G14）:
  - **Phase A** — 型付きイベントとハンドラレジストリ: `event.mbt`（`Event` enum / `decode_event`）と `handlers.mbt`（`HandlerRegistry`、`on_click` / `on_key` / `on_named_key` / `on_text`、fan-out 配送）。`BTN_*` int 定数と int switch を撤廃。
  - **Phase B** — 型付き状態ストア: `store.mbt`（`Store` / `CellId[T]`、`cell_for_key`）。`Array[Int]` / `Array[Bool]` のグローバル可変配列を置換。RFC の `Any + downcast` 案はこのツールチェーンに `Any` が無いため不採用で、`CellId[T]` が型付き get/set クロージャを保持する設計を採用（RFC §6）。
  - **Phase C** — 再利用可能コンポーネント: `components.mbt`（`RenderCtx` / `button`）、`HandlerId` newtype。`build_tree` をコンポーネント呼び出しの列に再構成。
  - **Phase D** — signal とフレームワーク dispatch: `signal.mbt`（`Signal[T]`）と `framework.mbt`（`framework_dispatch`）。ハンドラは signal の `set` のみを行い、フレームワークが store の dirty 追跡で再構築をスケジュール。`changed` 戻り値の報告を撤廃。dispatch の変化/不変化ゲートはリンク済み往復テスト（`cmd/roundtrip`）で検証。

- イベントの view 単位ルーティング: dispatch を 5 スロット envelope `app.dispatch(version, kind, view, data_a, data_b)` に拡張し、`ABI_VERSION` を 4 に bump（#49、24c3809）。
- `moonbit-bindings/moon.mod` のメタデータ整備（`description` / `repository` / `keywords`）と、バージョニング方針文書 `docs/versioning.md`（#48、G1 / G4）。
- コンポーネントモデルと状態管理の設計 RFC `docs/rfc/0001-component-model.md`（#50、G11–G14）。
- 消費者向け getting-started: `moonbit-bindings/README.md` 充填、`examples/hello` 追加、公開 API への `///|` doc comment（#55、G27–G29）。
- 構造化エラー `GpuiError` / `classify_status` / `status_message` / `expect_ok`、診断 `debug_dump_text`、MoonBit native 実行時制約の文書化（architecture.md §11）、`gpui_abi_probe` による自動 Int==i32 チェック（#54、G20–G23）。
- widget / style 体系の拡充（#51）: `Color` 型（alpha 付き、G9）、margin / min-max / flex / align / overflow / opacity / shadow / cursor / absolute / inset / per-side padding の 13 opcode（G7、15–27）、typography 7 opcode（text size/color/weight/line-height/align/whitespace/family、G8、28–34）、keyed `ScrollHandle` 保持による本物の scroll と `checkbox` / `labeled_row` 合成 widget（G6）。
- テスト基盤（#53）: gpui `test-support` によるヘッドレス layout golden テスト（G24）、in-crate シード PRNG ファジング + 任意の `fuzz/` scaffold（G25）、criterion ベンチ harness（G26）。
- キーボードナビゲーション: `OP_SET_FOCUSABLE` / `OP_SET_TAB_INDEX` / `OP_SET_TAB_STOP`（35–37）と Tab / Shift+Tab トラバース。a11y / IME の境界を `docs/a11y-ime.md` に文書化（#52、G18 / G19）。
- 計測で正当化したインクリメンタル更新: keyed in-place `gpui_update_text` FFI。24 行ツリーで full rebuild 比 約440x（11.4µs → 25.9ns）。汎用 vdom diff は意図的に未実装（#10）。
- `set_border_color(width, color)`: 枠線を alpha 付き `Color` で設定する API。`set_border(width, r, g, b)` と wire format は同一（#81）。
- prebuild パイプライン（#93、G2）: `moonbit-bindings/build.py` を `--moonbit-unstable-prebuild` で登録。path/git 依存で本モジュールを消費したコンシューマの `moon build` 時に Rust staticlib をビルドし、LinkConfig でリンクフラグを伝播する。`link/` パッケージを新設し、コンシューマ exe が import することで伝播を受ける設計（テスト exe への意図しない伝播を回避）。Linux x86_64 / macOS arm64 / Windows MSVC x64 の 3 つで検証済み（CI の consumer smoke test、#103）。
- 最小コンシューマモジュール `tests/consumer`（#103）: `moonbit-bindings` に path 依存し、`link` パッケージを import して FFI を実際に呼ぶ。prebuild の LinkConfig が壊れているとリンクに失敗するため、prebuild 消費経路の回帰テストとして機能する。CI で ubuntu / macOS / Windows の 3 ランナーすべてで、`moon test` より前にビルド・実行する。
- MoonBit 側のブラックボックステスト 17 件（#80）: `moonbit-bindings/gpui-bindings_test.mbt` に、`@gpui-bindings` 経由で公開 API だけを使うテストを追加。コマンドバッファ組み立て（magic / `BUFFER_VERSION` / 先頭・末尾 opcode）、`Color` の 4 チャンネル、`classify_status` ↔ `GpuiError::code` の往復、`status_message` / `message` / `to_string`、`expect_ok` の成功と abort、`Store` / `Signal` / dirty 追跡、`HandlerRegistry` のクリック・submit 配送、`button` / `checkbox` / `labeled_row` / `RenderCtx`、ABI 定数の公開を検証する。従来のテストはすべて whitebox（パッケージ内部スコープ）で、`pub` の付け忘れを検出できなかった。なお blackbox テスト実行ファイルは `tcc -run` で走り `gpui_sys` をリンクしないため、FFI に到達する API（`build_tree` / `update_text` / `run_window` / `decode_event` など）はブラックボックスからは検証できない。その層は `cmd/roundtrip` と CI の consumer smoke test が担う。
- 再構築フォールバック（#10）の分岐テスト 4 件（#80）: `app.update_view_with(view, incremental, rebuild)` を切り出し、インクリメンタル更新の成否で `build_tree` を呼ぶ／呼ばないの判断を FFI から分離した。`dispatch` 本体は FFI シンボルを参照するため `moon test` では走らないが、この判断部だけはスタブを渡して全分岐を検証できる。あわせてカウント表示の文字列を `count_label` に集約し、インクリメンタル経路とフルリビルド経路の書式ドリフトを防いだ。

- 非同期イベント注入（RFC 0002、#84）: 公開 C ABI `gpui_post_event(view, ptr, len)` で任意スレッドから有界キュー（1024 エントリ / 1 エントリ 1 MiB 上限）へペイロードを push。メインスレッドの drain pump が各エントリを新種別 `EVENT_ASYNC`（`5`、`ABI_VERSION` 据え置き）として配送し、`changed==1` で view を notify。新ステータス `GPUI_STATUS_QUEUE_FULL`（`-11`）/ `GPUI_STATUS_PAYLOAD_TOO_LARGE`（`-12`）。MoonBit 側は `post_event` / `copy_async_payload` ラッパー、`GpuiError::QueueFull` / `PayloadTooLarge`、`Event::Async` デコード（RFC 0001 の `Event` enum / `HandlerRegistry::on_async` に統合）、消費者例 `examples/stream` を追加。

### Changed

- `set_absolute(mode)` を `set_position(mode)` にリネーム。実態は position-mode setter（`POSITION_RELATIVE` / `POSITION_ABSOLUTE`）であり、「absolute にするだけ」の旧名は誤解を招いたため（#81）。
- 色の API を `Color` 受けに寄せる方針を文書化。生 `r, g, b` トリプレット版（`set_bg` / `set_border` / `text`）は引き続き利用可能で、`Color` 版（`set_bg_color` / `set_border_color` / `set_text_color`）を推奨（#81）。
- `on_text` の数値パースに i32 オーバーフローガードを追加。桁あふれする数字入力は wrap せず無視する（#81）。
- コールバックの期待プロトタイプを `abi.toml` の `[callback] params` から導出するように `build.sh` / `build.ps1` を変更（#76）。従来は `int32_t,int32_t,int32_t,int32_t,int32_t` を両ドライバに文字列リテラルでハードコードしていたため、envelope のスロット数を変えると `abi.toml` に加えて 2 箇所を手で直す必要があった。opcode / status code と同様に `abi.toml` を単一情報源に揃えた。`i32` 以外の param 型は明示的にエラーにする。

### Deprecated

- `set_absolute(mode)`: `set_position(mode)` を使用のこと。`deprecated.mbt` に非推奨エイリアスとして残置（#81）。

### Removed

- 未使用の `NodeHandle` 型（宣言のみで使用箇所ゼロのデッドコード）を削除（#81）。

### Fixed

- C export 全 10 本のうち `ffi_export`（`catch_unwind` ラッパ）を通っていなかった 2 本（`gpui_event_copy_text` / `gpui_debug_dump_text`）をラップした（#73）。現状この 2 本に unwind する経路は見当たらず、`extern "C"` からの unwind は現代の Rust では abort であって UB ではないため、これは健全性の修正ではなく**契約の一貫性**の修正である。「panic は FFI 境界を越えず `GPUI_STATUS_INTERNAL_PANIC` になる」という契約が全 export に等しく適用されていなかったため、将来この 2 本に panic しうるコードが入ったときだけ静かにプロセス abort に化ける状態だった。
  - 再発防止として、`#[unsafe(no_mangle)]` の付いた export が `ffi_export` を通っているか、かつラベル文字列が関数名と一致しているかを自身のソースを走査して検証するテストを追加（属性レベルで強制する手段が無いためテキスト検査。export を 1 本でも取りこぼすと空回りするので、検出本数の下限も assert する）。`ffi_export` が panic をステータスに変換すること自体のテストも追加した。
- コミット済みツリーを歩く再帰 3 関数（`render_node` / `collect_text_contents` / `update_keyed_text`）のスタックオーバーフローを塞いだ（#74）。`stacker` でスタックを伸長し、あわせて木のネスト深さに上限（`MAX_TREE_DEPTH` = 64）を設けて、超過分は新ステータス `GPUI_STATUS_DEPTH_EXCEEDED`（`-15`）でコミット前に拒否する。深さの検査は既存の重複キー検査と同じ 1 回の反復走査に相乗りさせている。
  - **実測**（debug ビルド、ヘッドレス render）: 1 段あたり約 70 KB のスタックを消費し、**素の再帰では 2 MiB のスレッドスタックが深さ 24〜32 で溢れる**。issue が想定していた「10 万段」ではなく数十段でプロセスが死んでいた。`stacker` を入れると 256〜384 まで伸びるが、そこから先の壁は gpui / taffy 自身の再帰（レイアウトと要素ツリーの drop）でこちらからは動かせない。上限 64 はその壁の十分下で、かつ Windows のメインスレッド既定 1 MiB でも余裕がある値として選んだ（現実の UI は 10 段前後）。
  - スタックオーバーフローは `catch_unwind` で捕捉できず `GPUI_STATUS_INTERNAL_PANIC` に変換されないため、これはプロセス死をステータスコードに置き換える変更にあたる。
- コマンドバッファの f32 オペランドをサニタイズするようにした（#75、G25）。生ビットから復元した `f32` を素通ししていたため、非有限値（NaN / ±無限大）が taffy まで到達していた。新ステータス `GPUI_STATUS_INVALID_FLOAT`（`-14`）でデコード時に拒否し、有限値も ±1e6 px にクランプする。対象は生 `f32` を読む 6 opcode（`OP_TEXT` のフォントサイズ、`OP_SET_SIZE` / `OP_SET_GAP` / `OP_SET_ROUNDED` / `OP_SET_PADDING` / `OP_SET_BORDER`）。あとから追加された opcode 群は i32 固定小数点なので対象外。
  - **実測**（ヘッドレスで 6 opcode × 7 値を計測）: panic も hang も起きず、`f32::INFINITY` は `inf × inf` の bounds として、無限大の gap は兄弟の幅が `NaN` として、いずれも静かに伝播していた。**`f32::MAX` は `INFINITY` と完全に同じ結果**になる（taffy の加算が f32 の表現限界よりずっと手前でオーバーフローする）ため、`is_finite()` チェック単独では無限大ジオメトリを防げない。クランプを併用しているのはこのため。
  - fuzz を render まで延伸（`fuzz_plausible_buffers_render_never_panic`）。従来の 3 本はいずれもデコーダで止まっており、`render_node` と taffy を一度も通していなかった。オペランドの「枠組み」ではなく「値」が効いてくるのはレイアウト以降なので、この段が無いと本件のような欠陥は原理的に検出できない。
- `build.sh` の `write_moon_pkg` の冪等性チェックが機能していなかった問題を修正（#77）。プレースホルダ未置換の**テンプレート**と置換済みの**生成結果**を `cmp` で比較していたため常に「差分あり」となり、`||` の短絡で本来の比較（生成内容 vs 既存ファイル）に到達していなかった。結果として `moon.pkg` が毎回書き換わり mtime が更新されていた（`build.sh` が exe を明示的に `rm -f` するため実害は無し）。`build.ps1` の `Write-MoonPkg` には同じ不具合が無く、両ドライバのロジック乖離の実例だった。
- Windows CI の `moon test` が #93 の prebuild 導入後に失敗していた問題を修正: `build.py` が cc/ld 形式のリンクフラグ（`-L`/`-l`）を MSVC の `cl` に渡し、`link` パッケージのテスト exe が `CVT1100`（duplicate manifest）でリンク失敗していた。Windows では prebuild のフラグ伝播を暫定的に無効化（空の LinkConfig）した。MSVC 形式フラグは #103 で実装・検証済み（下記）。
- prebuild の Windows 対応を実装（#103）: `build.py` が MSVC 形式のリンクフラグを出力するようになり、#102 の暫定ゲートを解除した。moon は `link_flags` を `link` ではなく `cl` に渡すため `/LIBPATH:` は「unknown option」として捨てられる。したがって検索パスは使わず、`gpui_sys.lib` / `gpui.lib` / windows-rs の import lib を**絶対パス**で渡し、Windows SDK のライブラリ（`kernel32.lib` 等）は素の名前のまま `LIB` 経由で解決させる。Rust 側は `RUSTFLAGS=-C target-feature=+crt-static` でビルドする（moon の native backend が無条件に `/MT` を付けるため）。あわせて Windows の `moon test` から `link` パッケージを除外した: moon は `link` パッケージ自身の blackbox test をビルドする際に LinkConfig を 2 回適用してしまい（`link` と `link_blackbox_test` が同じ `link/moon.pkg` に解決される）、`.lib` の重複で MSVC が `CVTRES: CVT1100 duplicate resource type:MANIFEST` → `LNK1123` で落ちる。ld / ld64 では無害なため Unix は全パッケージを実行する。
- `build.ps1` が `cargo rustc -- --print native-static-libs` の出力から ANSI エスケープを除去していなかった問題を修正（#106）。最後のトークンが `/defaultlib:libcmt<ESC>[0m` の形で残るため後続の `/defaultlib:(libcmt|msvcrt)` フィルタがマッチせず、`moon.pkg` の `@NATIVE_LIBS@` に漏れて Windows CI で `cl : Command line warning D9002 : ignoring unknown option` が繰り返し出ていた（`cl` が捨てるため実害は無し）。`moonbit-bindings/build.py` の `extract_native_libs()` と同じ処理に揃えた。パターンは Windows PowerShell 5.1 でも動くよう `[char]27` で組んでいる（`` `e `` は PowerShell 6+ 専用）。windows-latest の CI で D9002 の消失と `native libs (static CRT):` に `/defaultlib:` が残らないことを確認済み。
- テキストの空白パディング workaround を撤廃し、paint-time ¼px オフセット（`TextGlyphInset`）に置換。コンテンツ汚染を解消（#16、G10）。
- `on_text` が 10 桁以上の数字入力で i32 境界を wrap して負値になり得た問題を、オーバーフローガードで修正（#81）。
- 新規 FFI 関数追加時のビルドデッドロックを修正（#71）: bindgen が消費する `gpui-sys/include/gpui_sys.h` を、`moon check` ゲートより前に `gen-header`（cbindgen のみ依存の小クレート）で再生成するように `build.sh` / `build.ps1` の順序を変更。新しい `#[unsafe(no_mangle)] pub extern "C"` を追加してもドライバ 1 回でビルドが通る。`moon check` 失敗時にはヘッダー再生成のヒントを表示。`build.ps1` 側は Windows 未検証。
- `EVENT_TEXT` dispatch 後の `EVENT_QUEUE` 未クリアによるペイロードリークを修正（#70）: dispatch 復帰直後にキューをクリアし、`gpui_event_copy_text` のトークンが再利用されないことを保証。非同期注入経路も同じ契約に従う。正常系・境界・リーク回帰の unit test を追加。

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
