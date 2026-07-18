use std::path::Path;

fn abi_value<'a>(abi: &'a str, key: &str) -> &'a str {
    abi.lines()
        .map(str::trim)
        .find_map(|line| line.strip_prefix(&format!("{key} = ")))
        .unwrap_or_else(|| panic!("missing `{key}` in abi.toml"))
}

fn abi_i32(abi: &str, key: &str) -> i32 {
    abi_value(abi, key)
        .parse()
        .unwrap_or_else(|_| panic!("`{key}` in abi.toml must be an i32"))
}

fn main() {
    // --- Shared Rust/MoonBit ABI ---
    println!("cargo:rerun-if-changed=abi.toml");
    let abi = std::fs::read_to_string("abi.toml").expect("read abi.toml");
    let constants = [
        "abi_version",
        "EVENT_CLICK",
        "EVENT_KEY",
        "MOD_CTRL",
        "MOD_ALT",
        "MOD_SHIFT",
        "MOD_PLATFORM",
        "MOD_FUNCTION",
    ];
    let mut rust_constants =
        String::from("// Auto-generated from abi.toml by build.rs. Do not edit manually.\n\n");
    for key in constants {
        let rust_name = key.to_ascii_uppercase();
        rust_constants.push_str(&format!(
            "pub(crate) const {rust_name}: i32 = {};\n",
            abi_i32(&abi, key)
        ));
    }
    std::fs::write("src/abi_constants.rs", rust_constants).expect("write src/abi_constants.rs");

    let callback_name = abi_value(&abi, "name").trim_matches('"');
    if callback_name != "dispatch" {
        panic!("abi.toml callback name must be `dispatch`");
    }
    let params = abi_value(&abi, "params")
        .trim_matches(['[', ']'])
        .split(',')
        .map(|param| param.trim().trim_matches('"'))
        .collect::<Vec<_>>();
    if params != ["i32", "i32", "i32", "i32"] {
        panic!("abi.toml callback must be dispatch(i32, i32, i32, i32)");
    }

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
    // This declaration is generated only after validating callback arity and
    // fixed-width types from abi.toml above.
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
