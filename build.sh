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

# The MoonBit function whose mangled symbol Rust needs. Its package path suffix
# + name determine the symbol; keep in sync if you rename the callback.
PKG_FN_SUFFIX="3app8dispatch"   # …/app :: dispatch  (see notes for the scheme)

echo "==> [1/4] Compile MoonBit (produces app.dispatch; final cc link may fail on a cold build — ignored)"
( cd "$MB" && moon build ) || true

echo "==> [2/4] Extract the real mangled symbol for app.dispatch"
SYM="$(find "$MB/_build/native" -name '*.o' -exec nm {} \; 2>/dev/null \
        | awk '{print $NF}' \
        | grep -E "^__M0FP.*${PKG_FN_SUFFIX}\$" \
        | sort -u | head -1)"
if [ -z "${SYM}" ]; then
  echo "ERROR: could not find the app.dispatch mangled symbol (…${PKG_FN_SUFFIX})." >&2
  echo "       Did MoonBit compile? Check '(cd $MB && moon build)'." >&2
  exit 1
fi
# `#[link_name]` on Mach-O gets one leading underscore added by the linker, so we
# store the symbol with one underscore stripped.
LINK_NAME="${SYM#_}"
printf '%s\n' "${LINK_NAME}" > "${GSYS}/mb_symbol.txt"
echo "    nm symbol : ${SYM}"
echo "    link_name : ${LINK_NAME}  -> ${GSYS}/mb_symbol.txt"

echo "==> [3/4] Build gpui-sys (build.rs reads mb_symbol.txt and generates the extern)"
( cd "$GSYS" && cargo build )
rm -f "${GSYS}/target/debug/libgpui_sys.dylib" 2>/dev/null || true  # staticlib only; drop any stale dylib

echo "==> [4/4] Final MoonBit build (links libgpui_sys.a + resolves the callback)"
# moon does not track the external libgpui_sys.a, so a gpui-sys-only change would
# NOT trigger a relink of the executable (it would silently keep a stale exe).
# Remove the linked outputs so moon re-links against the freshly built .a.
rm -f "$MB"/_build/native/debug/build/cmd/main/main.exe \
      "$MB"/_build/native/debug/build/cmd/main/__moonbit_link_core__/main.o 2>/dev/null || true
( cd "$MB" && moon build )

echo "Done. Run:  (cd $MB && moon run cmd/main)"
