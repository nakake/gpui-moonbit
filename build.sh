#!/usr/bin/env bash
#
# Build driver for GPUI + MoonBit.
#
# The Rust side (gpui-sys) calls back into MoonBit's `dispatch_entry` (the
# library-owned entry point apps register into, RFC 0004) by its compiled
# (mangled) symbol. That symbol is deterministic, and the prebuild script
# (moonbit-bindings/build.py, run by `moon build` via
# `--moonbit-unstable-prebuild`) computes it from gpui-sys/abi.toml, writes
# gpui-sys/mb_symbol.txt, builds the Rust staticlib, and propagates the link
# flags through a LinkConfig on the `link` package (RFC 0005). cmd/main and
# cmd/roundtrip import that package like any consumer would, so a plain
# `moon build` inside moonbit-bindings is a full build.
#
# What this script adds on top of `moon build`:
#   - codegen (ABI constants, C header, MoonBit FFI bindings) and `moon check`
#   - a forced relink of the cmd executables (moon does not track the external
#     libgpui_sys.a, so a Rust-only change would otherwise keep a stale exe)
#   - post-build verification of the callback link contract (symbol present
#     exactly once, C prototype matches abi.toml `[callback] params`)
#   - the headless round-trip test and (macOS) the Runner.app bundle
#
# See docs/moonbit-native-notes.md §3 and docs/rfc/0005-build-driver-redesign.md.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
GSYS="$ROOT/gpui-sys"
MB="$ROOT/moonbit-bindings"
BUILD_OUTPUT="$(mktemp)"
trap 'rm -f "$BUILD_OUTPUT"' EXIT

# --- CLI flags ---
# macOS builds bundle dist/Runner.app by default (keyboard delivery needs it);
# --no-bundle skips. --bundle requests bundling explicitly and is an error on
# other OSes, where .app bundles are meaningless.
BUNDLE=auto
for arg in "$@"; do
  case "$arg" in
    --bundle) BUNDLE=yes ;;
    --no-bundle) BUNDLE=no ;;
    *) echo "ERROR: unknown argument: $arg (usage: ./build.sh [--bundle|--no-bundle])" >&2; exit 1 ;;
  esac
done

# --- Platform differences ---
# Mach-O prepends one ABI underscore to every C symbol: nm shows `__M0FP…`
# while mb_symbol.txt stores the `#[link_name]` form with a single `_` (the
# linker adds the other). ELF has no ABI underscore: nm output and the stored
# name match verbatim.
case "$(uname -s)" in
  Darwin)
    if [ "$(uname -m)" != "arm64" ] && [ "$(uname -m)" != "x86_64" ]; then
      echo "ERROR: unsupported macOS architecture: $(uname -m) (supported: arm64, x86_64)" >&2
      exit 1
    fi
    OS_PKG=macos
    ;;
  Linux)
    if [ "$(uname -m)" != "x86_64" ]; then
      echo "ERROR: unsupported Linux architecture: $(uname -m) (supported: x86_64)" >&2
      exit 1
    fi
    OS_PKG=linux
    ;;
  *) echo "ERROR: unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
if [ "$OS_PKG" != macos ] && [ "$BUNDLE" = yes ]; then
  echo "ERROR: --bundle is only supported on macOS (.app bundles are macOS-specific)" >&2
  exit 1
fi

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $1" >&2
    exit 1
  fi
}

echo "==> Preflight ($OS_PKG $(uname -m))"
require_command moon
require_command cargo
require_command rustc
require_command nm
require_command python3   # runs moonbit-bindings/build.py (the prebuild script)
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
# RFC 0005 D1: build.py pins gpui-sys for the wrapper (registry) routes with a
# cargo caret requirement. The comparison lives in build.py (--check-pin, the
# single implementation both drivers share); it exits non-zero on drift.
if ! python3 "$MB/build.py" --check-pin; then
  exit 1
fi
if command -v rustup >/dev/null 2>&1; then
  rustup show active-toolchain
fi

# The pre-commit hook is opt-in: `core.hooksPath` is a local git setting that a
# clone does not inherit, so it is easy to never notice the hook exists (issue
# #82). Nudge, do not set it — silently rewriting someone's git config from a
# build script is worse than an unenforced hook.
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
   [ -z "$(git -C "$ROOT" config --get core.hooksPath || true)" ]; then
  echo "    HINT: pre-commit hook not enabled. To enable it, run:"
  echo "          git config core.hooksPath moonbit-bindings/.githooks"
fi

# The MoonBit callback whose link contract this script verifies after the
# build, derived from abi.toml so `[callback] name` stays the single source of
# truth (issue #76, RFC 0004 §3.5). build.py and gpui-sys/build.rs derive the
# full mangled symbol from the same fields.
CALLBACK_NAME="$(awk '
  { sub(/[[:space:]]*#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
  /^\[[A-Za-z_][A-Za-z0-9_]*\]$/ { section=$0; next }
  section == "[callback]" && /^name[[:space:]]*=/ {
    sub(/^name[[:space:]]*=[[:space:]]*/, "")
    gsub(/["[:space:]]/, "")
    if ($0 !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
      print "ERROR: invalid [callback] name in abi.toml: " $0 > "/dev/stderr"
      exit 1
    }
    print $0
    exit
  }
' "$GSYS/abi.toml")"
if [ -z "$CALLBACK_NAME" ]; then
  echo "ERROR: could not derive [callback] name from $GSYS/abi.toml" >&2
  exit 1
fi
CALLBACK_MODULE="$(awk '
  { sub(/[[:space:]]*#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
  /^\[[A-Za-z_][A-Za-z0-9_]*\]$/ { section=$0; next }
  section == "[callback]" && /^module[[:space:]]*=/ {
    sub(/^module[[:space:]]*=[[:space:]]*/, "")
    gsub(/["[:space:]]/, "")
    print $0
    exit
  }
' "$GSYS/abi.toml")"
# Mangled prefix of the module path (component: _ -> __ then - -> _2d, each
# length-prefixed, count first). Used only to narrow link-failure diagnostics
# to this module's symbols; function-name independent by construction.
# Keep in sync with compute_callback_symbol() in moonbit-bindings/build.py
# (the authoritative copy; a drift here only widens the diagnostic list).
MODULE_PREFIX=""
if [ -n "$CALLBACK_MODULE" ]; then
  N=0
  PARTS=""
  IFS='/' read -ra COMPONENTS <<< "$CALLBACK_MODULE"
  for comp in "${COMPONENTS[@]}"; do
    esc="$(printf '%s' "$comp" | sed -e 's/_/__/g' -e 's/-/_2d/g')"
    PARTS="${PARTS}${#esc}${esc}"
    N=$((N + 1))
  done
  MODULE_PREFIX="_M0FP${N}${PARTS}"
fi

# Expected C parameter list for the MoonBit callback, derived from abi.toml so
# `[callback] params` stays the single source of truth (issue #76).
CALLBACK_PARAMS="$(awk '
  { sub(/[[:space:]]*#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "") }
  /^\[[A-Za-z_][A-Za-z0-9_]*\]$/ { section=$0; next }
  section == "[callback]" && /^params[[:space:]]*=/ {
    sub(/^params[[:space:]]*=[[:space:]]*\[/, "")
    sub(/\][[:space:]]*$/, "")
    gsub(/["[:space:]]/, "")
    n = split($0, types, ",")
    if (n < 1) { print "ERROR: [callback] params is empty in abi.toml" > "/dev/stderr"; exit 1 }
    out = ""
    for (i = 1; i <= n; i++) {
      if (types[i] != "i32") {
        print "ERROR: unsupported [callback] param type in abi.toml: " types[i] > "/dev/stderr"
        exit 1
      }
      out = out (i > 1 ? "," : "") "int32_t"
    }
    print out
    exit
  }
' "$GSYS/abi.toml")"
if [ -z "$CALLBACK_PARAMS" ]; then
  echo "ERROR: could not derive [callback] params from $GSYS/abi.toml" >&2
  exit 1
fi

echo "==> [0/4] Regenerate the C header, ABI constants, and C FFI bindings"
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
# The header must reflect any new Rust C export BEFORE bindgen reads it:
# bindgen's output gates `moon check`, which gates the `cargo build` that
# would otherwise be the only thing regenerating the header (issue #71).
# gen-header depends on cbindgen alone, so this is cheap (no gpui build).
( cd "$ROOT/gen-header" && cargo run -- "$GSYS" "$GSYS/include/gpui_sys.h" )
( cd "$ROOT/bindgen-moonbit" && cargo run -- "$GSYS/include/gpui_sys.h" "$MB/gpui-bindings-ffi.mbt" )
( cd "$MB" && moon fmt gpui-bindings-ffi.mbt )
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
   ! git -C "$ROOT" diff --quiet -- moonbit-bindings/gpui-bindings-ffi.mbt moonbit-bindings/abi_constants.mbt; then
  echo "WARNING: generated MoonBit bindings changed. Commit the update if intentional."
fi

echo "==> [1/4] MoonBit typecheck"
( cd "$MB" && moon check ) || {
  echo "ERROR: MoonBit compilation failed" >&2
  echo "HINT: if you added a new Rust C export, the C header must be regenerated; run ./build.sh (it regenerates the header before bindgen)." >&2
  exit 1
}

echo "==> [2/4] MoonBit build (build.py builds gpui-sys and supplies the link flags)"
# moon does not track the external libgpui_sys.a, so a gpui-sys-only change
# would NOT trigger a relink of the executables (it would silently keep stale
# exes). Remove the linked outputs so moon re-links against the fresh .a.
rm -f "$MB"/_build/native/debug/build/cmd/main/main.exe \
      "$MB"/_build/native/debug/build/cmd/roundtrip/roundtrip.exe 2>/dev/null || true
if ! ( cd "$MB" && moon build ) 2>&1 | tee "$BUILD_OUTPUT"; then
  if grep -Eqi "undefined (reference|symbol)|cannot find .*gpui_sys|library.*gpui_sys|_M0FP" "$BUILD_OUTPUT"; then
    # Link failure on the callback symbol: the symbol gpui-sys referenced
    # (gpui-sys/mb_symbol.txt) does not match what the MoonBit toolchain
    # actually generated. Show the real candidates from the generated C so the
    # mismatch is diagnosable even if the mangling scheme itself changed
    # (a suffix-anchored grep would find nothing in that case).
    echo "ERROR: MoonBit native link failed." >&2
    if [ -f "$GSYS/mb_symbol.txt" ]; then
      echo "    expected callback symbol (gpui-sys/mb_symbol.txt): $(cat "$GSYS/mb_symbol.txt")" >&2
    fi
    UNRESOLVED="$(grep -Ei "undefined (reference|symbol)" "$BUILD_OUTPUT" \
        | grep -oE '_M0FP[A-Za-z0-9_]+' | sort -u || true)"
    if [ -n "$UNRESOLVED" ]; then
      echo "    unresolved symbols in the link output:" >&2
      printf '%s\n' "$UNRESOLVED" | sed 's/^/      /' >&2
    fi
    CANDIDATES="$(find "$MB/_build/native" -path '*/build/cmd/*' -name '*.c' \
        -exec grep -ohE '_M0FP[A-Za-z0-9_]+' {} \; 2>/dev/null | sort -u || true)"
    if [ -n "$CANDIDATES" ] && [ -n "$MODULE_PREFIX" ]; then
      FILTERED="$(printf '%s\n' "$CANDIDATES" | grep -E "^${MODULE_PREFIX}" || true)"
      if [ -n "$FILTERED" ]; then
        CANDIDATES="$FILTERED"
      fi
    fi
    if [ -n "$CANDIDATES" ]; then
      echo "    mangled symbols found in the generated C (module ${CALLBACK_MODULE:-?}):" >&2
      printf '%s\n' "$CANDIDATES" | sed 's/^/      /' >&2
    fi
    echo "HINT: if the expected symbol is stale, delete gpui-sys/mb_symbol.txt and re-run ./build.sh (build.py recomputes it)." >&2
    echo "HINT: if the recomputed symbol still mismatches the candidates above, the toolchain's mangling scheme changed; update compute_callback_symbol() in moonbit-bindings/build.py (gpui-sys/build.rs derives the same value)." >&2
  else
    echo "ERROR: MoonBit build failed (see output above)." >&2
  fi
  exit 1
fi

echo "==> [3/4] Verify the callback link contract in the final binary"
EXE="$MB/_build/native/debug/build/cmd/main/main.exe"
if [ ! -f "$EXE" ]; then
  echo "ERROR: final executable not found at $EXE" >&2
  exit 1
fi
# Verify the value actually in mb_symbol.txt, not a recomputation: the file is
# what gpui-sys/build.rs consumed, and keeping it authoritative preserves the
# manual-override escape hatch (write the file by hand, build.py leaves it).
if [ ! -f "$GSYS/mb_symbol.txt" ]; then
  echo "ERROR: $GSYS/mb_symbol.txt not found after moon build (build.py should have written it)" >&2
  exit 1
fi
LINK_NAME="$(head -n1 "$GSYS/mb_symbol.txt" | tr -d '[:space:]')"
if [ -z "$LINK_NAME" ]; then
  echo "ERROR: $GSYS/mb_symbol.txt is empty" >&2
  exit 1
fi
case "$OS_PKG" in
  macos) EXE_SYMBOL="_${LINK_NAME}" ;;
  linux) EXE_SYMBOL="$LINK_NAME" ;;
esac
CALLBACK_MATCHES="$(nm "$EXE" 2>/dev/null | awk -v symbol="$EXE_SYMBOL" '$(NF-1) == "T" && $NF == symbol { count++ } END { print count + 0 }')"
if [ "$CALLBACK_MATCHES" -ne 1 ]; then
  echo "ERROR: expected exactly 1 definition of ${LINK_NAME} (${CALLBACK_NAME}) in final binary, found ${CALLBACK_MATCHES}" >&2
  exit 1
fi
echo "    Verified: ${LINK_NAME} is defined exactly once"
# The mangled name does not encode types. Validate the actual generated C
# declaration when it is available (Linux generates main.c; macOS may not).
MAIN_C="$(find "$MB/_build/native" -path '*/build/cmd/main/*' -name 'main.c' -print -quit)"
if [ -n "$MAIN_C" ]; then
  PROTOTYPES="$(tr '\r\n\t' '   ' < "$MAIN_C" \
    | grep -oE "int32_t[[:space:]]+${LINK_NAME}[[:space:]]*\([^)]*\)" \
    | sed -E 's/^[^(]*\((.*)\)$/\1/; s/[[:space:]]+//g' \
    | sed -E 's/int32_t[A-Za-z_][A-Za-z0-9_]*/int32_t/g' \
    | sort -u || true)"
  PROTOTYPE_COUNT="$(printf '%s\n' "$PROTOTYPES" | sed '/^$/d' | wc -l)"
  if [ "$PROTOTYPE_COUNT" -ne 1 ] || [ "$PROTOTYPES" != "$CALLBACK_PARAMS" ]; then
    echo "ERROR: generated MoonBit callback must be int32_t ${LINK_NAME}(${CALLBACK_PARAMS//,/, }); found: ${PROTOTYPES:-none}" >&2
    exit 1
  fi
  echo "    signature : int32_t(${CALLBACK_PARAMS//,/, })"
else
  echo "    signature : skipped (generated main.c is unavailable on this platform)"
fi

echo "==> [4/4] Run headless round-trip test (issue #34)"
RT_EXE="$MB/_build/native/debug/build/cmd/roundtrip/roundtrip.exe"
if [ ! -f "$RT_EXE" ]; then
  echo "ERROR: roundtrip executable not found at $RT_EXE" >&2
  exit 1
fi
case "$OS_PKG" in
  linux) ( cd "$MB" && env -u WAYLAND_DISPLAY LD_LIBRARY_PATH="$PWD/../.linux-libs" "$RT_EXE" ) ;;
  macos) "$RT_EXE" ;;
esac

if [ "$OS_PKG" = macos ] && [ "$BUNDLE" != no ]; then
  echo "==> Bundle Runner.app (keyboard delivery needs the bundle)"
  "$ROOT/bundle.sh"
fi


case "$OS_PKG" in
  macos)
    if [ "$BUNDLE" != no ]; then
      echo "Done. Run:  open dist/Runner.app  (or ./dist/Runner.app/Contents/MacOS/Runner to keep stderr on the terminal)"
    else
      echo "Done. Run:  ./bundle.sh && open dist/Runner.app  (keyboard needs the bundle)"
    fi
    ;;
  linux) echo 'Done. Run:  (cd moonbit-bindings && env -u WAYLAND_DISPLAY LD_LIBRARY_PATH=$PWD/../.linux-libs ./_build/native/debug/build/cmd/main/main.exe)' ;;
esac
# cmd/main is the minimal runner the driver needs (a real app that registers a
# dispatch and links the staticlib end to end). The demo apps are separate
# modules under examples/ that consume this one the way a third party would
# (issue #125).
echo "Demos:      (cd examples/counter && moon build && ./_build/native/debug/build/main/main.exe)"
echo "            examples/hello and examples/stream build and run the same way."
