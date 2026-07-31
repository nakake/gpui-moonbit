# gen-header

Standalone cbindgen runner that regenerates `gpui-sys/include/gpui_sys.h`
without building gpui-sys itself (issue #71).

The build drivers (`build.sh` / `build.ps1`) run this before
`bindgen-moonbit` so the MoonBit FFI declarations are generated from a
header that already reflects any new Rust `#[unsafe(no_mangle)] pub extern
"C"` export. `gpui-sys/build.rs` keeps the identical cbindgen invocation as
an idempotent backstop for bare `cargo build`.

Usage (from this directory):

```sh
cargo run -- ../gpui-sys ../gpui-sys/include/gpui_sys.h
```

The binary depends on cbindgen only; it never compiles gpui or gpui-sys.
