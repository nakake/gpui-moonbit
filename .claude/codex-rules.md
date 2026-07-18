# Repo-specific rules (gpui-moonbit)

- `moonbit-bindings/cmd/main/moon.pkg` is a GENERATED file (build.sh copies it
  from moon.pkg.macos / .linux / .windows). Edit the templates if needed; never
  commit moon.pkg itself (it is gitignored).
- `.linux-libs` and `gpui-sys/target` are symlinks into the main checkout
  (shared build cache / runtime libs). Do not commit, delete, or recreate them.
- Build (Linux): `./build.sh` from the worktree root. MoonBit typecheck only:
  `cd moonbit-bindings && moon check`.
- Run (Linux/WSLg, X11 workaround):
  `(cd moonbit-bindings && env -u WAYLAND_DISPLAY LD_LIBRARY_PATH=$PWD/../.linux-libs ./_build/native/debug/build/cmd/main/main.exe)`
- Docs: docs/moonbit-native-notes.md (§9 Linux, §10 Windows),
  docs/troubleshooting.md, docs/architecture.md.
- This machine is WSL2 Ubuntu; DISPLAY=:0 is available via WSLg. Windows-only
  changes (build.ps1, moon.pkg.windows) cannot be verified here — say so.
