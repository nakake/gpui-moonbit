#!/usr/bin/env bash
#
# Build driver for GPUI + MoonBit.
#
# The Rust side (gpui-sys) calls back into MoonBit's `app.dispatch` by its
# compiled (mangled) symbol. That symbol only exists after MoonBit is compiled,
# and Rust needs it at *its* compile time (for `#[link_name]`) — a chicken/egg.
# We resolve it by extracting the *real* mangled symbol from MoonBit's build
# output and injecting it into gpui-sys's build. This tracks the actual symbol,
# so a MoonBit rename or a toolchain mangling change is picked up automatically
# (no hand-edited name). See docs/moonbit-native-notes.md §3.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
GSYS="$ROOT/gpui-sys"
MB="$ROOT/moonbit-bindings"

# --- Platform differences ---
# Mach-O prepends one ABI underscore to every C symbol: nm shows `__M0FP…` and
# `#[link_name]` must be written with a single `_` (the linker adds the other).
# ELF has no ABI underscore: nm shows `_M0FP…` and link_name takes it verbatim.
# moon.pkg cannot branch per-OS, so cmd/main keeps per-OS templates
# (moon.pkg.macos / moon.pkg.linux) and we copy the right one into place.
case "$(uname -s)" in
  Darwin) SYM_RE='^__M0FP'; OS_PKG=macos ;;
  Linux)  SYM_RE='^_M0FP';  OS_PKG=linux ;;
  *) echo "ERROR: unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
PKG_TMPL="$MB/cmd/main/moon.pkg.$OS_PKG"
if ! cmp -s "$PKG_TMPL" "$MB/cmd/main/moon.pkg"; then
  cp "$PKG_TMPL" "$MB/cmd/main/moon.pkg"
  echo "==> Selected $PKG_TMPL -> cmd/main/moon.pkg"
fi

# The MoonBit function whose mangled symbol Rust needs. Its package path suffix
# + name determine the symbol; keep in sync if you rename the callback.
PKG_FN_SUFFIX="3app8dispatch"   # …/app :: dispatch  (see notes for the scheme)

echo "==> [1/4] Compile MoonBit (produces app.dispatch; final cc link may fail on a cold build — ignored)"
( cd "$MB" && moon build ) || true

echo "==> [2/4] Extract the real mangled symbol for app.dispatch"
# Prefer nm over compiled objects (macOS flow leaves per-pkg .o files). Fall back
# to scanning the C source that `moonc link-core` generates: the Linux flow
# compiles+links it in a single cc step, so no .o survives a failed cold link.
SYM="$(find "$MB/_build/native" -name '*.o' -exec nm {} \; 2>/dev/null \
        | awk '{print $NF}' \
        | grep -E "${SYM_RE}.*${PKG_FN_SUFFIX}\$" \
        | sort -u | head -1 || true)"
if [ -z "${SYM}" ]; then
  SYM="$(find "$MB/_build/native" -name 'main.c' \
          -exec grep -ohE "_M0FP[A-Za-z0-9_]*${PKG_FN_SUFFIX}" {} \; 2>/dev/null \
          | sort -u | head -1 || true)"
fi
if [ -z "${SYM}" ]; then
  echo "ERROR: could not find the app.dispatch mangled symbol (…${PKG_FN_SUFFIX})." >&2
  echo "       Did MoonBit compile? Check '(cd $MB && moon build)'." >&2
  exit 1
fi
# `#[link_name]` on Mach-O gets one leading underscore added by the linker, so we
# store the symbol with one underscore stripped. ELF nm output and names taken
# from the generated C source have no ABI underscore — use them verbatim.
case "$SYM" in
  __M0FP*) LINK_NAME="${SYM#_}" ;;
  *)       LINK_NAME="$SYM" ;;
esac
printf '%s\n' "${LINK_NAME}" > "${GSYS}/mb_symbol.txt"
echo "    nm symbol : ${SYM}"
echo "    link_name : ${LINK_NAME}  -> ${GSYS}/mb_symbol.txt"

echo "==> [3/4] Build gpui-sys (build.rs reads mb_symbol.txt and generates the extern)"
( cd "$GSYS" && cargo build )
rm -f "${GSYS}/target/debug/libgpui_sys.dylib" \
      "${GSYS}/target/debug/libgpui_sys.so" 2>/dev/null || true  # staticlib only; drop any stale dylib/so

echo "==> [4/4] Final MoonBit build (links libgpui_sys.a + resolves the callback)"
# moon does not track the external libgpui_sys.a, so a gpui-sys-only change would
# NOT trigger a relink of the executable (it would silently keep a stale exe).
# Remove the linked outputs so moon re-links against the freshly built .a.
rm -f "$MB"/_build/native/debug/build/cmd/main/main.exe \
      "$MB"/_build/native/debug/build/cmd/main/__moonbit_link_core__/main.o 2>/dev/null || true
( cd "$MB" && moon build )

echo "Done. Run:  (cd $MB && moon run cmd/main)"
