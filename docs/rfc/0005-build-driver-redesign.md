# RFC 0005: build driver の再設計(registry 消費 + cmd の prebuild 一本化)

| 項目 | 内容 |
|---|---|
| ステータス | 設計確定・実装中(PR-0〜PR-D、§5)。D0 観測(§4)は 2026-08-17 完了・緑 |
| 作成日 | 2026-08-17 |
| 対象 | `moonbit-bindings/build.py`(prebuild driver)の registry 消費対応と、`cmd/{main,roundtrip}` の per-OS テンプレート機構の廃止 |
| 関連 issue | #132(registry 消費 = 案 C の実装)、#126(cmd の prebuild 一本化)、#125(前提: RFC 0004)、#93(prebuild パイプライン)、#107(LinkConfig 二重適用) |
| 前提ドキュメント | [`0004-dispatch-registration.md`](0004-dispatch-registration.md) §6-3(registry スパイクと案 C の採用)・§8-4、[`../architecture.md`](../architecture.md)(現行実装の権威)、[`../versioning.md`](../versioning.md) |

RFC 0004 §6-3 の結論: MoonBit モジュール単独の mooncakes 公開は成立しない(`build.py` が sibling `../gpui-sys` を要求し、`.mooncakes/` 展開には sibling が無い)。採用済みの案 C = 「`gpui-sys` を crates.io に公開し、wrapper crate(`extern crate gpui_sys;` の staticlib)経由で引く」の実装が #132。その build.py 再設計は、`cmd/{main,roundtrip}` を per-OS テンプレート機構から prebuild + `link` import 方式へ寄せる #126 とスコープが重なるため、RFC 0004 §8-4 の指示どおり両者を合同で設計する。本 RFC は Plan agent の設計案を critic に反証させ、全 10 指摘を反映した確定版である。

---

## 1. 背景と動機

現状、リンクフラグの供給経路が 2 本ある:

1. **prebuild 経路**(`build.py` → LinkConfig → `link` パッケージ): tests/consumer・examples が使う。cc-link-flags は依存を越えて伝播しない(moon#1595)ため、これが唯一の伝播経路。
2. **テンプレート経路**(`cmd/*/moon.pkg.<os>` + `build.sh`/`build.ps1` の `@RUST_LIB_DIR@`/`@NATIVE_LIBS@` 置換): cmd/{main,roundtrip} だけが使う遺物。生成物の `moon.pkg` は gitignore され、供給源が二重化している。

registry 消費(#132)は build.py に「sibling が無い環境で gpui-sys を手に入れる」新経路を要求する。テンプレート経路を残したまま新経路を足すと検証面が 3 本になるため、先に #126 で prebuild 一本へ畳み、その上に wrapper 分岐を載せる。

## 2. 前提事実(調査 + critic 実機確認で裏取り済み)

- `build.py:270-276` が sibling `../gpui-sys` 必須で hard-exit。prebuild プロトコルの `out_dir` は moon 側未実装(リテラル `"TODO"`)で使用不能
- wrapper crate 経由で `#[no_mangle]` 11 個が残り tests/consumer PASS は Linux で実測済み(RFC 0004 §6-3)。gpui-sys の依存形(path/crates.io)はコード生成・リンクに影響しない
- gpui-sys の publish メタデータ・`mb_symbol.txt` 非依存化は PR #131 で完了。`moon.mod` とロックステップで双方 0.1.0
- **`gpui-sys/build.rs` は registry 消費で壊れる潜在バグを持つ**: `build.rs:101`(abi_constants.rs)と `build.rs:202`(cbindgen ヘッダ)が無条件にクレートディレクトリへ書き込む。registry checkout は読み取り専用のため panic し得る。`cargo publish` の verify では検出されない
- cmd/{main,roundtrip} にテストは 0 件。「link import する is-main + テスト 0 件」は examples/counter/main が同形で windows-latest の `moon test` を通過済み(#107 対策の先行実績)
- cc-flags(`-I../gpui-sys/include`、Win `/utf-8`)は全廃可(tests/consumer・examples/stream が cc-flags なしで 3 OS 緑)
- stale な gitignore 済み moon.pkg は tracked 化コミットへの checkout 時に git が上書きするため手動掃除不要。`.claude/codex-scaffold.sh:8` のコピー行削除のみ必要
- prebuild 経路でも生成 `main.c` は `_build/.../build/<pkg>/main.c` に残る(リンク成功後も)。リンク済み PE は COFF シンボルテーブルを持たず `dumpbin /SYMBOLS exe` は使えない(build.ps1:339-343 の既存コメントどおり)
- 現行 moon では `__moonbit_link_core__/main.o` は生成されない(build.sh:454-456 の rm は死にパス)
- `moon package --list` が存在し、**公開なしで tarball 内容を観測できる**(§4 で実施)

## 3. 決定事項

| # | 決定事項 | 選択 | 根拠(要点) |
|---|---|---|---|
| D0 | 着手前観測(公開不要・最優先) | `moon package --list` で tarball に build.py・link/・cmd/ が入るかを観測し、生成 tarball を consumer の `.mooncakes/nakake/gpui-bindings/` に手置きして「`.mooncakes` 展開からの prebuild 起動」をシミュレート。結果を本 RFC §4 に記録し、**ユーザゲート 1(crates.io publish)の前提条件**とする | この観測は公開なしで今すぐ可能であり、不可逆ゲート 2 つの後に置くと「tarball に build.py が入らない」と publish 後に判明するリスクがある。RFC 0004 §6-3 と同じ「公開せず構造可否を先に検証」方式 |
| D1 | wrapper crate | **build.py がビルド時に生成**(同梱しない)。`Cargo.toml`(`[workspace]` ガード + `crate-type=["staticlib"]` + `publish=false`)+ `src/lib.rs`(`extern crate gpui_sys;`)。生成は**常に内容照合し、期待値と異なれば temp ファイル + rename で原子的に書き直す**(「無ければ書く」ではない)。gpui-sys の pin は build.py 冒頭の定数から **caret 形式 `gpui-sys = "0.1.0"`**(= `>=0.1.0 <0.2.0`) | 生成なら registry 依存と path 依存を依存行 1 行差で出し分けられ、公開前 CI 検証(D4)が成立。原子的再生成は route 切替の依存行残存(偽陽性 e2e)と並行ビルド競合への手当て。**caret pin の理由**: `=` pin だと配布済みモジュール内の build.py が旧バージョンに凍結され、マングリング修正等の patch release が既存消費者に届かない。caret + 「patch は ABI/シンボル契約を壊さない」規律(versioning.md に明記)で修復チャネルを確保。minor(0.2)へは自動追従しないのでロックステップと整合。pin drift assert は build.sh preflight(= リポジトリ側 CI で毎回実行。registry 消費者は build.sh を実行しないが、pin の正しさはリポジトリ側で作り込む性質のもの) |
| D2 | wrapper の置き場 | OS 慣例のユーザキャッシュ(Linux `$XDG_CACHE_HOME`/`~/.cache`、macOS `~/Library/Caches`、Win `%LOCALAPPDATA%`)配下 `nakake-gpui-bindings/wrapper/<version>/`。cargo target は **`CARGO_TARGET_DIR` 未設定時のみ** `<キャッシュ>/nakake-gpui-bindings/target` を設定 | `.mooncakes/` 汚染(1.2GB×N)回避 + 複数 consumer で warm 共有。`CARGO_TARGET_DIR` 尊重は cargo 規約で CI のキャッシュ接続口。ホーム解決不能時は module_root 配下フォールバック + stderr 警告。docs に明記する事項: 位置・容量・削除手順に加え「初回は gpui 全依存のコールドビルド(数十分 + ネットワーク必須)」「異バージョン pin の consumer を併用すると共有 target で再ビルドが往復する(正しさは保たれる)」 |
| D3 | 経路分岐 | 自動判定は **sibling `../gpui-sys` の存在チェックのみ**。env `GPUI_BINDINGS_ROUTE` = `auto`(既定)/`checkout`/`wrapper-path`/`wrapper-registry` で強制上書き(検証専用)。`wrapper-path` は `GPUI_BINDINGS_GPUI_SYS_PATH` で指定可能な path 依存 wrapper | 実消費形態は二値で曖昧さなし(`.mooncakes` 展開に sibling は構造的に無く、checkout/path/git 依存には必ず有る)。examples・tests/consumer は path 依存で module_root = 実リポジトリのため「sibling あり」= checkout 経路となり現行挙動と整合。`wrapper-path` = 公開前 CI シミュレーション、`wrapper-registry` = 公開後の実経路検証。依存形が結果に影響しないことは実測済みなので前者が後者の代理になる |
| D4 | 公開前 e2e | CI 恒常 2 ステップ: (1) 3 OS で `GPUI_BINDINGS_ROUTE=wrapper-path` + `CARGO_TARGET_DIR=$GITHUB_WORKSPACE/gpui-sys/target` の tests/consumer ビルド+実行 (2) Linux で `cargo package` → 展開 → **読み取り専用化** → path 依存でビルド+実行 | (1) はスパイクの恒久 CI 化(3 OS のフラグ正規化を毎 PR 検証、warm 約 1 分)。(2) は「公開 tarball のファイル集合 + 読み取り専用」という crates.io 消費の最接近近似で、build.rs 書き込みバグ級を publish 前に検出する唯一の網。**wrapper 経路は gpui の resolve が浮動する**(gpui-sys/Cargo.lock は wrapper に効かない): registry 消費者は最新 gpui 0.2.x を引く設計と割り切る。wrapper-path CI がこれ由来でフレークしたら wrapper 生成時の gpui pin を検討 |
| D5 | cmd 移行 | **moon.pkg をコミット**(現行 toolchain の正規形で。旧記法とドリフトがあるため実装時に `moon fmt`/`moon check` の安定形へ合わせる)。main: bindings + link import + is-main 相当、roundtrip は + core/{buffer,encoding/utf8}。cc-flags/cc-link-flags 全廃。テンプレート 6 ファイル + `write_moon_pkg`/`Write-MoonPkg` 削除、`.gitignore` の該当 2 行削除。**事後シンボル検証(OS 別仕様)**: (i) Linux/macOS = `moon build` 成功後 `nm` で final exe に**実ファイル `mb_symbol.txt` の値**(computed 再計算ではなく。手動 override の escape hatch 維持)が exactly-once。Windows = main.obj が prebuild 経路で残るなら現行の obj 定義 1 回 + gpui_sys.lib UNDEF 参照 1 回の契約検証を維持、残らなければ UNDEF 参照 + リンク成功で定義側を担保(PR-A で存否を確認して確定) (ii) 生成 main.c の C プロトタイプを abi.toml `[callback] params` と照合(維持。main.c はリンク成功後も残ることを確認済み) (iii) リンク失敗時は生成 main.c から**suffix 非依存のパターン**で実シンボル候補を提示し、「`gpui-sys/mb_symbol.txt` を削除して再実行」を含む診断を表示(現行 grep は suffix 変化時に 0 件になる)。Windows `moon test` スコープは現状維持(link 除外・cmd 含む) | 実マングル抽出の自己修復は consumer 経路には元々無い保証 = 失うのは cmd 固有の冗長性のみ。ドリフトは CI(MoonBit 最新追従)のリンク失敗 + (iii) 診断で顕在化。(ii) はマングル名が型を運ばないため唯一の型レベル検証で必須維持。#107 は「link パッケージ自身の blackbox test の二重適用」という機構が cmd に当たらないこと + examples/counter の同形実績から安全と判断。発生時フォールバック = cmd を moon test スコープから外す(テスト 0 件で喪失ゼロ) |
| D6 | build.sh の残存役割 | 残す: preflight(+ pin drift assert)/ [0] codegen / moon check / **cmd exe の rm(強制再リンク。死にパスの `__moonbit_link_core__/main.o` 参照は掃除)** / moon build(prebuild が cargo 内包)/ 事後シンボル検証(D5)/ roundtrip 実行 / macOS bundle。撤去: write_moon_pkg・[1b] bootstrap・[2/5] 抽出・[3/5] cargo + native-libs 捕捉(build.py と完全重複) | 「moon が外部 .a を追跡しない」問題は経路と無関係に残るため rm は維持。consumer 側の Rust-only 変更後再リンクは未検証 → PR-B で CI probe(touch → 再ビルド → 実行結果 or mtime 比較、Linux)。stale なら文書化 + upstream issue |
| D7 | 順序と公開バージョン | **PR-0(本 RFC + D0 観測)→ PR-A(#126)→ PR-B(#132 build.py + CI sim)→ PR-C(publish 準備 + ユーザゲート 1: crates.io `gpui-sys 0.1.0`)→ PR-D(mooncakes 検証 + ユーザゲート 2、wrapper-registry CI 恒常化)** | #126 先行で検証面を prebuild 一本にしてから wrapper 分岐を載せる(逆順は二重検証)。0.1.0 のまま publish(未公開なので bump の利益なし、ロックステップ現在値と一致)。**mooncakes 0.0.1 は D0 の手置きシミュレーションで大半が決着した場合は省略可**とし、実施要否自体をユーザゲート 2 の判断材料にする。実施する場合: モジュール名は変えられない(マングルシンボル・LinkConfig ターゲット・abi.toml `[callback] module` がモジュール名依存)ため実名 + 0.0.1、公開用ブランチのみで moon.mod を 0.0.1 にし main に merge しない + **公開コミットにタグを打ち provenance を残す**。実名での 0.0.x 公開は事実上の公開開始なので versioning.md(リリースチェックリスト 6「mooncakes 公開は prebuild API 安定化後」)からの方針変更として本 RFC に明示記録する。**バージョンバンプ期のデッドロック対策**: wrapper-registry CI ステップは「pin が crates.io に未存在なら skip + 警告」のガード付きにし、versioning.md のリリース手順に publish とバンプ PR merge の順序を明記 |
| D8 | 記録 | 本 RFC(0005)を新設し、実装 PR ごとに docs 同期 | リポジトリ慣行(意思決定 = RFC、現行実装の権威 = architecture.md)。2 issue 横断のため RFC 0004 追記では主客逆転。caret pin・gpui 浮動の割り切り・mooncakes 方針変更もここに記録 |
| D9 | スコープ外 | out_dir 採用 / #107 上流修正 / mooncakes **正式**公開(0.1.x の公開判断は prebuild API 安定化後)/ rerun_if / gpui-sys の機能・ABI 変更(ABI_VERSION 4 据え置き)/ macOS 配布署名 | 上流依存または別方針で管理済み |

## 4. D0 観測結果(2026-08-17、Linux x86_64・moon 0.1.20260721)

**結論: 緑。registry 消費の構造は成立する。** ユーザゲート 1(crates.io publish)の前提条件はこの観測で満たされた。

### 4-1. tarball 内容(`moon package --list`)

`moonbit-bindings/` で `moon package --list` を実行。生成物は `_build/publish/nakake-gpui-bindings-0.1.0.zip`(42 ファイル)。

- **`build.py` は同梱される** — prebuild driver は tarball で配布される
- **`link/`(link.mbt + moon.pkg)は同梱される** — LinkConfig ターゲットが消費者に届く
- **`cmd/` も同梱される**(main.mbt・smoke_app.mbt・per-OS テンプレート)。ただし gitignore 済みの生成 `cmd/*/moon.pkg` は**除外される**(= `moon package` は gitignore を尊重する)。PR-A で moon.pkg を tracked 化すると tarball にも入るようになるため、「registry 消費者のビルドが依存側 cmd(is-main)をどう扱うか」は PR-A の検証項目に含める
- テスト(`*_test.mbt` / `*_wbtest.mbt`)・AGENTS.md も入る(サイズ影響は軽微、動作影響なし)

### 4-2. `.mooncakes` 手置きシミュレーション

手順(公開不要・再現レシピ):

1. スクラッチ consumer モジュール(`deps: {"nakake/gpui-bindings": "0.1.0"}` の registry 形式、`preferred-target: native`、main は bindings + link を import)を作成
2. 4-1 の zip を consumer の `.mooncakes/nakake/gpui-bindings/` に展開(レイアウトはバージョンディレクトリなしの `<user>/<name>/` 直下)
3. `moon build --frozen`

**発見 1(前提の修正)**: `--frozen` でも moon は依存グラフ解決に **registry index(`~/.moon/registry/index`)を参照する**。index に無いモジュールは `.mooncakes/` を見る前に「module was not found in the registry」で失敗する。シミュレーションには index への一時エントリ(`index/user/nakake/gpui-bindings.index` に JSONL 1 行: name/version/checksum = zip の sha256)を手置きする必要があった。つまり「手置きシミュレーション」の正確な形は **tarball 手置き + index エントリ手置き**である。実消費者向けには mooncakes への公開(index 登録)が必須であることの裏返しでもある。

**発見 2(本命)**: index エントリを置いた状態の `moon build --frozen` で、**prebuild は `.mooncakes` 展開から起動した**:

```
[gpui-bindings prebuild] module_root=<consumer>/.mooncakes/nakake/gpui-bindings
[gpui-bindings prebuild] os=linux arch=x86_64
[gpui-bindings prebuild] ERROR: gpui-sys not found at <consumer>/.mooncakes/nakake/gpui-sys
```

- `--moonbit-unstable-prebuild` は registry(`.mooncakes/`)展開でも実行される(RFC 0004 §6-3 時点では path 依存のみ実績だった未検証点が解消)
- 失敗箇所は sibling `../gpui-sys` チェック、**すなわち PR-B の wrapper 経路が埋める継ぎ目そのもの**。それ以前(tarball 欠品・prebuild 不起動・プロトコル不一致)では落ちない

### 4-3. ユーザゲート 2 への含意

この観測で RFC 0004 §6 検証計画 3(「`.mooncakes/` フェッチ依存でも prebuild が走るか」)の核心は **YES で決着**した。0.0.1 実名 mooncakes 公開で追加検証できるのは「moon の実ダウンロード・checksum 経路」と「実 index 登録」だけであり、これは本シミュレーションでは代替できないが、失敗様態が build driver 設計に跳ね返る類のものではない。ユーザゲート 2 では「0.0.1 公開の省略」を既定の推奨とする(最終判断は PR-C の実 registry e2e 結果も見て行う)。

## 5. ステージ計画(各ステージ = 1 PR)

### PR-0: 本 RFC + D0 観測
§4 のとおり完了。`docs/rfc/0004-dispatch-registration.md`(0005 への参照)と `docs/roadmap.md` も同期。

### PR-A(#126): cmd の prebuild + link import 移行 — 実装済み(PR #135、3 OS CI 緑 2026-08-17)
- 追加コミット: `cmd/main/moon.pkg`、`cmd/roundtrip/moon.pkg`(現行 toolchain 正規形、D5)
- 削除: per-OS テンプレート 6 ファイル、`.gitignore` の該当 2 行
- `build.sh` / `build.ps1`: D6 の形へ縮約(事後検証は D5 の OS 別仕様。検証値は実ファイル `mb_symbol.txt` を読む)
- `.claude/codex-scaffold.sh`(コピー行削除)、`.claude/codex-rules.md`、docs 棚卸し、`CHANGELOG.md`
- 完了条件: テンプレート機構 + `@RUST_LIB_DIR@`/`@NATIVE_LIBS@` 置換の全消滅、リンクフラグ供給源が LinkConfig 一本、roundtrip 全スモーク PASS、build.sh 実行後 + `moon fmt` 後に git diff が出ない
- 検証: (1) 旧生成 moon.pkg 残存状態からの checkout 上書き確認 + `./build.sh` フル PASS (2) `moon test` unscoped 緑 (3) dispatch 関数を一時 rename → (iii) 診断が実シンボル候補を提示することの実証 (4) 3 OS CI 緑 + **Windows で main.obj の存否を確認し D5-(i) Windows 仕様を確定** (5) macOS bundle 検証ステップ緑

### PR-B(#132 前半): build.py の wrapper 経路 + 公開前 CI シミュレーション
- `build.py`: `GPUI_SYS_VERSION` 定数(caret pin)、経路判定(D3)、wrapper 生成(D1/D2)、cargo cwd 抽象化、リンク名分岐(`-lgpui_sys` ↔ `-lgpui_sys_wrapper`、`gpui_sys.lib` ↔ `gpui_sys_wrapper.lib` — `msvc_path()` の解決対象も分岐)、wrapper 経路では abi.toml/mb_symbol.txt 処理スキップ(crates.io 側 build.rs が自己計算)
- `gpui-sys/build.rs`: 書き込み冪等化(内容一致なら skip、差分ありかつ書き込み不能なら cargo:warning で続行)
- `build.sh`/`build.ps1`: preflight pin drift assert
- `ci.yml`: D4 の 2 ステップ + 再リンク probe(Linux)
- docs: README(キャッシュ位置・容量・削除手順・初回コールドビルド警告・異バージョン併用時の再ビルド往復)、troubleshooting、本 RFC 実測追記、CHANGELOG
- 検証: (1) `GPUI_BINDINGS_ROUTE=wrapper-path` でスパイク再現 PASS + キャッシュ位置・`CARGO_TARGET_DIR` 尊重確認 (2) route 切替後の wrapper Cargo.toml 書き換え + 同時 2 ビルド無競合の実証 (3) `cargo package` → 展開 → `chmod -R a-w` → ビルド成功 + `cargo package --list` で abi.toml・include/gpui_sys.h・src/abi_constants.rs 含有 / mb_symbol.txt 非含有 (4) 3 OS CI で D4-(1) 緑 (5) 再リンク probe の結果記録

#### PR-B 実測(2026-08-17、Linux x86_64)

- **wrapper-path e2e PASS**: `GPUI_BINDINGS_ROUTE=wrapper-path` で tests/consumer をビルド・実行(イベント注入 8 ステップ、5 rebuilds)。リンクは `-lgpui_sys_wrapper`、final exe に `dispatch_entry` シンボルが exactly-once(スパイクの恒久化)
- **キャッシュ配置**: wrapper は `~/.cache/nakake-gpui-bindings/wrapper/0.1.0/`(Cargo.toml + src/lib.rs の 2 ファイル)、cargo target は `CARGO_TARGET_DIR` 未設定時 `~/.cache/nakake-gpui-bindings/target`。`CARGO_TARGET_DIR` 指定時はそれを尊重(gpui-sys/target 共有で warm ビルド確認)
- **route 切替**: wrapper-path → wrapper-registry で wrapper の Cargo.toml が原子的に書き換わる(`gpui-sys = "0.1.0"`)。未 publish のため cargo は「no matching package named `gpui-sys`」で停止 — 想定どおりの pre-publish 挙動で、この同一コマンドが PR-C ゲート 1 後の実 registry e2e になる
- **並行ビルド**: wrapper dir + target dir を共有する 2 つの `moon build`(tests/consumer と examples/hello)を同時実行して双方成功(cargo の target ロック + 原子的 rename)
- **読み取り専用の梱包済み crate 消費 PASS**(D4-(2) のローカル前倒し): `cargo package --no-verify` → 展開 → `chmod -R a-w` → `GPUI_BINDINGS_GPUI_SYS_PATH` で wrapper-path ビルド → consumer 実行 PASS。`cargo package --list` で abi.toml・include/gpui_sys.h・src/abi_constants.rs の同梱と mb_symbol.txt の非同梱を確認。§2 の「build.rs が registry checkout で panic し得る」潜在バグは build.rs の書き込み冪等化(内容一致で skip、書き込み不能は cargo:warning で続行)で閉じ、このテストが再発を封じる
- **pin drift assert**: build.py の `GPUI_SYS_VERSION` を一時的に 0.2.0 へ変えると build.sh preflight が即エラー、0.1.0 で緑(negative/positive 両方向を実測)
- checkout 経路は無回帰(tests/consumer・build.sh フル PASS)

#### PR-B レビュー反映(2026-08-17、/code-review 8 観点 + critic 反証)

critic の必須 3 件 + 推奨/finder 指摘を反映し、D1/D2/D4 を次のとおり精緻化した:

1. **wrapper の置き場は依存元ごとにバケット化**(D2 精緻化): `wrapper/<pin>/<bucket>/`。bucket = route 接頭辞 + 依存行の sha256 先頭 12 桁。同一 dir を registry / 各 path 依存で共有すると、切替のたびに Cargo.toml 書き換え → cargo の path-identity fingerprint 無効化で gpui-sys 再ビルドが起き(CI の D4-(1)→(2) で毎回)、検証専用 env の並行異 route ビルドに TOCTOU もあった。分離で両方消える。
2. **wrapper-path は依存先の Cargo.lock をシード**(D4 精緻化、critic 必須 2): wrapper は lockfile を持たず gpui と約 740 推移依存を毎回最新解決するため、上流リリース 1 回で「rust-cache に保存されない cold build を毎 CI 実行で払い、timeout 超過で全 PR ブロック」になり得た。build.py が依存先 gpui-sys/Cargo.lock を wrapper へコピーし(`.seeded-from` マーカーで lock 変更時のみ再シード)、CI/検証の解決を repo lock に固定する。**wrapper-registry(実消費)は lock 供給源が無いため従来どおり浮動**(割り切りは不変。troubleshooting に反映)。
3. **sibling 判定は realpath**(critic 必須 3): normpath の字句的 `..` 解決は symlink 経由の path 依存で実在する sibling を不在と誤判定し、fail-loud だった旧挙動を「無言で crates.io を使う」に変えてしまう(critic が実測再現)。realpath で実体解決に変更。auto 判定が registry 経路へ落ちる際は stderr に理由と復帰手段(`GPUI_BINDINGS_ROUTE=checkout`)を明示するログも追加(壊れた checkout のマスキング対策)。
4. **ci.yml の `! grep` は set -e 下で死んでいた**(critic 必須 1、実測再現済み): mb_symbol.txt 非同梱アサートが常に素通りだった。明示的な if/exit 1 に修正。`cargo package` には `--allow-dirty` を付与(このステップは梱包構造の検証であり git 衛生は別段の守備範囲。生成物ドリフトで無関係な赤にしない)。
5. **caret 判定は build.py `--check-pin` に一本化**: bash/PowerShell の二重実装は cargo の `^0.0.z`(= 完全一致)を誤許容しており、将来の意味論修正も片側に漏れる。Python 1 実装を両ドライバが呼ぶ。
6. **build.rs の write_generated は「書き込み可能 dir での書き込み失敗」を fail-loud に**: 警告続行は読み取り専用 checkout(内容一致が通常)限定。書き込み可能なのに失敗した場合は stale な生成物での静かなビルド = 言語間 ABI 不一致(ビルド時シグナルなし)につながるため panic を維持。親 dir の create_dir_all も cbindgen 従来挙動に合わせて復元。
7. **cargo 成功時も build.rs の warning を prebuild ログへ転送**(critic 推奨): 冪等化ガードレールの cargo:warning が consumer に見えなかった。
8. **mb_symbol.txt の rerun-if-changed はファイル存在時のみ発行**: 不在パスの登録は build script を常時 dirty にし、registry 消費の warm ビルドに毎回 build.rs 実行(cbindgen 解析込み)の税を課していた。

### PR-C(#132 中盤): publish 準備 → 【ユーザゲート 1】crates.io へ gpui-sys 0.1.0
- 前提条件: §4 の D0 観測で赤信号なし(満了)
- `docs/versioning.md`(リリースチェックリストへ「publish → バンプ PR merge」の順序、pin 更新、「patch は ABI/シンボル契約を壊さない」規律)、`CHANGELOG.md`。コード変更なし
- 手順: `cargo publish --dry-run` でファイル一覧レビュー → **ユーザが `cargo publish`**(不可逆・トークンはユーザ管理)
- 検証: crates.io 上の 0.1.0 に対し `GPUI_BINDINGS_ROUTE=wrapper-registry` で tests/consumer Linux PASS(実 registry 初 e2e)

### PR-D(#132 後半): mooncakes 検証 → 【ユーザゲート 2】+ CI 恒常化
- ユーザゲート 2 の判断材料: §4-3 のとおり **0.0.1 実名公開の省略を既定の推奨**とする。実施する場合のみ: 公開用ブランチ(main に merge しない)で moon.mod を 0.0.1 + README 警告 → **ユーザが `moon publish`** → 公開コミットへタグ → 素の consumer で `.mooncakes/` からの prebuild → wrapper-registry で exe 実行 PASS、3 OS
- 本体 PR: `ci.yml`(wrapper-registry 恒常ステップ — pin が crates.io に未存在なら skip + 警告のガード付き)、本 RFC へ結果追記、versioning.md 注記、CHANGELOG
- 完了条件: RFC 0004 §6 検証計画 3 が YES/NO で決着・記録(§4 で核心は YES 済み)、3 OS で wrapper-registry 緑

## 6. 残存リスク

| リスク | 影響 | 手当て |
|---|---|---|
| ~~moon package tarball 仕様(build.py/link/cmd 同梱)~~ | ~~不同梱なら registry 消費不成立~~ | **解消(§4-1): すべて同梱される** |
| #107 が cmd の空テストビルドで顕在化 | Windows moon test 赤 | 機構的に当たらない見立て + examples/counter 同形実績。発生時は cmd をスコープから外す(喪失ゼロ) |
| マングリング変更時の自己修復喪失 | ツールチェーン更新でリンク失敗(自動追従喪失) | CI 最新 moon 追従で即検出 + D5-(iii) 診断(mb_symbol.txt 削除の案内込み)。修復は build.py/build.rs 修正 + caret pin により gpui-sys patch release が既存消費者に届く。モジュール側の修正は git 依存 HEAD 追従で配布 |
| consumer の Rust-only 変更後 stale exe | 静かな古バイナリ | PR-B の CI probe で実測 → 文書化 + upstream issue。cmd 側は rm 維持 |
| wrapper 経路の gpui 浮動(Cargo.lock 非対称) | 上流 gpui 0.2.x の破壊的 patch で wrapper 経路のみ赤 / CI フレーク源 | 本 RFC・troubleshooting に明記。フレーク化したら wrapper 生成時の gpui pin を検討 |
| wrapper キャッシュ約 1.2GB/環境・初回コールドビルド | ディスク圧迫・初回の長時間ビルド | README/troubleshooting に位置・容量・削除手順・初回警告・異バージョン併用の再ビルド往復を明記。CI は CARGO_TARGET_DIR 共有 |
| crates.io / mooncakes の不可逆性 | 誤公開の恒久化 | 双方に明示ユーザゲート + D0 前倒し観測で publish の必要性を先に確定(済)。mooncakes は省略可否込みでゲート 2 判断、実施時はタグで provenance 確保 |
| バンプ期の wrapper-registry CI 赤 | リリース PR がマージ不能になるデッドロック | CI ガード(未存在 version は skip + 警告)+ versioning.md に publish → merge の順序明記 |
| cbindgen バージョン幅(0.28)のヘッダ再生成差分 | registry ビルドで書き込み試行 | 冪等化 + 読み取り専用検証(D4-(2))が網。差分時 warning 続行 |
| prebuild API の変動 | 全経路の土台 | 既知の受容済みリスク(本計画で増えない) |

## 7. 未決事項

1. ~~**Windows の main.obj 存否**~~ **確定(2026-08-17、PR-A の windows-latest CI)**: prebuild 経路でも `main.obj` は残る。したがって D5-(i) Windows 仕様は強い側 = 「main.obj の定義 exactly-once + gpui_sys.lib の UNDEF 参照 exactly-once + リンク成功」で運用される(build.ps1 は main.obj が無い環境でも UNDEF + リンク成功へ自動縮退する適応分岐を保持)。cold build と Rust-only rebuild の両方で全検証 PASS。
2. **consumer の Rust-only 変更後再リンク**(stale exe か否か)— PR-B の CI probe で確定する。
3. **registry 消費者ビルドにおける依存側 cmd(is-main)の扱い**(§4-1)— PR-A で tracked 化した moon.pkg が tarball に入った状態での消費者ビルド挙動を確認する。問題があれば cmd の tarball 除外(moon package の除外機構の有無調査)か cmd の設計見直しをこの RFC に追記する。
4. **mooncakes 0.0.1 公開の最終要否** — ユーザゲート 2(§5 PR-D)。既定の推奨は省略。
