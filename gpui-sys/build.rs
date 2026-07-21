use std::{collections::HashMap, path::Path};

fn parse_abi(abi: &str) -> (Vec<(&str, i32)>, HashMap<&str, &str>) {
    // Grammar: [section] headers or key = non-negative-integer, with whitespace/comments.
    let mut section = "";
    let mut constants = Vec::new();
    let mut callback = HashMap::new();
    for (index, raw_line) in abi.lines().enumerate() {
        let line = raw_line.split('#').next().unwrap().trim();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            let name = &line[1..line.len() - 1];
            if name.is_empty()
                || !name.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
                || !name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
            {
                panic!("invalid ABI section at line {}: {raw_line}", index + 1);
            }
            section = name;
            continue;
        }
        let (key, value) = line
            .split_once('=')
            .unwrap_or_else(|| panic!("invalid ABI assignment at line {}: {raw_line}", index + 1));
        let key = key.trim();
        let value = value.trim();
        if key.is_empty()
            || !key.starts_with(|c: char| c.is_ascii_alphabetic() || c == '_')
            || !key.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
        {
            panic!("invalid ABI key at line {}: {raw_line}", index + 1);
        }
        if section == "callback" {
            callback.insert(key, value);
            continue;
        }
        if value.is_empty() || !value.chars().all(|c| c.is_ascii_digit()) {
            panic!(
                "ABI constant at line {} must be a non-negative integer: {raw_line}",
                index + 1
            );
        }
        let value = value
            .parse::<i32>()
            .unwrap_or_else(|_| panic!("ABI constant at line {} exceeds i32", index + 1));
        constants.push((key, value));
    }
    (constants, callback)
}

fn main() {
    // --- Shared Rust/MoonBit ABI ---
    println!("cargo:rerun-if-changed=abi.toml");
    let abi = std::fs::read_to_string("abi.toml").expect("read abi.toml");
    let (constants, callback) = parse_abi(&abi);
    let mut rust_constants =
        String::from("// Auto-generated from abi.toml by build.rs. Do not edit manually.\n\n");
    for (key, value) in constants {
        let rust_name = key.to_ascii_uppercase();
        rust_constants.push_str(&format!("pub(crate) const {rust_name}: i32 = {};\n", value));
    }
    std::fs::write("src/abi_constants.rs", rust_constants).expect("write src/abi_constants.rs");

    let callback_name = callback
        .get("name")
        .unwrap_or_else(|| panic!("missing callback `name` in abi.toml"))
        .trim_matches('"');
    if callback_name != "dispatch" {
        panic!("abi.toml callback name must be `dispatch`");
    }
    let params = callback
        .get("params")
        .unwrap_or_else(|| panic!("missing callback `params` in abi.toml"))
        .trim_matches(['[', ']'])
        .split(',')
        .map(|param| param.trim().trim_matches('"'))
        .collect::<Vec<_>>();
    if params != ["i32", "i32", "i32", "i32"] {
        panic!("abi.toml callback must take four i32 parameters");
    }
    let return_type = callback
        .get("return")
        .unwrap_or_else(|| panic!("missing callback `return` in abi.toml"))
        .trim_matches('"');
    if return_type != "i32" {
        panic!("abi.toml callback must return i32");
    }

    // --- Rust -> MoonBit callback symbol ---
    // `mb_symbol.txt` holds the MoonBit `app.dispatch` mangled symbol (with the
    // Mach-O leading underscore already stripped for `#[link_name]`). It is
    // produced by `build.sh`, which extracts the *real* symbol from MoonBit's
    // compiled output — so a rename or a toolchain mangling change is tracked
    // automatically. We generate the `extern` block from it.
    println!("cargo:rerun-if-changed=mb_symbol.txt");
    println!("cargo:rerun-if-env-changed=CARGO_FEATURE_TEST_DISPATCH_STUB");
    println!("cargo:rerun-if-env-changed=GPUI_SYS_ALLOW_TEST_DISPATCH_STUB");
    let test_stub_enabled = std::env::var_os("CARGO_FEATURE_TEST_DISPATCH_STUB").is_some();
    let extern_code = if test_stub_enabled {
        if std::env::var("GPUI_SYS_ALLOW_TEST_DISPATCH_STUB").as_deref() != Ok("1") {
            panic!(
                "feature `test-dispatch-stub` is test-only; set \
                 GPUI_SYS_ALLOW_TEST_DISPATCH_STUB=1 explicitly when running gpui-sys tests"
            );
        }
        "unsafe fn mb_dispatch(_kind: i32, _id: i32, _a: i32, _b: i32) -> i32 {\n    0\n}\n"
            .to_string()
    } else {
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
        // This declaration is generated only after validating the fixed-width
        // callback signature from abi.toml above.
        format!(
            "unsafe extern \"C\" {{\n    #[link_name = \"{link_name}\"]\n    fn mb_dispatch(kind: i32, id: i32, a: i32, b: i32) -> i32;\n}}\n"
        )
    };
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
