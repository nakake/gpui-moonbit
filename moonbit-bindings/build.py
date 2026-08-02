#!/usr/bin/env python3
"""
Prebuild script for nakake/gpui-bindings (issue #93, G2).

Registered in moon.mod via `options("--moonbit-unstable-prebuild": "build.py")`.
Runs when this module is consumed as a path/git dependency, or when the module
itself is built with `moon build` / `moon test`.

What it does:
  1. Computes the MoonBit callback symbol (app.dispatch) deterministically.
  2. Writes gpui-sys/mb_symbol.txt if absent (standalone builds without build.sh).
  3. Runs `cargo build` to produce libgpui_sys.a.
  4. Runs `cargo rustc -- --print native-static-libs` to capture link flags.
  5. Normalizes the flags per-OS (mirrors build.sh logic).
  6. Outputs a LinkConfig JSON to stdout (the ONLY stdout output).

All diagnostic output goes to stderr. stdout is reserved for the JSON output —
moon parses the entire stdout as JSON (serde_json::from_slice).

Protocol reference (moon 0.1.20260721, crates/moonutil/src/build_script.rs):
  stdin:  {"env": {...}, "paths": {"module_root": "...", "out_dir": "TODO"}}
  stdout: {"link_configs": [{"package": "...", "link_flags": "...", ...}]}
  stderr: inherited (free-form diagnostics)

Limitations:
  - Linux x86_64: verified.
  - macOS arm64/x86_64: best-effort, unverified (no test environment).
  - Windows MSVC x64: MSVC-style flags (/LIBPATH:, gpui_sys.lib)
    implemented; being verified on windows-latest CI.
  - `rerun_if` does not work in current moon; cargo build runs on every
    `moon build` invocation (incremental, so warm builds are fast).
"""

import glob
import json
import os
import platform
import re
import subprocess
import sys


def log(msg):
    """Diagnostic output to stderr (stdout is reserved for JSON)."""
    sys.stderr.write(f"[gpui-bindings prebuild] {msg}\n")
    sys.stderr.flush()


def escape_mangling_component(s):
    """Escape a path component for MoonBit symbol mangling.

    Rules (verified 2026-08-01, moon 0.1.20260721):
      '_' -> '__'  (first)
      '-' -> '_2d' (second)
    """
    return s.replace("_", "__").replace("-", "_2d")


def compute_callback_symbol():
    """Compute the mangled symbol for nakake/gpui-bindings :: app :: dispatch.

    Mangling scheme: _M0FP<N><len1><comp1><len2><comp2>...<fnlen><fn>
    where N = number of path components (module parts + package).

    For module nakake/gpui-bindings, package app, function dispatch:
      components: ["nakake", "gpui-bindings", "app"]
      escaped:    ["nakake", "gpui_2dbindings", "app"]
      fn:         "dispatch" (no escaping needed)
      -> _M0FP3 6nakake 15gpui_2dbindings 3app 8dispatch
      -> _M0FP36nakake15gpui_2dbindings3app8dispatch

    The leading '_' is the ELF symbol prefix. Mach-O adds one more via the
    linker (#[link_name] uses one underscore; the linker adds the other).
    """
    module_parts = ["nakake", "gpui-bindings"]
    package = "app"
    function = "dispatch"

    components = [escape_mangling_component(p) for p in module_parts]
    components.append(escape_mangling_component(package))
    fn = escape_mangling_component(function)

    parts = [str(len(components))]  # N
    for comp in components:
        parts.append(str(len(comp)))
        parts.append(comp)
    parts.append(str(len(fn)))
    parts.append(fn)

    return "_M0FP" + "".join(parts)


def normalize_native_libs(native_libs_str, os_pkg):
    """Normalize cargo's native-static-libs output per-OS.

    Mirrors build.sh's normalize_native_libs + belt-and-suspenders logic:
      - Drop -lc (all platforms): cc driver links it implicitly.
      - macOS: drop -lm (math lives in libSystem).
      - Linux: rewrite XCB/XKB to versioned SONAME form (-l:libfoo.so.N).
      - Linux: ensure -l:libxcb-xkb.so.1 is present.
      - Windows: drop /defaultlib:(libcmt|msvcrt) (moon links /MT always).
    """
    tokens = native_libs_str.split()
    normalized = []

    for lib in tokens:
        if lib == "-lc":
            continue
        if os_pkg == "windows" and re.match(
            r"^/defaultlib:(libcmt|msvcrt)$", lib, re.IGNORECASE
        ):
            continue
        if os_pkg == "macos" and lib == "-lm":
            continue
        if os_pkg == "linux":
            replacements = {
                "-lxcb": "-l:libxcb.so.1",
                "-lxcb-xkb": "-l:libxcb-xkb.so.1",
                "-lxkbcommon": "-l:libxkbcommon.so.0",
                "-lxkbcommon-x11": "-l:libxkbcommon-x11.so.0",
            }
            if lib in replacements:
                lib = replacements[lib]
            if lib == "-l:libxcb-xkb.so.1" and lib in normalized:
                continue
        normalized.append(lib)

    if os_pkg == "linux" and "-l:libxcb-xkb.so.1" not in normalized:
        normalized.append("-l:libxcb-xkb.so.1")

    return normalized


def run(cmd, **kwargs):
    """Run a command, logging it. Raises on failure."""
    log(f"  $ {' '.join(cmd)}")
    return subprocess.run(cmd, **kwargs)


def msvc_path(path):
    """Format a Windows path for a link flag.

    moon parses link_flags with shlex, which eats backslashes as escapes
    (observed in PR #102 CI logs). link.exe accepts forward-slash paths, so
    normalize to '/'. Wrap in double quotes when the path contains whitespace
    so shlex does not split it.
    """
    p = os.path.abspath(path).replace("\\", "/")
    if any(c.isspace() for c in p):
        return '"' + p + '"'
    return p


def cargo_build(gpui_sys, rust_target):
    """Build gpui-sys with `cargo build`. Logs and exits on failure."""
    log("building gpui-sys...")
    result = run(
        ["cargo", "build", "--target", rust_target],
        cwd=gpui_sys,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        log("ERROR: cargo build failed:")
        sys.stderr.write(result.stderr)
        sys.exit(1)


def extract_native_libs(gpui_sys, rust_target):
    """Capture cargo's native-static-libs list. Logs and exits on failure."""
    log("extracting native-static-libs...")
    result = run(
        [
            "cargo", "rustc", "--target", rust_target,
            "--lib", "--crate-type", "staticlib",
            "--", "--print", "native-static-libs",
        ],
        cwd=gpui_sys,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        log("ERROR: cargo rustc --print native-static-libs failed:")
        sys.stderr.write(result.stderr)
        sys.exit(1)

    # rustc prints native-static-libs to stderr
    native_libs_line = ""
    for line in result.stderr.splitlines():
        line = re.sub(r"\x1b\[[0-9;]*m", "", line)  # strip ANSI
        if "native-static-libs:" in line:
            native_libs_line = line.split("native-static-libs:", 1)[1].strip()
            break
    if not native_libs_line:
        log("ERROR: could not find native-static-libs in cargo output")
        sys.exit(1)
    log(f"raw native libs: {native_libs_line}")
    return native_libs_line


def main():
    # --- Read BuildScriptEnvironment from stdin ---
    env_input = json.load(sys.stdin)
    module_root = env_input["paths"]["module_root"]
    log(f"module_root={module_root}")

    # --- Determine OS ---
    system = platform.system()
    if system == "Linux":
        os_pkg = "linux"
    elif system == "Darwin":
        os_pkg = "macos"
    elif system == "Windows":
        os_pkg = "windows"
    else:
        log(f"ERROR: unsupported OS: {system}")
        sys.exit(1)
    log(f"os={os_pkg} arch={platform.machine()}")

    # --- Locate gpui-sys (sibling of the module root) ---
    gpui_sys = os.path.normpath(os.path.join(module_root, "..", "gpui-sys"))
    if not os.path.isdir(gpui_sys):
        log(f"ERROR: gpui-sys not found at {gpui_sys}")
        log("This module must be consumed from a checkout where gpui-sys/ is")
        log("a sibling of moonbit-bindings/ (path dependency or git clone).")
        sys.exit(1)

    # --- Compute and write the callback symbol ---
    symbol = compute_callback_symbol()
    log(f"callback symbol: {symbol}")

    mb_symbol_path = os.path.join(gpui_sys, "mb_symbol.txt")
    if os.path.exists(mb_symbol_path):
        with open(mb_symbol_path) as f:
            existing = f.read().strip()
        if existing and existing != symbol:
            log(f"WARNING: mb_symbol.txt='{existing}' != computed='{symbol}'")
            log("The mangling scheme may have changed. Verify and update")
            log("compute_callback_symbol() in build.py.")
    else:
        with open(mb_symbol_path, "w") as f:
            f.write(symbol + "\n")
        log(f"wrote {mb_symbol_path}")

    # --- Determine Rust host target ---
    result = run(["rustc", "-vV"], capture_output=True, text=True, check=True)
    rust_target = None
    for line in result.stdout.splitlines():
        if line.startswith("host:"):
            rust_target = line.split(":", 1)[1].strip()
            break
    if not rust_target:
        log("ERROR: could not determine Rust host target from `rustc -vV`")
        sys.exit(1)
    log(f"rust target: {rust_target}")

    # --- Force the static CRT on Windows ---
    if os_pkg == "windows":
        # moon's native backend always compiles and links with /MT (it appends
        # /MT after user flags, so /MD can never win); build the Rust static
        # lib with the same static CRT to avoid a CRT mismatch at link time.
        flag = "-C target-feature=+crt-static"
        existing = os.environ.get("RUSTFLAGS", "")
        if "target-feature=+crt-static" not in existing:
            os.environ["RUSTFLAGS"] = (existing + " " + flag).strip() if existing else flag
        log(f"RUSTFLAGS={os.environ['RUSTFLAGS']}")

    # --- Determine the Rust library directory ---
    result = run(
        ["cargo", "metadata", "--no-deps", "--format-version", "1"],
        cwd=gpui_sys,
        capture_output=True,
        text=True,
        check=True,
    )
    metadata = json.loads(result.stdout)
    target_dir = metadata["target_directory"]
    rust_lib_dir = os.path.join(target_dir, rust_target, "debug")
    log(f"rust lib dir: {rust_lib_dir}")

    # --- Build gpui-sys / extract native-static-libs ---
    # On Windows the print step runs FIRST: `cargo rustc -- --print` may
    # invalidate a previously built .lib (cargo cleans stale artifacts and
    # rustc exits after printing without producing output), so running
    # `cargo build` last guarantees gpui_sys.lib exists for moon's link step.
    if os_pkg == "windows":
        native_libs_line = extract_native_libs(gpui_sys, rust_target)
        cargo_build(gpui_sys, rust_target)
        gpui_sys_lib = os.path.join(rust_lib_dir, "gpui_sys.lib")
        if not os.path.exists(gpui_sys_lib):
            log(f"ERROR: {gpui_sys_lib} not found after cargo build")
            sys.exit(1)
    else:
        cargo_build(gpui_sys, rust_target)
        native_libs_line = extract_native_libs(gpui_sys, rust_target)

    # --- Normalize per-OS ---
    normalized = normalize_native_libs(native_libs_line, os_pkg)

    # --- Assemble link flags (order matters: search paths before libs) ---
    if os_pkg == "windows":
        # gpui's build.rs emits an extra static lib (gpui.lib) under
        # target/<host>/debug/build on Windows; add every dir holding a .lib.
        extra_dirs = []
        build_tree = os.path.join(rust_lib_dir, "build")
        if os.path.isdir(build_tree):
            for root, _dirs, files in os.walk(build_tree):
                if any(name.endswith(".lib") for name in files):
                    extra_dirs.append(root)

        # windows-rs ships its import libs inside the cargo registry checkout;
        # the linker needs those dirs on the search path too.
        win_lib_dirs = []
        user_profile = os.environ.get("USERPROFILE")
        if user_profile:
            registry_src = os.path.join(user_profile, ".cargo", "registry", "src")
            for d in sorted(glob.glob(
                os.path.join(registry_src, "*", "windows_x86_64_msvc-*", "lib")
            )):
                if os.path.isdir(d):
                    win_lib_dirs.append(d)

        # Dedupe preserving order.
        seen = set()
        lib_dirs = []
        for d in [rust_lib_dir] + extra_dirs + win_lib_dirs:
            if d not in seen:
                seen.add(d)
                lib_dirs.append(d)
        search_paths = ["/LIBPATH:" + msvc_path(d) for d in lib_dirs]
        log(f"LIBPATH dirs: {'; '.join(lib_dirs)}")
    else:
        search_paths = [f"-L{rust_lib_dir}"]

        # .linux-libs fallback (repo-level, gitignored)
        linux_libs = os.path.normpath(os.path.join(module_root, "..", ".linux-libs"))
        if os_pkg == "linux" and os.path.isdir(linux_libs):
            search_paths.append(f"-L{linux_libs}")
            log(f"using .linux-libs fallback: {linux_libs}")

        # System lib dir (for environments where ld doesn't inherit cc's defaults)
        if os_pkg == "linux":
            result = run(
                ["cc", "-print-file-name=libc.so"],
                capture_output=True, text=True, check=True,
            )
            libc_path = result.stdout.strip()
            if libc_path and libc_path != "libc.so":
                sys_lib_dir = os.path.dirname(os.path.abspath(libc_path))
                if os.path.isdir(sys_lib_dir):
                    search_paths.append(f"-L{sys_lib_dir}")
                    log(f"system lib dir: {sys_lib_dir}")
        elif os_pkg == "macos":
            result = run(
                ["xcrun", "--show-sdk-path"],
                capture_output=True, text=True, check=True,
            )
            sdk_lib_dir = os.path.join(result.stdout.strip(), "usr", "lib")
            if os.path.isdir(sdk_lib_dir):
                search_paths.append(f"-L{sdk_lib_dir}")
                log(f"SDK lib dir: {sdk_lib_dir}")
            # IOSurface is not always reported by cargo's native-static-libs
            normalized.extend(["-framework", "IOSurface"])

    # Final flag string: search paths -> gpui_sys -> normalized native libs
    if os_pkg == "windows":
        all_flags = search_paths + ["gpui_sys.lib"] + normalized
    else:
        all_flags = search_paths + ["-lgpui_sys"] + normalized
    link_flags = " ".join(all_flags)
    log(f"link_flags: {link_flags}")

    # --- Output LinkConfig JSON (the ONLY stdout output) ---
    output = {
        "link_configs": [
            {
                "package": "nakake/gpui-bindings/link",
                "link_flags": link_flags,
            }
        ]
    }
    print(json.dumps(output))


if __name__ == "__main__":
    main()
