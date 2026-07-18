#!/usr/bin/env bash
# codex-delegate scaffold hook: prepare an issue worktree for this repo.
# Called as: codex-scaffold.sh <worktree> <main-checkout>
set -euo pipefail
WT="$1"; REPO="$2"

# moon.pkg is a build product; place the Linux template so moon check/build works
cp "$WT/moonbit-bindings/cmd/main/moon.pkg.linux" "$WT/moonbit-bindings/cmd/main/moon.pkg"

# Share the heavy cargo cache (5G+) and runtime libs from the main checkout.
# Concurrent cargo builds are safe (cargo file-locks the target dir).
rm -rf "$WT/gpui-sys/target"
ln -sfn "$REPO/gpui-sys/target" "$WT/gpui-sys/target"
ln -sfn "$REPO/.linux-libs" "$WT/.linux-libs"
