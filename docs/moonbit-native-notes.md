# MoonBit native 低レベル仕様メモ

このプロジェクト(MoonBit ↔ Rust/C FFI で GPUI を叩く)で**実測した MoonBit の native バックエンドの挙動**を蓄積する場所。
公式ドキュメントに載っていない/載っていても曖昧な、C ABI・シンボル・ランタイム・リンク周りの実装挙動が中心。

> **位置付け**: これは観測記録であり、現行仕様の正本は [`README.md`](../README.md) と [`architecture.md`](./architecture.md) である。以下の旧実装・修正前の観測は履歴として残している。

> **前提**: すべて `preferred_target = "native"`。対応 host/target は macOS arm64・x86_64、Linux x86_64、Windows MSVC x64 で、cross compile は対象外。§1〜§8 は主に macOS(arm64 / Mach-O)を基準にした観測で、§9/§10 は後から追加した Linux/Windows の観測である。
> ツールチェーン観測値: `moon 0.1.20260713` / `rustc 1.97.0`。これは最低保証ではない。build driver は実行時バージョンを表示し、Cargo 依存は `Cargo.lock` を正本とする。**MoonBit のマングル方式やビルド挙動はバージョンで変わりうる**ので、各項目に観測日を付す。壊れたら本メモを疑い、再測定して更新すること。

## 追記のしかた(重要)

MoonBit の native/低レベル挙動を新たに発見したら、**必ずここに追記**する。1項目 = 「事実 / 根拠(コマンド・シンボル) / 含意 / 観測日」。
再測定に使うコマンドは末尾の「確認チートシート」に集約。

---

## 1. 値表現と FFI 受け渡し

> **旧 C-string ABI の観測 (2026-07-14、現在は superseded)**: 以下の UTF-8 + NUL 終端の記述は、C 側が `const char *` と `CStr::from_ptr` を使っていた時点のもの。現行のテキスト ABI は borrowed `Bytes` の `const uint8_t *ptr + int32_t len` であり、UTF-8 は明示長で渡すため NUL 終端を付けない。

- **`String` は UTF-16・非 NUL 終端**。native では `moonbit_string_t = uint16_t*`(UTF-16 コードユニット列)。C の `const char*` に**直接渡してはいけない**(`CStr::from_ptr` が ASCII 文字列の 2 バイト目 `0x00` で切って先頭1文字になる)。
  - 対処: UTF-8 にエンコードして NUL 終端を付けた `Bytes` を渡す。`@moonbitlang/core/encoding/utf8.encode(StringView) -> Bytes` + 末尾に `0` バイト。詳細は [`troubleshooting.md`](./troubleshooting.md) §1。
  - 観測日: 2026-07-14
- **`Bytes` は `moonbit_bytes_t = uint8_t*`** で、**データ先頭を直接指す**。FFI に渡すとその生ポインタが C 側に渡る。NUL 終端 UTF-8 を入れれば `const char*` としてそのまま読める。
  - 観測日: 2026-07-14
- 型マッピング(bindgen で使用): `int32_t`/`uint8_t`→`Int`、`float`→`Float`、`double`→`Double`、`void`→`Unit`、`const char*`→`Bytes`(String ではない、上記理由)。
  - 観測日: 2026-07-14

## 2. FFI 宣言(import 方向: MoonBit → C)

- import は `extern "C" fn name_ffi(args) -> Ret = "c_symbol"`。`= "..."` が C 側シンボル名。
- ポインタ型引数には **`#borrow(param)` か `#owned(param)`** を付ける。`#borrow` = 呼び出し中だけ読む(callee は incref/decref しない)。`#owned` = 所有権を渡す。**デフォルトは現状 `#owned`(将来変わる予定)** なので明示推奨。
- 観測日: 2026-07-14

## 3. シンボル・エクスポート・マングリング

- **`#export_name("sym")` は native の実行ファイルビルドでは C シンボルを出力しない**(観測)。
  - `#export_name` は `pkgtype(kind: "foreign_library")` 必須。foreign_library は `fn main` と同居不可。
  - しかし is-main 実行ファイルビルドでは、依存 foreign_library の `#export_name` シンボルが**最終実行ファイルに載らない**(マングル名だけ出て C エクスポート名は出ない)。
  - `moon build --target native` を foreign_library モジュールに対して単体実行しても、`link-core` に `-main` が付いて**実行ファイル扱い**になり、やはり export は出ない。
  - `moonc link-core` を手動で `-main` 抜き + `-exported_functions mb_ping:mb_ping` で叩いても export は出ず、対象関数は DCE で消える。
  - **結論**: native の「main を持たない C リンク可能ライブラリ + export」を出す正規手段が現状未成熟。→ Rust→MoonBit は下の「マングル名直参照」で行う。
  - 観測日: 2026-07-15
- **シンボルのマングリング規則**(実測):
  - トップレベル関数 `f`(パッケージ `a/b/c`)→ Mach-O シンボル `__M0FP<N><comp1><comp2>…<fnlen><fn>`。
    - `N` = パスの構成要素数、各要素は `<len><name>`。
    - `-` は `_2d`、識別子中の `_` は `__` にエスケープ。
    - Mach-O の先頭 `_`(ABI アンダースコア)込みで nm は `__M0FP…` と2本で表示。
  - 例: `username/gpui-bindings/spike` の `mb_ping` → `__M0FP38username15gpui_2dbindings5spike8mb__ping`
    - `3`(要素数) + `8username` + `15gpui_2dbindings` + `5spike` + `8mb__ping`(`mb_ping`→`mb__ping` で8字)。先頭の `38` は `3`+`8username`。
  - 例: `username/gpui-bindings/app` の `dispatch` → `__M0FP38username15gpui_2dbindings3app8dispatch`
  - 観測日: 2026-07-15
- **Rust から MoonBit 関数をマングル名で参照する**(Rust→MoonBit コールバックの実用手段):
  ```rust
  unsafe extern "C" {
      #[link_name = "_M0FP38username15gpui_2dbindings3app8dispatch"] // ← 先頭 _ は1本
      fn mb_dispatch(id: i32);
  }
  ```
  - **Mach-O は `link_name` に先頭 `_` を1本自動付与**する。nm 表示が `__M0FP…`(2本)なら、`link_name` には `_M0FP…`(1本)と書く。2本書くと参照が `___`(3本)になって未解決。
  - 脆さ: 関数/パッケージ改名・ツールチェーンのマングル変更で壊れるが**リンクエラーで即検知**でき、`nm` で新名に更新するだけ。
  - **旧説明の補足 (現在は superseded)**: `build.sh` が MoonBit ビルド出力から `app.dispatch` の実マングル名を `nm` で抽出 → `gpui-sys/mb_symbol.txt` に書き、`gpui-sys/build.rs` がそれを読んで `extern`(`#[link_name]`)を生成する。これはマングル表記の抽出だけを自動化する。改名・引数数・型・ABI 方針への自動追従ではない。
  - 観測日: 2026-07-15
- **マングル名が変わる/変わらない条件**(`#[link_name]` に直書きしているので重要):
  - **変わる**: 関数名の変更 / パッケージ名・場所(ディレクトリ)の変更 / モジュール名(`moon.mod` の `name`)の変更 / MoonBit ツールチェーンのマングル方式変更(version up)。→ いずれも**リンクエラーで即検知**でき、`nm … | grep <fn>` で得た新名を(先頭 `_` を1本にして)貼り直すだけ。
  - **変わらない**: 関数本体だけの変更、そして **引数/戻り値の型・数の変更**。マングル名は「パス + 関数名」だけで **型シグネチャを含まない**(`mb_ping()` も `dispatch(Int)` も末尾は `<len><name>` のみ、型情報なし)。
  - ⚠️ **型/引数を変えても名前は同じ = リンクは通ってしまうが、Rust 側 `extern` シグネチャと食い違うと呼び出しが不整合(サイレント UB、リンクエラーで気づけない)**。型/引数を変えたら Rust の `unsafe extern "C" { fn … }` のシグネチャを**手で必ず合わせる**(名前は変えなくてよい)。
  - 観測日: 2026-07-15
- **cbindgen は import 用 `extern "C" { fn foo(); }` もヘッダに出す**(`extern void foo(void);`)。MoonBit bindgen がそれを壊れた形で再取り込みするので、`cbindgen.toml` の `[export] exclude = ["foo"]` で除外する。
  - 観測日: 2026-07-15

## 4. エントリポイントとランタイム

- **native 出力は常に `_main` / `_moonbit_main` を持つ**(`fn main` の無い foreign_library でも、`link-core` の `-main` を外しても生成された)。
  - `_main`(C エントリ)→ `_moonbit_main`(ランタイム bootstrap: `moonbit_runtime_init` を呼ぶ)→ ユーザーの `fn main`。
  - 含意: **MoonBit がプロセスのエントリを握る前提**。Rust に `main` を持たせて MoonBit をライブラリとして埋め込む「反転」は、`_main` の重複シンボル衝突とランタイム初期化肩代わりが必要で、現状**沼**。→ MoonBit に `main` を持たせたまま Rust はコールバックで入る構成が素直。
  - 観測日: 2026-07-15
- **ランタイムは参照カウント方式**(トレース GC ではない)。`moonbit.h`: 各オブジェクトに inline `int32_t rc` ヘッダ、`moonbit_incref(void*)` / `moonbit_decref(void*)`。`moonbit_runtime_init(int argc, char** argv)` は起動時1回。
  - **再入は安全**: `run_window` 等でブロック中に、同一(メイン)スレッドから MoonBit 関数を呼ぶのはネストした C 呼び出しに過ぎない(止める world が無い)。
  - 注意: RC は**非アトミック** → コールバックはメインスレッド限定。**例外は FFI 境界を越えられない**(MoonBit の panic はプロセス abort)→ コールバック/エクスポート関数は total に保つ。
  - 観測日: 2026-07-15

## 5. デッドコード削除(DCE)

- 実行ファイルビルドでは、**MoonBit から参照されない `pub` 関数は DCE で消える**(`#export_name` 付きでも消えた)。
- Rust からマングル名でしか呼ばれない関数は、MoonBit 側から**値として参照して retain** する: `let _keep : (Int) -> Unit = @pkg.f`。
- `-Wl,-u,<sym>` だけでは、MoonBit が既に `.o` から落とした関数は復活できない(MoonBit 側で残す必要がある)。
- 観測日: 2026-07-15

## 6. コールバックの方向(Rust ↔ MoonBit)

> **現行設計 (2026-07-20)**: コールバック ABI は `app.dispatch(kind, id, a, b) -> i32`（4 個の `i32` 引数、`i32` 戻り値）に固定される。戻り値 `1` は状態変更と tree 再構築済み、`0` は no-op を表し、Rust は `1` のときだけ `cx.notify()` を呼ぶ。build driver が自動追従するのは実マングル表記だけで、生成 C の戻り値と引数を別途検証する。関数名・パッケージ名・引数数・型の変更は自動追従の対象ではなく、`abi.toml`、両 build driver、Rust extern を同時に更新する。

- **MoonBit のクロージャを C 関数ポインタとして渡すのは不可**。公開 `FuncRef`/`#callback` は無い。クロージャは RC ヒープオブジェクト `{code ptr + 環境}` で、C の `void(*)()` ではない。非キャプチャのトップレベル関数のみ内部的に raw fn ptr 化できる(未公開)。
- したがって **Rust→MoonBit は「名前付き(マングル)シンボルを Rust から参照して呼ぶ」の一択**(§3)。渡すのは `Int` 等スカラのみにして MoonBit オブジェクトを Rust 側に保持しない(incref/decref を避ける)。
- 観測日: 2026-07-15

## 7. リンク(gpui-sys のような重い Rust ライブラリ)

- **静的 `.a` を MoonBit(moon)側の最終リンクに載せると、Rust の推移的ネイティブ依存を全部供給**する必要がある。moon は Rust の依存を知らない。
  - 必要なフレームワーク/ライブラリ列は **`cargo rustc --lib --crate-type staticlib -- --print native-static-libs`** で出力できる。root build driver は毎回これを基礎列として捕捉し、選択した `moon.pkg.*` template の `@NATIVE_LIBS@` に投入する。
  - Linux は `-lxcb` / `-lxkbcommon*` を versioned SONAME の `-l:` 形式へ正規化し、runtime-only / `.linux-libs` 環境との互換性のため `libxcb-xkb.so.1` を補う。この compatibility policy は Cargo 出力とは別に driver が管理する。
  - gpui 0.2.2 の macOS 実測列: `ApplicationServices CoreFoundation CoreVideo CoreText Carbon Security CoreGraphics AppKit QuartzCore Foundation Metal SystemConfiguration OpenGL` + `-lobjc -liconv`。これは観測記録であり、最終リンクの基礎列は現在の Cargo 出力。
- **cdylib(`.dylib`)を消費**すると frameworks は焼き込み済みで楽だが、**cdylib は自ビルドで完結**するため「後からできる MoonBit のシンボル」を参照できない(Rust→MoonBit コールバック不可)。`-undefined dynamic_lookup` で無理に許すと**起動時 segfault**(未定義チェック全無効化が gpui のリンケージを壊す)。
  - → コールバックが要るなら staticlib + 上記フレームワーク列。
- 観測日: 2026-07-15
- **⚠️ moon は外部 `.a` を依存として追跡しない → 再リンクされない**。gpui-sys(cargo)だけ変更して `moon build` しても、MoonBit 側に変更が無ければ moon は「no work to do」で **exe を再リンクせず、古いバイナリが残る**(Rust 側の修正が反映されない罠)。`build.sh` は最終段で `main.exe` と `__moonbit_link_core__/main.o` を削除して**強制再リンク**する。手動なら `moon clean && moon build`。
  - 観測日: 2026-07-16(キーイベントが効かなかった主因。実際は古い exe をテストしていた)

## 8. moon.pkg / moon.mod 形式(readable / `rr_moon_pkg`・`rr_moon_mod`)

- `moon.mod`: `name = "モジュール名"`(TOML 風)。
- `moon.pkg`:
  ```
  import { "pkgA", "pkgB" }
  pkgtype(kind: "library" | "executable" | "foreign_library")   // 省略時 library 相当
  options(
    "is-main": true,
    link: { "native": { "cc-flags": "...", "cc-link-flags": "..." } },
  )
  ```
  - `pkgtype` は厳格にパースされる(不正な kind → `unknown variant … expected one of library, executable, foreign_library`)。
- 観測日: 2026-07-15

## 9. Linux(ELF / WSLg)対応での差分

- **シンボル**: ELF には Mach-O の ABI アンダースコアが無い。nm 表示は `_M0FP…`(1本)で、`#[link_name]` にはそのまま書く(剥がさない)。マングル方式自体は macOS と完全同一(moon 0.1.20260713 で確認: `_M0FP38username15gpui_2dbindings3app8dispatch`)。
  - 観測日: 2026-07-18
- **ビルドフロー差**: Linux の moon は `moonc link-core` が `cmd/main/main.c` を直接生成し、cc がコンパイル+リンクを1段で行う → **リンク失敗時に .o が残らない**(`__moonbit_link_core__/*.o` も無い)。build.sh のシンボル抽出は「.o の nm → 生成 main.c の grep」のフォールバック2段構え(2026-07-18 実装)。step 4 の強制再リンクは `main.exe` の削除だけで足りる。
  - 観測日: 2026-07-18
- **moon.pkg は per-OS 分岐不可** → `cmd/main/moon.pkg.{macos,linux}` テンプレートを build.sh が uname で選択コピーする方式に変更。
  - 観測日: 2026-07-18
- **Linux のリンク列**(`cargo rustc -- --print native-static-libs`, gpui 0.2.2): `-lstdc++ -lxcb -ldl -lxkbcommon -lxkbcommon-x11 -lgcc_s -lutil -lrt -lpthread -lm -lc`。
  - `-dev` パッケージが無い環境では `-l:libxcb.so.1 -l:libxcb-xkb.so.1 -l:libxkbcommon.so.0 -l:libxkbcommon-x11.so.0` 形式(GNU ld の `-l:` 直指定)で回避できる。`libxkbcommon-x11.so.0` は `libxcb-xkb.so.1` に依存(リンク行への明示が必要)。
  - 未インストールの runtime lib は `apt-get download` + `dpkg -x` でプロジェクトローカル(`.linux-libs/`)に展開し、リンク時 `-L`、実行時 `LD_LIBRARY_PATH` で供給(sudo 不要の暫定策。正式には `sudo apt install libxkbcommon-x11-0 libxcb-xkb1`)。
  - 観測日: 2026-07-18
- **WSLg の制約**:
  - **修正前の事象 (2026-07-18、現在は superseded)**: Wayland バックエンドは WSLg のコンポジタで `UnsupportedVersion` panic(gpui-0.2.2 `wayland/client.rs:151`、プロトコルバージョン不足)し、この panic は `extern "C"` の `gpui_run_window` を越えられず abort した。
  - **現行挙動 (2026-07-19)**: C 境界の内側で Wayland 起動 panic を捕捉し、X11 (XWayland) へ一度だけ再試行する。WSLg で確実に手動起動する方法は `env -u WAYLAND_DISPLAY` である。
  - Vulkan は WSL 用 dzn ドライバ不在でも lavapipe(CPU)で描画できる(counter アプリで CPU ~20%)。
  - クリック→dispatch→ツリー再構築→再描画のフルサイクルは X11 で動作確認済み(XTest による合成クリックで Count 加算をスクリーンショット検証)。**キー入力は headless では未検証**: WSLg は Windows 側のウィンドウアクティブ化がフォーカスを支配し、XTest/set_input_focus ではフォーカスを取れない。実機で窓をクリック→`k` で要確認。
  - 観測日: 2026-07-18
  - **後続の手動確認 (2026-07-19)**: WSL/Linux で GUI の手動操作を確認済み。この確認は上記の headless 入力制約を解消するものではなく、当該制約は 2026-07-18 時点の観測として残す。

## 10. Windows(MSVC / COFF)対応での差分

- **ビルドは `build.ps1`**(build.sh の PowerShell 版)。cl.exe が PATH に無ければ vswhere → `Enter-VsDevShell` で MSVC 環境に入る。moon は Windows でも Linux と同じく `moonc link-core` が `main.c` を直接生成する → シンボル抽出は main.c の grep(Select-String)で共通化できる。
- **x64 COFF は C シンボルに ABI アンダースコアを付けない** → `#[link_name]` は nm/main.c の名前をそのまま(ELF と同じ扱い)。マングル名は3プラットフォームで完全同一だった(moon 0.1.20260713)。
- **リンクフラグの順序**: moon はユーザーの `cc-link-flags` の**後ろ**に自前の `/link /LIBPATH:$MOON_HOME/lib` を付ける。追加の探索ディレクトリは `build.ps1` が `LIB` 環境変数へ登録し、`cc-link-flags` にはライブラリ名だけを置く。これにより、先頭にも `/link` を置いたときの LNK4044 と、`/link` を置かず `/LIBPATH:` を渡したときの D9002 の両方を避ける。
- **リンクに必要な追加 LIB ディレクトリ**(build.ps1 が自動収集):
  1. `cargo rustc -- --print native-static-libs` のライブラリ列(user32.lib, d3d系等)
  2. **gpui の build.rs が生成する `gpui.lib`**: Cargo metadata が示す target directory 配下の `<host>\debug\build\gpui-<hash>\out\`(macOS/Linux には無い Windows 固有の産物)
  3. **windows-rs のインポートライブラリ** `windows.0.5x.0.lib`: cargo レジストリ内 `windows_x86_64_msvc-*/lib/`
- **CRT は静的 `/MT` に統一**: moon の native backend はユーザー `cc-flags` の後ろに `/MT` を追加するため、`/MD` では上書きできない。`build.ps1` は Rust に `-C target-feature=+crt-static` を渡して MoonBit 側へ合わせ、Cargo が出す重複CRTの `/defaultlib:` 指定を除く。これにより D9025 と LNK4098 を避ける。
- **文字コード**: 生成 `main.c` は `/utf-8` でコンパイルする。`build.ps1` は `VSLANG=1033` を要求しつつ、ローカライズ済みMSVCが日本語を出す場合に備えてコンソールとPowerShellのnative-command pipelineもUTF-8へ切り替える。これによりログ捕捉時のCP932文字化けとC4819を避ける。
- **リンク後検証**: PEの最終exeは通常COFFシンボル表を保持しないため、`dumpbin /SYMBOLS main.exe` ではコールバックが0件になる。`main.obj` の定義1件と `gpui_sys.lib` の未解決参照1件を検証し、最終リンク成功を解決済みの根拠とする。
- **動作確認済み**(2026-07-18、2026-07-19再確認): DirectX 11 レンダリングでウィンドウ表示、クリックとキー `j`/`k`/`r`、Rust→MoonBit dispatch、再描画が動作。**キーボードは素の exe で動く**(macOS の .app バンドル要件のようなものは無い)。ルートレイアウトもウィンドウ全体を埋める。
- 観測日: 2026-07-19

---

## 確認チートシート(再測定コマンド)

```bash
# moon が実際に叩く moonc/cc コマンドを見る(-main / -exported_functions / 出力形式)
moon build --target native --dry-run

# シンボル確認(マングル名・_main の有無・export の有無)
nm _build/native/debug/build/**/__moonbit_link_core__/*.o | grep -i <name>

# Rust 静的ライブラリが要求する native 依存を列挙
cargo rustc --lib --crate-type staticlib -- --print native-static-libs 2>&1 | grep native-static-libs

# moonc のフラグ確認
~/.moon/bin/moonc link-core --help
~/.moon/bin/moonc build-package --help

# ランタイム/ABI ヘッダ
less ~/.moon/include/moonbit.h        # rc ヘッダ, incref/decref, string/bytes typedef
grep -n moonbit_runtime_init ~/.moon/lib/runtime.c
ls ~/.moon/lib/*.o ~/.moon/lib/*.a    # libmoonbitrun.o, runmain.o, runtime.o 等
```

## 関連

- [`troubleshooting.md`](./troubleshooting.md) — 具体的な不具合→修正の記録(String→char* の欠け、先頭グリフの subpixel クリップ)。
- 反転アーキテクチャの図解 Artifact(構成・リンク解決・実行時シーケンス)。
