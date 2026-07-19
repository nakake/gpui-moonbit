# Git Hooks

## Pre-commit Hook

`pre-commit` は `moon check` だけを実行する最小のフックです。`moon test`、Rust build、FFI 再生成、ABI/link 検証は行いません。

## 現在の制約

このリポジトリの Git root は `moonbit-bindings/` の1階層上です。Git は pre-commit hook をリポジトリ root から実行しますが、現在のフックは単に `moon check` を呼ぶため、そのまま有効化すると MoonBit project を見つけられません。

利用する場合は、フックを次のようにしてから設定してください。

```sh
#!/bin/sh

cd moonbit-bindings && moon check
```

リポジトリ root で:

```bash
chmod +x moonbit-bindings/.githooks/pre-commit
git config core.hooksPath moonbit-bindings/.githooks
```

これはローカルの Git 設定です。root の build driver が行うクロス言語の生成・ビルド・リンク検証を置き換えるものではありません。
