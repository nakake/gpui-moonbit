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
BUILD_OUTPUT="$(mktemp)"
trap 'rm -f "$BUILD_OUTPUT"' EXIT

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

echo "==> [0/5] Regenerate ABI constants and C FFI bindings"
awk '
  BEGIN { print "// Auto-generated from gpui-sys/abi.toml. Do not edit manually." }
  /^\[/ { section=$0; next }
  /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*[0-9]+$/ && section != "[callback]" {
    name=$1
    if (name == "abi_version") name="ABI_VERSION"
    print "\n///|"
    print "pub const " name " : Int = " $3
  }
' "$GSYS/abi.toml" > "$MB/abi_constants.mbt"
( cd "$MB" && moon fmt abi_constants.mbt )
( cd "$ROOT/bindgen-moonbit" && cargo run -- "$GSYS/include/gpui_sys.h" "$MB/gpui-bindings-ffi.mbt" )
( cd "$MB" && moon fmt gpui-bindings-ffi.mbt )
if ! git -C "$ROOT" diff --quiet -- moonbit-bindings/gpui-bindings-ffi.mbt; then
  echo "WARNING: gpui-bindings-ffi.mbt changed after bindgen. Commit the update if intentional."
fi

echo "==> [1a/5] MoonBit typecheck"
( cd "$MB" && moon check ) || { echo "ERROR: MoonBit compilation failed" >&2; exit 1; }

echo "==> [1b/5] MoonBit build (only a missing native callback/library is tolerated)"
if ! ( cd "$MB" && moon build ) 2>&1 | tee "$BUILD_OUTPUT"; then
  if grep -Eqi "undefined (reference|symbol)|cannot find .*gpui_sys|library not found.*gpui_sys|${PKG_FN_SUFFIX}" "$BUILD_OUTPUT"; then
    echo "    (expected cold-link failure — continuing)"
  else
    echo "ERROR: MoonBit build failed for a non-link reason." >&2
    exit 1
  fi
fi

echo "==> [2/5] Extract the real mangled symbol for app.dispatch"
# Prefer nm over compiled objects (macOS flow leaves per-pkg .o files). Fall back
# to scanning the C source that `moonc link-core` generates: the Linux flow
# compiles+links it in a single cc step, so no .o survives a failed cold link.
SYM="$(find "$MB/_build/native" -path '*/build/cmd/main/*' -name '*.o' -exec nm {} \; 2>/dev/null \
        | awk '$(NF-1) == "T" {print $NF}' \
        | grep -E "${SYM_RE}.*${PKG_FN_SUFFIX}\$" \
        | sort -u || true)"
if [ -z "${SYM}" ]; then
  SYM="$(find "$MB/_build/native" -path '*/build/cmd/main/*' -name 'main.c' \
          -exec grep -ohE "_M0FP[A-Za-z0-9_]*${PKG_FN_SUFFIX}" {} \; 2>/dev/null \
          | sort -u || true)"
fi
SYM_COUNT="$(printf '%s\n' "$SYM" | sed '/^$/d' | wc -l)"
if [ "$SYM_COUNT" -ne 1 ]; then
  echo "ERROR: expected exactly 1 app.dispatch symbol (…${PKG_FN_SUFFIX}), found $SYM_COUNT." >&2
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

echo "==> [3/5] Build gpui-sys (build.rs reads mb_symbol.txt and generates the extern)"
( cd "$GSYS" && cargo build )
rm -f "${GSYS}/target/debug/libgpui_sys.dylib" \
      "${GSYS}/target/debug/libgpui_sys.so" 2>/dev/null || true  # staticlib only; drop any stale dylib/so

echo "==> [4/5] Final MoonBit build (links libgpui_sys.a + resolves the callback)"
# moon does not track the external libgpui_sys.a, so a gpui-sys-only change would
# NOT trigger a relink of the executable (it would silently keep a stale exe).
# Remove the linked outputs so moon re-links against the freshly built .a.
rm -f "$MB"/_build/native/debug/build/cmd/main/main.exe \
      "$MB"/_build/native/debug/build/cmd/main/__moonbit_link_core__/main.o 2>/dev/null || true
( cd "$MB" && moon build )

echo "==> [5/5] Verify exactly one callback definition in the final binary"
EXE="$MB/_build/native/debug/build/cmd/main/main.exe"
if [ ! -f "$EXE" ]; then
  echo "ERROR: final executable not found at $EXE" >&2
  exit 1
fi
case "$OS_PKG" in
  macos) EXE_SYMBOL="_${LINK_NAME}" ;;
  linux) EXE_SYMBOL="$LINK_NAME" ;;
esac
CALLBACK_MATCHES="$(nm "$EXE" 2>/dev/null | awk -v symbol="$EXE_SYMBOL" '$(NF-1) == "T" && $NF == symbol { count++ } END { print count + 0 }')"
if [ "$CALLBACK_MATCHES" -ne 1 ]; then
  echo "ERROR: expected exactly 1 definition of ${LINK_NAME} in final binary, found ${CALLBACK_MATCHES}" >&2
  exit 1
fi
echo "    Verified: ${LINK_NAME} is defined exactly once"

case "$OS_PKG" in
  macos) echo "Done. Run:  ./bundle.sh && open dist/Counter.app  (keyboard needs the bundle)" ;;
  linux) echo 'Done. Run:  (cd moonbit-bindings && env -u WAYLAND_DISPLAY LD_LIBRARY_PATH=$PWD/../.linux-libs ./_build/native/debug/build/cmd/main/main.exe)' ;;
esac
