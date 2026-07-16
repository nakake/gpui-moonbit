use std::path::Path;

fn main() {
    // --- Rust -> MoonBit callback symbol ---
    // `mb_symbol.txt` holds the MoonBit `app.dispatch` mangled symbol (with the
    // Mach-O leading underscore already stripped for `#[link_name]`). It is
    // produced by `build.sh`, which extracts the *real* symbol from MoonBit's
    // compiled output — so a rename or a toolchain mangling change is tracked
    // automatically. We generate the `extern` block from it.
    println!("cargo:rerun-if-changed=mb_symbol.txt");
    let link_name = std::fs::read_to_string("mb_symbol.txt")
        .map(|s| s.trim().to_string())
        .unwrap_or_default();
    if link_name.is_empty() {
        panic!(
            "gpui-sys/mb_symbol.txt is missing or empty.\n\
             The MoonBit callback symbol is injected at build time — run `./build.sh`\n\
             (which extracts app.dispatch and writes mb_symbol.txt) instead of a bare\n\
             `cargo build`."
        );
    }
    // Scalar event payload: (kind, id, a, b). Keep in sync with MoonBit's
    // `app.dispatch` — its arg types are NOT part of the mangled symbol, so a
    // signature change is only caught here / at call sites, not by the linker.
    let extern_code = format!(
        "unsafe extern \"C\" {{\n    #[link_name = \"{link_name}\"]\n    fn mb_dispatch(kind: i32, id: i32, a: i32, b: i32);\n}}\n"
    );
    let out_dir = std::env::var("OUT_DIR").unwrap();
    std::fs::write(Path::new(&out_dir).join("mb_extern.rs"), extern_code)
        .expect("write mb_extern.rs");

    // --- C header (cbindgen) ---
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    let config = cbindgen::Config::from_file("cbindgen.toml").unwrap_or_default();
    cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_config(config)
        .generate()
        .expect("Unable to generate bindings")
        .write_to_file("include/gpui_sys.h");
}
