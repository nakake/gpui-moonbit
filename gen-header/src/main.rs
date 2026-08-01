//! Standalone C header generator for gpui-sys (issue #71).
//!
//! `gpui-sys/build.rs` regenerates `include/gpui_sys.h` with cbindgen, but
//! that only runs during `cargo build` — which the build drivers reach only
//! AFTER bindgen has consumed the header and `moon check` has gated on the
//! generated bindings. A new `#[unsafe(no_mangle)] pub extern "C"` export
//! therefore deadlocked the build: stale header -> missing FFI declaration
//! -> `moon check` failure -> `cargo build` never runs -> header never
//! regenerates.
//!
//! This binary runs the same cbindgen invocation as build.rs but depends on
//! cbindgen alone, so it builds without compiling gpui or gpui-sys. The
//! drivers run it before bindgen; build.rs keeps its own generation as an
//! idempotent backstop for bare `cargo build`.
//!
//! Usage: gen-header <gpui-sys-dir> <output-header>

use std::path::Path;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: gen-header <gpui-sys-dir> <output-header>");
        return ExitCode::FAILURE;
    }
    let crate_dir = &args[1];
    let output = &args[2];

    let config_path = Path::new(crate_dir).join("cbindgen.toml");
    let config = cbindgen::Config::from_file(&config_path).unwrap_or_else(|err| {
        eprintln!("Warning: {}: {}; using default config", config_path.display(), err);
        cbindgen::Config::default()
    });
    match cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_config(config)
        .generate()
    {
        Ok(bindings) => {
            bindings.write_to_file(output);
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("Error: cbindgen failed for {crate_dir}: {err}");
            ExitCode::FAILURE
        }
    }
}
