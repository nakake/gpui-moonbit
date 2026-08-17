# Repo-specific rules (gpui-moonbit)

- `moonbit-bindings/cmd/{main,roundtrip}/moon.pkg` are tracked files (no
  per-OS templates anymore): the executables import `nakake/gpui-bindings/link`
  and the prebuild script (moonbit-bindings/build.py) supplies the link flags.
- `.linux-libs` and `gpui-sys/target` are symlinks into the main checkout
  (shared build cache / runtime libs). Do not commit, delete, or recreate them.
- Build (Linux): `./build.sh` from the worktree root. MoonBit typecheck only:
  `cd moonbit-bindings && moon check`.
- Run (Linux/WSLg, X11 workaround):
  `(cd moonbit-bindings && env -u WAYLAND_DISPLAY LD_LIBRARY_PATH=$PWD/../.linux-libs ./_build/native/debug/build/cmd/main/main.exe)`
- Docs: docs/moonbit-native-notes.md (§9 Linux, §10 Windows),
  docs/troubleshooting.md, docs/architecture.md.
- This machine is WSL2 Ubuntu; DISPLAY=:0 is available via WSLg. Windows-only
  changes (build.ps1) cannot be verified here — say so.
