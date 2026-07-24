//! G26 benchmark harness.
//!
//! - `decode/realistic_tree`: decode a realistic command buffer (nested flex
//!   rows/columns, styled divs, text nodes) through the real decoder.
//! - `decode/large_tree`: decode a wide, deep tree to stress the decoder's
//!   scaling.
//! - `render/headless_layout`: decode + headless render + taffy layout of the
//!   realistic tree through the G24 harness (`gpui_sys::headless`).
//!
//! Run with the same stub environment the tests use (the bench binary links
//! this crate, which references the MoonBit callback symbol):
//!
//! ```sh
//! cd gpui-sys
//! env GPUI_SYS_ALLOW_TEST_DISPATCH_STUB=1 \
//!     RUSTFLAGS="-L ../.linux-libs" LD_LIBRARY_PATH=../.linux-libs \
//!     cargo bench --features test-dispatch-stub,test-support
//! ```
//!
//! A bare `cargo bench` skips this target (`required-features` unmet) instead
//! of failing the link; `cargo bench --no-run` compiles it without executing.

use criterion::{BatchSize, BenchmarkId, Criterion, Throughput, criterion_group, criterion_main};
use gpui::{TestAppContext, TestDispatcher};
use gpui_sys::headless::layout_bounds;
use gpui_sys::GPUI_STATUS_OK;
use rand::SeedableRng;
use std::hint::black_box;

// Wire protocol constants (buffer version + opcodes), mirroring abi.toml. The
// generated `abi_constants` module is crate-private, so this out-of-crate
// bench uses literals.
const BUFFER_VERSION: u32 = 1;
const OP_DIV: u8 = 1;
const OP_TEXT: u8 = 2;
const OP_SET_SIZE: u8 = 3;
const OP_SET_FLEX: u8 = 5;
const OP_SET_GAP: u8 = 7;
const OP_SET_ROUNDED: u8 = 8;
const OP_SET_KEY: u8 = 10;
const OP_ADD_CHILD: u8 = 11;
const OP_SET_ROOT: u8 = 12;
const OP_SET_PADDING: u8 = 13;
const OP_SET_BG_COLOR: u8 = 15;

/// Minimal command-buffer builder (little-endian, matching the wire layout).
struct Buf(Vec<u8>);

impl Buf {
    fn new() -> Self {
        let mut b = Buf(Vec::new());
        b.0.extend_from_slice(b"GPUI");
        b.0.extend_from_slice(&BUFFER_VERSION.to_le_bytes());
        b
    }
    fn op(mut self, opcode: u8) -> Self {
        self.0.push(opcode);
        self
    }
    fn u8(self, v: u8) -> Self {
        self.op(v)
    }
    fn u32(mut self, v: u32) -> Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    fn f32(mut self, v: f32) -> Self {
        self.0.extend_from_slice(&v.to_le_bytes());
        self
    }
    fn key(self, k: &str) -> Self {
        self.op(OP_SET_KEY).u32(k.len() as u32).bytes(k.as_bytes())
    }
    fn bytes(mut self, bs: &[u8]) -> Self {
        self.0.extend_from_slice(bs);
        self
    }
    fn finish(self) -> Vec<u8> {
        self.0
    }
}

/// A realistic UI tree: a padded, rounded column with a gap, holding `rows`
/// flex rows; each row has a styled label box and a text node. Exercises div
/// nesting, flex layout, padding/gap/rounded/bg styling, keys, and text.
fn realistic_tree(rows: usize) -> Vec<u8> {
    let mut b = Buf::new()
        .op(OP_DIV)
        .key("root")
        .op(OP_SET_FLEX)
        .u8(1) // column
        .op(OP_SET_GAP)
        .f32(8.0)
        .op(OP_SET_PADDING)
        .f32(16.0)
        .op(OP_SET_ROUNDED)
        .f32(12.0)
        .op(OP_SET_BG_COLOR)
        .u8(240)
        .u8(240)
        .u8(245)
        .u8(255);
    for i in 0..rows {
        let row_key = format!("row{i}");
        let label_key = format!("label{i}");
        let text = format!("Item {i}");
        b = b
            .op(OP_DIV)
            .key(&row_key)
            .op(OP_SET_FLEX)
            .u8(0) // row
            .op(OP_SET_GAP)
            .f32(12.0)
            .op(OP_DIV)
            .key(&label_key)
            .op(OP_SET_SIZE)
            .f32(120.0)
            .f32(32.0)
            .op(OP_SET_ROUNDED)
            .f32(6.0)
            .op(OP_SET_BG_COLOR)
            .u8(80)
            .u8(120)
            .u8(200)
            .u8(255)
            .op(OP_ADD_CHILD) // label -> row
            .op(OP_TEXT)
            .u32(text.len() as u32)
            .bytes(text.as_bytes())
            .u8(20)
            .u8(20)
            .u8(20)
            .f32(16.0)
            .op(OP_ADD_CHILD); // text -> row
        b = b.op(OP_ADD_CHILD); // row -> root
    }
    b.op(OP_SET_ROOT).finish()
}

/// Decode into a private `VIEWS` slot (9998) so benches never clobber the
/// golden tests' slot 0.
fn decode(buf: &[u8]) {
    let status = gpui_sys::gpui_build_tree(9998, buf.as_ptr(), buf.len() as i32);
    assert_eq!(status, GPUI_STATUS_OK, "bench buffer must decode");
}

fn bench_decode(c: &mut Criterion) {
    let mut group = c.benchmark_group("decode");

    let realistic = realistic_tree(24);
    group.throughput(Throughput::Bytes(realistic.len() as u64));
    group.bench_with_input(
        BenchmarkId::new("realistic_tree", "24rows"),
        &realistic,
        |b, buf| b.iter(|| decode(black_box(buf))),
    );

    let large = realistic_tree(512);
    group.throughput(Throughput::Bytes(large.len() as u64));
    group.bench_with_input(
        BenchmarkId::new("large_tree", "512rows"),
        &large,
        |b, buf| b.iter(|| decode(black_box(buf))),
    );

    group.finish();
}

fn bench_headless_render(c: &mut Criterion) {
    let buf = realistic_tree(24);
    // Selectors to read back: the root plus a few rows/labels, exercising the
    // debug_bounds path over a representative set of elements.
    let selectors: Vec<&'static str> = vec!["root", "row0", "label0", "row12", "label12"];

    c.bench_function("render/headless_layout_24rows", |b| {
        b.iter_batched(
            || {
                let dispatcher = TestDispatcher::new(rand::rngs::StdRng::seed_from_u64(0xBEEF));
                TestAppContext::build(dispatcher, Some("decode_bench"))
            },
            |mut cx| {
                let bounds = layout_bounds(&mut cx, black_box(&buf), &selectors)
                    .expect("bench buffer must render");
                black_box(bounds);
            },
            BatchSize::SmallInput,
        );
    });
}

criterion_group!(benches, bench_decode, bench_headless_render);
criterion_main!(benches);
