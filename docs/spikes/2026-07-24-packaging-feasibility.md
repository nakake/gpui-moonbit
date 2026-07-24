# スパイレポート: MoonBit native パッケージで Rust staticlib 依存を配布できるか

**Issue**: #47（P0）/ `docs/framework-gaps.md` G3
**日付**: 2026-07-24
**ツールチェイン**: `moon 0.1.20260721` / `moonc v0.10.4+fbf78f16c-nightly`
**検証環境**: Linux x86_64 (WSL2)

---

## 結論

**原理的に可能。** ただし唯一の経路である `--moonbit-unstable-prebuild` は実験的機能であり、API 安定性の保証がない。

---

## 検証した経路と結果

### 1. `cc-link-flags` の依存伝播 — ❌ 不可

ライブラリパッケージの `moon.pkg` に `cc-link-flags` を宣言しても、それを import する exe の最終リンクには**伝播しない**。

- 実機検証: ライブラリ pkg に `-L… -lspike` を宣言 → 消費者 exe で `undefined reference to 'spike_answer'`
- 対照: exe 側に同じフラグを宣言 → リンク成功、実行出力 `42`
- 公式見解: [moon#1595](https://github.com/moonbitlang/moon/issues/1595) — メンテナが「`link` オプションはそのパッケージがエントリポイント（`fn main`）か dylib のときだけ適用される」と明言
- 公式ドキュメント: 「Currently, `link` does not work for the native backend」（※ `link: true` のリンク出力/dylib 生成の話。executable の `cc-link-flags` 自体は動作するが伝播しない）

### 2. `native-stub` — ❌ 用途不一致

`native-stub` は C **ソースファイル**をパッケージと共にコンパイルする仕組み。事前ビルド済み `.a` アーカイブの配布機構ではない。Rust staticlib のリンクには使えない。

### 3. `rule` / `dev_build`（pre-build フック）— ❌ 依存では実行されない

公式ドキュメント: 「When the package is used as a dependency by downstream users, these pre-build steps are not triggered for security reasons」。ライブラリパッケージ内で `cargo build` を走らせるビルドフックとしては使えない。

### 4. `--moonbit-unstable-prebuild` — ✅ 成立

`moon.mod` の `options("--moonbit-unstable-prebuild": "build.py")` で登録したスクリプト（JS/Python）が、**依存モジュールとして消費された場合でも実行される**。スクリプトは:

- **シェルコマンド実行可能**（`subprocess.run(["cc", "--version"])` 成功確認）
- **LinkConfig JSON を stdout に出力**すると、指定パッケージのリンク設定に反映される
- LinkConfig の `link_libs` / `link_search_paths` / `link_flags` は **「propagated to dependents」**（依存先へ伝播）
- 制約: LinkConfig の `package` は**自モジュール内のパッケージのみ**指定可能（外部パッケージ指定は `cannot apply config to an external package` で拒否）

#### 実機検証の伝播チェーン

```
dep モジュール (spike/dep)
  └─ moon.mod: --moonbit-unstable-prebuild = "build.py"
  └─ nativelib/lib.mbt: extern "C" fn spike_answer_ffi() -> Int = "spike_answer"
  └─ build.py: LinkConfig { package: "spike/dep/nativelib",
                            link_libs: ["spike"],
                            link_search_paths: ["/tmp/spike/libs"] }

app モジュール (spike/app)
  └─ moon.mod: import { "spike/dep@0.1.0" }
  └─ main/main.mbt: println(@nativelib.answer())
  └─ main/moon.pkg: pkgtype(kind: "executable")  ← cc-link-flags 無し

結果: DEP PREBUILD RAN → ビルド成功 → ./main.exe → 42
```

---

## 配布形態の選択肢

### A. prebuild 方式（スパイク検証済み）

ライブラリモジュールに `build.py`（または `.js`）を同梱。消費者の `moon build` 時に:

1. prebuild スクリプトが実行される
2. スクリプト内で `cargo build --target <host> --crate-type staticlib` を実行
3. `cargo rustc -- --print native-static-libs` でリンクフラグを捕捉
4. LinkConfig JSON を出力（`link_libs: ["gpui_sys"]` + `link_search_paths` + native libs）
5. 消費者の exe が自動的にリンクされる

**前提条件**:
- Rust ソース（`gpui-sys/`）をパッケージに含める必要がある（mooncakes 公開時は `include` で指定）
- 消費者の環境に Rust ツールチェイン（cargo/rustc）が必須
- per-OS のリンクフラグ正規化（Linux の `-l:` SONAME 形式、macOS の framework 列、Windows の CRT 統一）をスクリプト内で再現する必要がある

**リスク**:
- `--moonbit-unstable-prebuild` は「extremely experimental, API may change at any time」
- セキュリティ警告: 「may execute arbitrary code in your computer. Use with caution and only with trusted dependencies」
- API 変更で LinkConfig の形式や伝播セマンティクスが変わる可能性

### B. テンプレートリポジトリ / CLI スキャフォールド

現状の `build.sh`/`build.ps1` 方式をテンプレート化。消費者が自分のリポジトリに組み込む。

- 利点: 実験的機能に依存しない、現状のビルドロジックをそのまま使える
- 欠点: 「依存関係として追加」ではなく「リポジトリを fork/clone」する体験。バージョン追従が手動

### C. vendored アーカイブ

事前ビルド済み `.a` を配布（GitHub Releases 等）。消費者が `cc-link-flags` で手動指定。

- 利点: 消費者に Rust ツールチェイン不要
- 欠点: ホスト/ターゲットごとのビルド済みアーカイブを配布する必要がある。`cc-link-flags` は伝播しないので消費者の exe パッケージに手動記述

---

## 推奨

**A（prebuild 方式）を主軸に、B（テンプレート）をフォールバックとして併記する。**

理由:
- A は「`moon add` で依存追加 → `moon build` で動く」というパッケージマネージャ本来の体験を実現する唯一の経路
- 実験的機能のリスクは、`build.py` を薄く保ち（cargo 呼び出し + LinkConfig 出力のみ）、API 変更時の修正コストを最小化することで緩和できる
- B は A の API が壊れた場合の退避先として常に維持する（現状の build.sh がそのまま B の実装）

---

## 未検証・今後の課題

- [ ] macOS / Windows での prebuild 動作確認（シェル実行の可否、パス形式）
- [ ] mooncakes 公開時の `include` で Rust ソースが正しくパッケージされるか
- [ ] prebuild スクリプトへの `host`/`target` 情報の渡り方（`BuildScriptEnvironment.paths` の詳細）
- [ ] `vars` 出力で `${build.<var>}` を `moon.pkg` の `cc-link-flags` に展開する経路（per-OS フラグの動的生成）
- [ ] 実際の gpui-sys（1.2GB の debug `.a`）で prebuild 内の cargo build が実用的な時間で完了するか
- [ ] `--moonbit-unstable-prebuild` の API 安定性に関する moonbitlang/moon の issue/roadmap 調査
