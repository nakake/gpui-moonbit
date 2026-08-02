# Git Hooks

`moonbit-bindings/.githooks/pre-commit` はコミット時の安全網です。以下の検査を行います。

- **生成バインディングの取りこぼし** — `gpui-sys/abi.toml` から `build.sh` が再生成する
  `gpui-bindings-ffi.mbt` / `abi_constants.mbt` に未ステージの差分があると失敗します。
  再生成時に build driver は WARNING を出すだけなので、うっかりコミットし忘れるのを防ぎます。
- **`moon check`** — MoonBit の型検査
- **`moon test`** — MoonBit のテスト

## 有効化

リポジトリ root で:

```bash
git config core.hooksPath moonbit-bindings/.githooks
```

これはローカルの git 設定です。クローンには引き継がれないため、リポジトリを取得したら各自で設定してください。

## 1回だけ迂回する

```bash
git commit --no-verify
```

## コスト

`moon test` は初回や Rust 側変更後には `cargo build`（gpui-sys）を伴うため、数分かかることがあります。
2 回目以降はインクリメンタルで速くなります。

## CI に委ねていること・このフックでないこと

Rust テスト、`abi.toml` の drift guard、言語横断のリンク検証、3 OS のコールドビルドは
CI（`.github/workflows/ci.yml`）で検証しています。このフックは root の build driver
（`build.sh` / `build.ps1`）が行うクロス言語の生成・ビルド・リンク検証の代替ではありません。

## 制約

この検査は working tree に対して走るため、部分ステージのコミット（一部だけ `git add` した状態）は
ここを通過しても CI で落ちうることに注意してください。