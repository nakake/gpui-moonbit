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
# (moon.pkg.macos / moon.pkg.linux) and generates the active package from one.
case "$(uname -s)" in
  Darwin)
    if [ "$(uname -m)" != "arm64" ] && [ "$(uname -m)" != "x86_64" ]; then
      echo "ERROR: unsupported macOS architecture: $(uname -m) (supported: arm64, x86_64)" >&2
      exit 1
    fi
    SYM_RE='^__M0FP'
    OS_PKG=macos
    ;;
  Linux)
    if [ "$(uname -m)" != "x86_64" ]; then
      echo "ERROR: unsupported Linux architecture: $(uname -m) (supported: x86_64)" >&2
      exit 1
    fi
    SYM_RE='^_M0FP'
    OS_PKG=linux
    ;;
  *) echo "ERROR: unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
PKG_TMPL="$MB/cmd/main/moon.pkg.$OS_PKG"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 1
  fi
}

normalize_native_libs() {
  local native_libs="$1"
  local lib
  local normalized=""

  for lib in $native_libs; do
    # Drop libc: the cc driver links it implicitly, and passing -lc
    # explicitly fails in moon's native link on some environments
    # (CI ubuntu-latest reports "cannot find -lc").
    case "$lib" in
      -lc) continue ;;
    esac
    # macOS has no standalone libm (math lives in libSystem); drop it there.
    # Linux needs -lm: the Rust staticlib references exp/log2/log directly.
    if [ "$OS_PKG" = macos ] && [ "$lib" = "-lm" ]; then
      continue
    fi
    if [ "$OS_PKG" = linux ]; then
      case "$lib" in
        -lxcb)          lib=-l:libxcb.so.1 ;;
        -lxcb-xkb)      lib=-l:libxcb-xkb.so.1 ;;
        -lxkbcommon)    lib=-l:libxkbcommon.so.0 ;;
        -lxkbcommon-x11) lib=-l:libxkbcommon-x11.so.0 ;;
      esac
      if [ "$lib" = -l:libxcb-xkb.so.1 ] && [[ " $normalized " == *" $lib "* ]]; then
        continue
      fi
    fi
    normalized="${normalized:+$normalized }$lib"
  done
  if [ "$OS_PKG" = linux ]; then
    case " $normalized " in
      *' -l:libxcb-xkb.so.1 '*) ;;
      *) normalized="$normalized -l:libxcb-xkb.so.1" ;;
    esac
  fi
  printf '%s\n' "$normalized"
}

write_moon_pkg() {
  local native_libs="$1"
  local destination="$MB/cmd/main/moon.pkg"
  local output
  output="$(while IFS= read -r line || [ -n "$line" ]; do
    line="${line//@RUST_LIB_DIR@/$RUST_LIB_DIR}"
    printf '%s\n' "${line//@NATIVE_LIBS@/$native_libs}"
  done < "$PKG_TMPL")"
  if [ ! -f "$destination" ] || ! cmp -s "$PKG_TMPL" "$destination" || grep -q '@NATIVE_LIBS@' "$destination" ||
     [ "$(cat "$destination")" != "$output" ]; then
    printf '%s\n' "$output" > "$destination"
    echo "==> wrote cmd/main/moon.pkg ($OS_PKG)"
  fi
}

# Do this before writing generated files so unsupported hosts fail without
# modifying the checkout.
echo "==> Preflight ($OS_PKG $(uname -m))"
require_command moon
require_command cargo
require_command rustc
require_command nm
case "$OS_PKG" in
  macos)
    require_command xcrun
    if ! xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
      echo "ERROR: macOS SDK not found; install Xcode or the Command Line Tools." >&2
      exit 1
    fi
    if ! xcrun --sdk macosx --find clang >/dev/null 2>&1; then
      echo "ERROR: macOS clang not found; install Xcode or the Command Line Tools." >&2
      exit 1
    fi
    if ! xcrun --sdk macosx --find ld >/dev/null 2>&1; then
      echo "ERROR: macOS linker not found; install Xcode or the Command Line Tools." >&2
      exit 1
    fi
    ;;
  linux)
    require_command cc
    require_command c++
    LINK_PROBE="$(mktemp)"
    if ! printf 'int main(void) { return 0; }\n' \
        | cc -x c - -o "$LINK_PROBE" -L"$ROOT/.linux-libs" -Wl,--no-as-needed \
            -l:libxcb.so.1 -l:libxcb-xkb.so.1 -l:libxkbcommon.so.0 \
            -l:libxkbcommon-x11.so.0 2>"$BUILD_OUTPUT"; then
      cat "$BUILD_OUTPUT" >&2
      rm -f "$LINK_PROBE"
      echo "ERROR: the Linux linker could not resolve the required XCB/XKB libraries; install them or add them to .linux-libs/." >&2
      exit 1
    fi
    rm -f "$LINK_PROBE"
    ;;
esac
moon --version
cargo --version
rustc --version
if command -v rustup >/dev/null 2>&1; then
  rustup show active-toolchain
fi
RUST_TARGET="$(rustc -vV | awk '/^host:/ { print $2 }')"
CARGO_TARGET_ROOT="$(cd "$GSYS" && cargo metadata --no-deps --format-version 1 \
  | sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p')"
if [ -z "$RUST_TARGET" ] || [ -z "$CARGO_TARGET_ROOT" ]; then
  echo "ERROR: could not determine the native Rust target or Cargo target directory." >&2
  exit 1
fi
RUST_LIB_DIR="$CARGO_TARGET_ROOT/$RUST_TARGET/debug"
echo "    Rust target: $RUST_TARGET"
echo "    Rust library dir: $RUST_LIB_DIR"

# The MoonBit function whose mangled symbol Rust needs. Its package path suffix
# + name determine the symbol; keep in sync if you rename the callback.
PKG_FN_SUFFIX="3app8dispatch"   # …/app :: dispatch  (see notes for the scheme)

echo "==> [0/5] Regenerate ABI constants and C FFI bindings"
awk '
  BEGIN { print "// Auto-generated from gpui-sys/abi.toml. Do not edit manually." }
  # Grammar: [section] headers or key = non-negative-integer, with whitespace/comments.
  {
    original=$0
    sub(/[[:space:]]*#.*/, "")
    gsub(/^[[:space:]]+|[[:space:]]+$/, "")
    if ($0 == "") next
    if ($0 ~ /^\[[A-Za-z_][A-Za-z0-9_]*\]$/) { section=$0; next }
    if (section == "[callback]") next
    if ($0 !~ /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*[0-9]+$/) {
      print "ERROR: invalid ABI constant at " FNR ": " original > "/dev/stderr"
      failed=1
      next
    }
    split($0, assignment, "=")
    name=assignment[1]
    value=assignment[2]
    gsub(/[[:space:]]/, "", name)
    gsub(/[[:space:]]/, "", value)
    if (name == "abi_version") name="ABI_VERSION"
    print "\n///|"
    print "pub const " name " : Int = " value
  }
  END { if (failed) exit 1 }
' "$GSYS/abi.toml" > "$MB/abi_constants.mbt"
( cd "$MB" && moon fmt abi_constants.mbt )
( cd "$ROOT/bindgen-moonbit" && cargo run -- "$GSYS/include/gpui_sys.h" "$MB/gpui-bindings-ffi.mbt" )
( cd "$MB" && moon fmt gpui-bindings-ffi.mbt )
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
   ! git -C "$ROOT" diff --quiet -- moonbit-bindings/gpui-bindings-ffi.mbt moonbit-bindings/abi_constants.mbt; then
  echo "WARNING: generated MoonBit bindings changed. Commit the update if intentional."
fi

echo "==> [1a/5] MoonBit typecheck"
( cd "$MB" && moon check ) || { echo "ERROR: MoonBit compilation failed" >&2; exit 1; }

echo "==> [1b/5] MoonBit bootstrap build (native-link failure is expected before Cargo flags)"
write_moon_pkg ""
if ! ( cd "$MB" && moon build ) 2>&1 | tee "$BUILD_OUTPUT"; then
  if grep -Eqi "undefined (reference|symbol)|cannot find .*gpui_sys|library not found.*gpui_sys|library.*gpui_sys.*not found|${PKG_FN_SUFFIX}" "$BUILD_OUTPUT"; then
    echo "    (expected bootstrap native-link failure — final link remains strict)"
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
# The mangled name does not encode types. Validate the actual generated C
# declaration when it is available (Linux/Windows generate main.c; macOS may not).
MAIN_C="$(find "$MB/_build/native" -path '*/build/cmd/main/*' -name 'main.c' -print -quit)"
if [ -n "$MAIN_C" ]; then
  PROTOTYPES="$(tr '\r\n\t' '   ' < "$MAIN_C" \
    | grep -oE "int32_t[[:space:]]+${SYM}[[:space:]]*\([^)]*\)" \
    | sed -E 's/^[^(]*\((.*)\)$/\1/; s/[[:space:]]+//g' \
    | sed -E 's/int32_t[A-Za-z_][A-Za-z0-9_]*/int32_t/g' \
    | sort -u || true)"
  PROTOTYPE_COUNT="$(printf '%s\n' "$PROTOTYPES" | sed '/^$/d' | wc -l)"
  if [ "$PROTOTYPE_COUNT" -ne 1 ] || [ "$PROTOTYPES" != "int32_t,int32_t,int32_t,int32_t" ]; then
    echo "ERROR: generated MoonBit callback must be int32_t ${SYM}(int32_t, int32_t, int32_t, int32_t); found: ${PROTOTYPES:-none}" >&2
    exit 1
  fi
  echo "    signature : int32_t(int32_t, int32_t, int32_t, int32_t)"
else
  echo "    signature : skipped (generated main.c is unavailable on this platform)"
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
( cd "$GSYS" && cargo build --target "$RUST_TARGET" )
NATIVE_LIBS="$(cd "$GSYS" && cargo rustc --target "$RUST_TARGET" --lib --crate-type staticlib -- --print native-static-libs 2>&1 \
  | tr -d '\r' \
  | awk '/native-static-libs:/ && !found {
      line=$0
      sub(/^.*native-static-libs:[[:space:]]*/, "", line)
      gsub(/[[:space:]]+/, " ", line)
      sub(/^ /, "", line)
      sub(/ $/, "", line)
      found=1
    }
    END { if (found) print line }')"
if [ -z "$NATIVE_LIBS" ]; then
  echo "ERROR: cargo rustc did not report native-static-libs." >&2
  exit 1
fi
NATIVE_LIBS="$(normalize_native_libs "$NATIVE_LIBS")"
# Belt-and-suspenders: strip -lc (all platforms) and -lm (macOS) in case
# normalize missed them (observed on CI where the drop did not take effect).
NATIVE_LIBS="$(printf '%s\n' "$NATIVE_LIBS" | awk -v os="$OS_PKG" '{
  for (i = 1; i <= NF; i++) {
    if ($i == "-lc") continue
    if (os == "macos" && $i == "-lm") continue
    printf "%s%s", (n++ ? " " : ""), $i
  }
  print ""
}')"
echo "    native libs: $NATIVE_LIBS"
# moon's native linker appends -lc (Linux) and -lm (macOS) itself. In
# environments where the linker does not inherit cc's default search paths
# (observed on GitHub Actions ubuntu-latest and macos-latest), those implicit
# flags fail with "cannot find -lc" / "library 'm' not found".
#
# moon invokes ld directly (not via cc), so LIBRARY_PATH and compiler default
# search paths do not apply. Prepend -L into NATIVE_LIBS so it reaches ld
# through the generated moon.pkg cc-link-flags BEFORE any -l flags.
case "$OS_PKG" in
  linux)
    SYS_LIB_DIR="$(cd "$(dirname "$(cc -print-file-name=libc.so)")" && pwd)"
    if [ -d "$SYS_LIB_DIR" ]; then
      NATIVE_LIBS="-L$SYS_LIB_DIR $NATIVE_LIBS"
      echo "    system lib dir: $SYS_LIB_DIR"
    fi
    ;;
  macos)
    SDK_LIB_DIR="$(xcrun --show-sdk-path)/usr/lib"
    if [ -d "$SDK_LIB_DIR" ]; then
      NATIVE_LIBS="-L$SDK_LIB_DIR $NATIVE_LIBS"
      echo "    SDK lib dir: $SDK_LIB_DIR"
    fi
    # New macOS SDKs may not ship standalone libm (math lives in libSystem).
    # Create a shim so the linker can resolve -lm.
    if [ -d "$SDK_LIB_DIR" ] && [ ! -e "$SDK_LIB_DIR/libm.dylib" ] && [ ! -e "$SDK_LIB_DIR/libm.tbd" ]; then
      SHIM_DIR="$(mktemp -d)"
      if [ -e "$SDK_LIB_DIR/libSystem.tbd" ]; then
        ln -s "$SDK_LIB_DIR/libSystem.tbd" "$SHIM_DIR/libm.tbd"
      else
        ln -s /usr/lib/libSystem.B.dylib "$SHIM_DIR/libm.dylib"
      fi
      NATIVE_LIBS="-L$SHIM_DIR $NATIVE_LIBS"
      echo "    libm shim: $SHIM_DIR"
    fi
    ;;
esac
rm -f "$RUST_LIB_DIR/libgpui_sys.dylib" \
      "$RUST_LIB_DIR/libgpui_sys.so" 2>/dev/null || true  # staticlib only; drop any stale dylib/so

echo "==> [4/5] Final MoonBit build (links libgpui_sys.a + resolves the callback)"
write_moon_pkg "$NATIVE_LIBS"
echo "    moon.pkg link flags:"
grep 'cc-link-flags' "$MB/cmd/main/moon.pkg" | sed 's/^/      /'
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
