use gpui::*;
use std::any::Any;
use std::cell::{Cell, RefCell};
use std::collections::HashMap;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::rc::Rc;
use std::sync::Mutex;

/// Headless layout harness (G24): decode a command buffer through the real
/// decoder, render it in a gpui `TestAppContext` window (no GPU, no display),
/// and read element geometry back via `debug_bounds`. Compiled for unit tests
/// and for the `test-support` feature (benches / integration tests); the
/// staticlib build has neither and stays free of gpui's `test-support`.
#[cfg(any(test, feature = "test-support"))]
pub mod headless;

mod abi_constants;
use abi_constants::{
    ABI_VERSION, ALIGN_CENTER, ALIGN_DEFAULT, ALIGN_END, ALIGN_START, ALIGN_STRETCH,
    BUFFER_VERSION, CURSOR_ARROW, CURSOR_COL_RESIZE, CURSOR_CROSSHAIR, CURSOR_EW_RESIZE,
    CURSOR_GRAB, CURSOR_GRABBING, CURSOR_NONE, CURSOR_NOT_ALLOWED, CURSOR_NS_RESIZE,
    CURSOR_POINTER, CURSOR_ROW_RESIZE, CURSOR_TEXT, EVENT_CLICK, EVENT_KEY, EVENT_NAMED_KEY,
    EVENT_TEXT, JUSTIFY_CENTER, JUSTIFY_DEFAULT, JUSTIFY_END, JUSTIFY_SPACE_AROUND,
    JUSTIFY_SPACE_BETWEEN, JUSTIFY_START, KEY_BACKSPACE, KEY_DELETE, KEY_DOWN, KEY_END,
    KEY_ENTER, KEY_ESCAPE, KEY_HOME, KEY_LEFT, KEY_PAGEUP, KEY_PAGEDOWN, KEY_RIGHT, KEY_TAB,
    KEY_UP, MOD_ALT, MOD_CTRL, MOD_FUNCTION, MOD_PLATFORM, MOD_SHIFT, OP_ADD_CHILD, OP_DIV,
    OP_SET_ALIGN, OP_SET_BG, OP_SET_BG_COLOR, OP_SET_BORDER, OP_SET_CENTER, OP_SET_CURSOR,
    OP_SET_FLEX, OP_SET_FLEX_ITEM, OP_SET_FOCUSABLE, OP_SET_FONT_FAMILY, OP_SET_FONT_WEIGHT,
    OP_SET_GAP, OP_SET_INSET, OP_SET_KEY, OP_SET_LINE_HEIGHT, OP_SET_MARGIN, OP_SET_MAX_SIZE,
    OP_SET_MIN_SIZE, OP_SET_ON_CLICK, OP_SET_OPACITY, OP_SET_OVERFLOW, OP_SET_PADDING,
    OP_SET_PADDING_SIDES, OP_SET_POSITION, OP_SET_ROOT, OP_SET_ROUNDED, OP_SET_SHADOW,
    OP_SET_SIZE, OP_SET_TAB_INDEX, OP_SET_TAB_STOP, OP_SET_TEXT_ALIGN, OP_SET_TEXT_COLOR,
    OP_SET_TEXT_SIZE, OP_SET_WHITESPACE, OP_TEXT, OVERFLOW_HIDDEN, OVERFLOW_SCROLL,
    OVERFLOW_VISIBLE, POSITION_ABSOLUTE, POSITION_RELATIVE, TEXT_ALIGN_CENTER,
    TEXT_ALIGN_DEFAULT, TEXT_ALIGN_JUSTIFY, TEXT_ALIGN_LEFT, TEXT_ALIGN_RIGHT,
    WHITESPACE_DEFAULT, WHITESPACE_NORMAL, WHITESPACE_NOWRAP, WHITESPACE_PRE, WHITESPACE_PRE_WRAP,
};

// Reference the version as a build-time sanity anchor until runtime FFI negotiation exists.
const _: () = assert!(ABI_VERSION > 0);

/// Committed trees, one slot per view id. `render` reads the slot for its own
/// view; a successful `gpui_build_tree` swaps a freshly built tree into it.
/// `None` = no tree committed yet (the view renders empty).
static VIEWS: Mutex<Vec<Option<UiNode>>> = Mutex::new(Vec::new());

/// Serializes every test that mutates the process-global `VIEWS`. The unit
/// tests (`mod tests`), the headless golden tests (`headless_tests`, via
/// `headless::layout_bounds`), and the fuzz tests (`fuzz_tests`) all commit
/// into `VIEWS`; without one shared lock they would run concurrently and
/// clobber each other's trees (e.g. `mod tests`'s `clear_state()` wiping a
/// slot mid-render). One lock, held for the duration of each test, keeps them
/// mutually exclusive.
#[cfg(any(test, feature = "test-support"))]
static TEST_VIEWS_MUTEX: Mutex<()> = Mutex::new(());

/// Operation completed successfully.
pub const GPUI_STATUS_OK: i32 = 0;
/// A handle was negative, out of range, duplicated, or could not be allocated.
pub const GPUI_STATUS_INVALID_HANDLE: i32 = -1;
/// The handle refers to the wrong kind of node for the requested operation.
pub const GPUI_STATUS_WRONG_NODE_KIND: i32 = -2;
/// The node was already moved into another node by `gpui_add_child`.
pub const GPUI_STATUS_NODE_ABSENT: i32 = -3;
/// An internal panic was caught before it could cross the C boundary.
pub const GPUI_STATUS_INTERNAL_PANIC: i32 = -4;
/// The command buffer header magic or version did not match.
pub const GPUI_STATUS_BAD_BUFFER_VERSION: i32 = -5;
/// The command buffer ended mid-field, or carried a truncated/oversized payload.
pub const GPUI_STATUS_TRUNCATED_BUFFER: i32 = -6;
/// The command buffer named an opcode this build does not recognize.
pub const GPUI_STATUS_UNKNOWN_OPCODE: i32 = -7;
/// `gpui_build_tree` finished without an `OP_SET_ROOT` designating a root.
pub const GPUI_STATUS_NO_ROOT: i32 = -8;
/// Two or more nodes in the committed tree carry the same explicit key.
pub const GPUI_STATUS_DUPLICATE_KEY: i32 = -9;
/// `gpui_update_text` found no node carrying the requested explicit key in the
/// committed tree for the view (the view may have no tree, or the key is absent
/// / belongs to a text node). Callers treat this as "fall back to a full
/// `gpui_build_tree` rebuild".
pub const GPUI_STATUS_KEY_NOT_FOUND: i32 = -10;


// Rust -> MoonBit callback. MoonBit native does not emit a stable C export
// symbol for an executable build, so we bind directly to the compiled MoonBit
// function's mangled symbol. Rather than hard-code that (fragile) name, the
// `extern` block below is generated by build.rs from `mb_symbol.txt`, which
// `build.sh` fills by extracting the real `app.dispatch` symbol from MoonBit's
// build output — so renames / toolchain mangling changes are tracked
// automatically. The callback is invoked on the main thread, inside the
// (MoonBit-initiated) GPUI event loop — safe under MoonBit's reference-counted
// runtime.
//
// Versioned event envelope (abi_version 4): the five i32 slots carry
//   (abi_version, event_kind, view, data_a, data_b)
// Slot 0 is always ABI_VERSION so MoonBit can reject a stale Rust binary at
// runtime. Slot 1 selects the event kind. Slot 2 is the view id (index into
// VIEWS, from FfiView.view) and routes the rebuild target. Slots 3–4 are
// kind-dependent:
//   EVENT_CLICK: data_a = click_id, data_b = 0
//   EVENT_KEY:   data_a = codepoint (single-char key), data_b = modifier bits
//   EVENT_TEXT:  data_a = token (index into EVENT_QUEUE), data_b = byte length
// For EVENT_TEXT the UTF-8 payload lives in a Rust-owned queue; MoonBit copies
// it synchronously via `gpui_event_copy_text` before returning from dispatch.
//
// Generates: `unsafe extern "C" { #[link_name = "_M0FP…3app8dispatch"] fn mb_dispatch(version: i32, kind: i32, view: i32, data_a: i32, data_b: i32) -> i32; }`
include!(concat!(env!("OUT_DIR"), "/mb_extern.rs"));

/// Rust-owned event payload queue. Text events store their UTF-8 bytes here;
/// the callback passes a token (index) and byte length so MoonBit can copy
/// the payload via `gpui_event_copy_text`. Entries are valid only during the
/// synchronous dispatch call — MoonBit must copy before returning.
static EVENT_QUEUE: Mutex<Vec<Vec<u8>>> = Mutex::new(Vec::new());

/// Copy the text payload for a pending EVENT_TEXT dispatch.
///
/// `token` is the index passed in `data_a`; `buf` must point to at least `len`
/// writable bytes (the `data_b` value). Returns the number of bytes written,
/// or a negative GPUI_STATUS_* on error. The payload is valid only during the
/// dispatch call that provided the token.
#[unsafe(no_mangle)]
pub extern "C" fn gpui_event_copy_text(token: i32, buf: *mut u8, len: i32) -> i32 {
    if token < 0 || buf.is_null() || len < 0 {
        return GPUI_STATUS_INVALID_HANDLE;
    }
    let guard = EVENT_QUEUE.lock().unwrap_or_else(|e| e.into_inner());
    let Some(payload) = guard.get(token as usize) else {
        return GPUI_STATUS_INVALID_HANDLE;
    };
    let copy_len = (len as usize).min(payload.len());
    unsafe {
        std::ptr::copy_nonoverlapping(payload.as_ptr(), buf, copy_len);
    }
    copy_len as i32
}

/// Collect text node contents in DFS pre-order from a committed tree.
fn collect_text_contents(node: &UiNode, out: &mut Vec<u8>) {
    match node {
        UiNode::Div { children, .. } => {
            for child in children {
                collect_text_contents(child, out);
            }
        }
        UiNode::Text { content, .. } => {
            let bytes = content.as_bytes();
            out.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
            out.extend_from_slice(bytes);
        }
    }
}

/// Debug read-back: dump every text node's content from the committed tree for
/// `view` into `buf` as a sequence of `len u32 LE + utf8[len]` records (DFS
/// pre-order). Returns the total number of bytes written, or a negative
/// GPUI_STATUS_* on error. Used by the headless round-trip test (issue #34)
/// to verify MoonBit→C→Rust text fidelity without a GUI.
#[unsafe(no_mangle)]
pub extern "C" fn gpui_debug_dump_text(view: i32, buf: *mut u8, len: i32) -> i32 {
    if view < 0 || buf.is_null() || len < 0 {
        return GPUI_STATUS_INVALID_HANDLE;
    }
    let guard = VIEWS.lock().unwrap_or_else(|e| e.into_inner());
    let Some(Some(root)) = guard.get(view as usize) else {
        return GPUI_STATUS_INVALID_HANDLE;
    };
    let mut payload = Vec::new();
    collect_text_contents(root, &mut payload);
    let copy_len = (len as usize).min(payload.len());
    unsafe {
        std::ptr::copy_nonoverlapping(payload.as_ptr(), buf, copy_len);
    }
    copy_len as i32
}

/// Cross-boundary ABI probe: echo `value` back unchanged.
///
/// The whole bridge assumes MoonBit's native `Int` is ABI-compatible with
/// Rust's `i32` (callback envelope, command-buffer operands, status codes).
/// MoonBit's `main.mbt` type annotation anchors that at `moon check` time,
/// but nothing verifies the actual register/stack width across the boundary.
/// The headless round-trip test (issue #54, G23) sends boundary values
/// (`i32::MAX`, `i32::MIN`, 0, -1) through this probe on every build; any
/// width or sign-extension mismatch fails the build instead of corrupting
/// silently at runtime.
#[unsafe(no_mangle)]
pub extern "C" fn gpui_abi_probe(value: i32) -> i32 {
    ffi_export("gpui_abi_probe", || value)
}

/// A single box shadow decoded from `OP_SET_SHADOW`. Offsets, blur, and spread
/// are pixel values; color is RGBA (0–255). `render_node` maps it onto a gpui
/// `BoxShadow` (offset/blur_radius/spread_radius + `Hsla` color).
#[derive(Clone, PartialEq, Debug)]
struct Shadow {
    x: f32,
    y: f32,
    blur: f32,
    spread: f32,
    color: (u8, u8, u8, u8),
}

#[derive(Clone)]
enum UiNode {
    Div {
        width: f32,
        height: f32,
        bg: Option<(u8, u8, u8)>,
        flex: bool,
        flex_col: bool,
        center: bool,
        gap: f32,
        rounded: f32,
        padding: f32,
        border_width: f32,
        border_color: Option<(u8, u8, u8)>,
        // --- G7 core layout/style + G9 color (issue #51) -----------------
        /// Background with alpha (G9). Takes precedence over `bg` when both set.
        bg_color: Option<(u8, u8, u8, u8)>,
        /// Per-side margin in px (top, right, bottom, left).
        margin: Option<(f32, f32, f32, f32)>,
        /// Minimum (width, height) in px; a negative component means auto.
        min_size: Option<(f32, f32)>,
        /// Maximum (width, height) in px; a negative component means auto.
        max_size: Option<(f32, f32)>,
        /// Flex item params: (grow, shrink, basis_px); basis < 0 means auto.
        flex_item: Option<(f32, f32, f32)>,
        /// (align_items, justify_content) as ABI enum ids; 0 = default (unset).
        align: Option<(i32, i32)>,
        /// (overflow_x, overflow_y) as ABI enum ids.
        overflow: Option<(i32, i32)>,
        /// Opacity 0.0–1.0.
        opacity: Option<f32>,
        /// Box shadow.
        shadow: Option<Shadow>,
        /// Cursor style as an ABI enum id.
        cursor: Option<i32>,
        /// Position mode as an ABI enum id (0 relative, 1 absolute).
        position: Option<i32>,
        /// Per-side inset in px (top, right, bottom, left); negative = auto.
        inset: Option<(f32, f32, f32, f32)>,
        /// Per-side padding in px (top, right, bottom, left). Takes precedence
        /// over the uniform `padding` when both are set.
        padding_sides: Option<(f32, f32, f32, f32)>,
        // --- G8 typography (issue #51) -----------------------------------
        /// Font size in px for descendant text (inherited via `Style.text`).
        text_size: Option<f32>,
        /// Text color RGBA (0–255) for descendant text.
        text_color: Option<(u8, u8, u8, u8)>,
        /// Font weight 100–900 (clamped at decode time).
        font_weight: Option<i32>,
        /// Line height in px; `None` keeps gpui's default (the golden ratio).
        line_height: Option<f32>,
        /// Text alignment as an ABI enum id; 0 = default (unset).
        text_align: Option<i32>,
        /// Whitespace/wrap handling as an ABI enum id; 0 = default (unset).
        whitespace: Option<i32>,
        /// Font family name for descendant text.
        font_family: Option<String>,
        on_click: Option<i32>,
        // --- Keyboard navigation / a11y (issue #52) ----------------------
        /// Focusable flag (`OP_SET_FOCUSABLE`): nonzero makes the div a
        /// focusable element (gpui `.focusable()`). Requires element identity,
        /// which `render_node` synthesizes when no key/click id is present.
        focusable: Option<bool>,
        /// Tab order index (`OP_SET_TAB_INDEX`): sets gpui `.tab_index()`,
        /// which also marks the element focusable and a tab stop.
        tab_index: Option<isize>,
        /// Tab stop flag (`OP_SET_TAB_STOP`): nonzero keeps the element
        /// reachable via Tab, zero removes it from keyboard navigation while
        /// leaving it in tab-index order (gpui `.tab_stop()`).
        tab_stop: Option<bool>,
        /// Explicit stable identity, independent of click routing. When set,
        /// `render_node` uses it as the GPUI `ElementId`; duplicate keys within
        /// a committed tree are rejected at `commit_tree`.
        key: Option<String>,
        children: Vec<UiNode>,
    },
    Text {
        content: String,
        color: (u8, u8, u8),
        size: f32,
    },
}


fn report_panic(context: &str, payload: &(dyn Any + Send)) {
    let message = payload
        .downcast_ref::<&str>()
        .copied()
        .or_else(|| payload.downcast_ref::<String>().map(String::as_str))
        .unwrap_or("non-string panic payload");
    eprintln!("gpui-sys: panic in {context}: {message}");
}

fn ffi_export<F>(name: &str, f: F) -> i32
where
    F: FnOnce() -> i32,
{
    match catch_unwind(AssertUnwindSafe(f)) {
        Ok(status) => status,
        Err(payload) => {
            report_panic(name, payload.as_ref());
            GPUI_STATUS_INTERNAL_PANIC
        }
    }
}

fn div_mut(nodes: &mut [Option<UiNode>], handle: i32) -> Result<&mut UiNode, i32> {
    if handle < 0 {
        return Err(GPUI_STATUS_INVALID_HANDLE);
    }
    match nodes.get_mut(handle as usize) {
        None => Err(GPUI_STATUS_INVALID_HANDLE),
        Some(None) => Err(GPUI_STATUS_NODE_ABSENT),
        Some(Some(node @ UiNode::Div { .. })) => Ok(node),
        Some(Some(UiNode::Text { .. })) => Err(GPUI_STATUS_WRONG_NODE_KIND),
    }
}

fn push_node(nodes: &mut Vec<Option<UiNode>>, node: UiNode) -> i32 {
    let Ok(id) = i32::try_from(nodes.len()) else {
        return GPUI_STATUS_INVALID_HANDLE;
    };
    nodes.push(Some(node));
    id
}

// --- Command buffer (issue #5) ---------------------------------------------
//
// MoonBit builds the whole tree as one length-delimited command buffer and
// submits it with a single `gpui_build_tree` call, replacing the former
// property-per-call FFI surface. The buffer is a flat opcode stream: a fixed
// header, then a sequence of `[opcode u8][operands]` records. Node creation
// pushes a handle onto an internal stack; setters apply to the top of the
// stack; `OP_ADD_CHILD` pops child then parent and re-pushes the parent;
// `OP_SET_ROOT` pops the root. All multi-byte integers are little-endian.
//
// Wire layout (little-endian):
//   header:  "GPUI" (4 bytes) | BUFFER_VERSION (u32)
//   OP_DIV            u8
//   OP_TEXT           u8 | len u32 | utf8[len] | r u8 | g u8 | b u8 | size f32
//   OP_SET_SIZE       u8 | w f32 | h f32
//   OP_SET_BG         u8 | r u8 | g u8 | b u8
//   OP_SET_FLEX       u8 | col u8
//   OP_SET_CENTER     u8
//   OP_SET_GAP        u8 | gap f32
//   OP_SET_ROUNDED    u8 | radius f32
//   OP_SET_ON_CLICK   u8 | click_id i32
//   OP_SET_KEY        u8 | len u32 | utf8[len]
//   OP_SET_PADDING    u8 | padding f32
//   OP_SET_BORDER     u8 | width f32 | r u8 | g u8 | b u8
//   OP_SET_BG_COLOR   u8 | r u8 | g u8 | b u8 | a u8          (G9: alpha)
//   OP_SET_MARGIN     u8 | top i32 | right i32 | bottom i32 | left i32   (px)
//   OP_SET_MIN_SIZE   u8 | w i32 | h i32                    (px; -1 = auto)
//   OP_SET_MAX_SIZE   u8 | w i32 | h i32                    (px; -1 = auto)
//   OP_SET_FLEX_ITEM  u8 | grow i32 | shrink i32 | basis i32 (grow/shrink ×1000; basis px, -1 = auto)
//   OP_SET_ALIGN      u8 | align_items i32 | justify_content i32  (ALIGN_*/JUSTIFY_* ids)
//   OP_SET_OVERFLOW   u8 | x i32 | y i32                    (OVERFLOW_* ids)
//   OP_SET_OPACITY    u8 | x1000 i32                        (0–1000 → 0.0–1.0)
//   OP_SET_SHADOW     u8 | x i32 | y i32 | blur i32 | spread i32 | r u8 | g u8 | b u8 | a u8  (px + RGBA)
//   OP_SET_CURSOR     u8 | kind i32                         (CURSOR_* ids)
//   OP_SET_POSITION   u8 | mode i32                         (POSITION_* ids)
//   OP_SET_INSET      u8 | top i32 | right i32 | bottom i32 | left i32   (px; -1 = auto)
//   OP_SET_PADDING_SIDES u8 | top i32 | right i32 | bottom i32 | left i32   (px; overrides uniform padding)
//   OP_SET_TEXT_SIZE  u8 | size i32                         (px; G8 typography)
//   OP_SET_TEXT_COLOR u8 | r u8 | g u8 | b u8 | a u8        (G8: RGBA text color)
//   OP_SET_FONT_WEIGHT u8 | weight i32                      (100–900; clamped)
//   OP_SET_LINE_HEIGHT u8 | px_x1000 i32                    (px×1000; negative = unset)
//   OP_SET_TEXT_ALIGN u8 | id i32                           (TEXT_ALIGN_* ids)
//   OP_SET_WHITESPACE u8 | id i32                           (WHITESPACE_* ids)
//   OP_SET_FONT_FAMILY u8 | len u32 | utf8[len]             (font family name)
//   OP_SET_FOCUSABLE  u8 | mode i32                         (0 = not focusable, nonzero = focusable)
//   OP_SET_TAB_INDEX  u8 | index i32                        (tab order; also marks focusable + tab stop)
//   OP_SET_TAB_STOP   u8 | mode i32                         (0 = skip in Tab nav, nonzero = tab stop)
//   OP_ADD_CHILD      u8            (pops child, then parent; re-pushes parent)
//   OP_SET_ROOT       u8            (pops the root)
//
// Opcodes and BUFFER_VERSION are generated from abi.toml on both sides, so a
// drift fails the cross-boundary constant check rather than corrupting at
// runtime. New opcodes are backward-compatible additions (issue #42): an old
// Rust binary rejects them with `UNKNOWN_OPCODE` rather than misdecoding, so
// `BUFFER_VERSION` is bumped only when an existing opcode's meaning changes.

const BUFFER_MAGIC: &[u8; 4] = b"GPUI";

/// A cursor over the command buffer with little-endian readers. Every reader
/// returns `None` on truncation so the parser reports `TRUNCATED_BUFFER`
/// instead of panicking.
struct BufferReader<'a> {
    data: &'a [u8],
    pos: usize,
}

impl<'a> BufferReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self { data, pos: 0 }
    }

    fn read_u8(&mut self) -> Option<u8> {
        let byte = *self.data.get(self.pos)?;
        self.pos += 1;
        Some(byte)
    }

    fn read_u32(&mut self) -> Option<u32> {
        let bytes = self.data.get(self.pos..self.pos + 4)?;
        self.pos += 4;
        Some(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    fn read_i32(&mut self) -> Option<i32> {
        self.read_u32().map(|v| v as i32)
    }

    fn read_f32(&mut self) -> Option<f32> {
        self.read_u32().map(f32::from_bits)
    }

    /// Borrow `len` bytes without copying; advances the cursor.
    fn read_bytes(&mut self, len: usize) -> Option<&'a [u8]> {
        let slice = self.data.get(self.pos..self.pos + len)?;
        self.pos += len;
        Some(slice)
    }

    fn read_string(&mut self) -> Option<String> {
        let len = self.read_u32()? as usize;
        let bytes = self.read_bytes(len)?;
        Some(String::from_utf8_lossy(bytes).into_owned())
    }
}

/// Apply `f` to the div on top of the stack. Fails with `INVALID_HANDLE` if the
/// stack is empty, `NODE_ABSENT` if the top was already moved, `WRONG_NODE_KIND`
/// if the top is a text node.
fn with_top_div<F>(stack: &[i32], nodes: &mut [Option<UiNode>], f: F) -> i32
where
    F: FnOnce(&mut UiNode) -> i32,
{
    let Some(&handle) = stack.last() else {
        return GPUI_STATUS_INVALID_HANDLE;
    };
    match div_mut(nodes, handle) {
        Ok(node) => f(node),
        Err(status) => status,
    }
}

/// Build and commit a tree for `view` from one command buffer. On any failure
/// the staging state is discarded and the previously committed tree is left
/// untouched.
#[unsafe(no_mangle)]
pub extern "C" fn gpui_build_tree(view: i32, ptr: *const u8, len: i32) -> i32 {
    ffi_export("gpui_build_tree", || {
        if view < 0 {
            return GPUI_STATUS_INVALID_HANDLE;
        }
        if ptr.is_null() || len < 0 {
            return GPUI_STATUS_TRUNCATED_BUFFER;
        }
        let data = unsafe { std::slice::from_raw_parts(ptr, len as usize) };
        build_tree_from_buffer(view as usize, data)
    })
}

fn build_tree_from_buffer(view: usize, data: &[u8]) -> i32 {
    let mut reader = BufferReader::new(data);

    // Header: magic + version.
    match reader.read_bytes(BUFFER_MAGIC.len()) {
        Some(m) if m == BUFFER_MAGIC => {}
        _ => return GPUI_STATUS_BAD_BUFFER_VERSION,
    }
    match reader.read_u32() {
        Some(v) if v == BUFFER_VERSION as u32 => {}
        _ => return GPUI_STATUS_BAD_BUFFER_VERSION,
    }

    let mut nodes: Vec<Option<UiNode>> = Vec::new();
    let mut stack: Vec<i32> = Vec::new();
    let mut root: Option<usize> = None;

    loop {
        let Some(opcode) = reader.read_u8() else {
            break; // clean end of buffer
        };
        let status = match opcode as i32 {
            OP_DIV => {
                let id = push_node(
                    &mut nodes,
                    UiNode::Div {
                        width: 0.0,
                        height: 0.0,
                        bg: None,
                        flex: false,
                        flex_col: false,
                        center: false,
                        gap: 0.0,
                        rounded: 0.0,
                        padding: 0.0,
                        border_width: 0.0,
                        border_color: None,
                        bg_color: None,
                        margin: None,
                        min_size: None,
                        max_size: None,
                        flex_item: None,
                        align: None,
                        overflow: None,
                        opacity: None,
                        shadow: None,
                        cursor: None,
                        position: None,
                        inset: None,
                        padding_sides: None,
                        text_size: None,
                        text_color: None,
                        font_weight: None,
                        line_height: None,
                        text_align: None,
                        whitespace: None,
                        font_family: None,
                        on_click: None,
                        focusable: None,
                        tab_index: None,
                        tab_stop: None,
                        key: None,
                        children: Vec::new(),
                    },
                );
                if id < 0 {
                    id
                } else {
                    stack.push(id);
                    GPUI_STATUS_OK
                }
            }
            OP_TEXT => {
                let (Some(content), Some(r), Some(g), Some(b), Some(size)) = (
                    reader.read_string(),
                    reader.read_u8(),
                    reader.read_u8(),
                    reader.read_u8(),
                    reader.read_f32(),
                ) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                let id = push_node(
                    &mut nodes,
                    UiNode::Text {
                        content,
                        color: (r, g, b),
                        size,
                    },
                );
                if id < 0 {
                    id
                } else {
                    stack.push(id);
                    GPUI_STATUS_OK
                }
            }
            OP_SET_SIZE => {
                let (Some(w), Some(h)) = (reader.read_f32(), reader.read_f32()) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { width, height, .. } => {
                        *width = w;
                        *height = h;
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_BG => {
                let (Some(r), Some(g), Some(b)) =
                    (reader.read_u8(), reader.read_u8(), reader.read_u8())
                else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { bg, .. } => {
                        *bg = Some((r, g, b));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_FLEX => {
                let Some(col) = reader.read_u8() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { flex, flex_col, .. } => {
                        *flex = true;
                        *flex_col = col != 0;
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_CENTER => with_top_div(&stack, &mut nodes, |node| match node {
                UiNode::Div { center, .. } => {
                    *center = true;
                    GPUI_STATUS_OK
                }
                _ => unreachable!("with_top_div guarantees a div"),
            }),
            OP_SET_GAP => {
                let Some(gap) = reader.read_f32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { gap: value, .. } => {
                        *value = gap;
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_ROUNDED => {
                let Some(radius) = reader.read_f32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { rounded, .. } => {
                        *rounded = radius;
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_ON_CLICK => {
                let Some(click_id) = reader.read_i32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { on_click, .. } => {
                        *on_click = Some(click_id);
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_KEY => {
                let Some(key) = reader.read_string() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { key: slot, .. } => {
                        *slot = Some(key);
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_PADDING => {
                let Some(padding) = reader.read_f32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { padding: value, .. } => {
                        *value = padding;
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_BORDER => {
                let (Some(width), Some(r), Some(g), Some(b)) = (
                    reader.read_f32(),
                    reader.read_u8(),
                    reader.read_u8(),
                    reader.read_u8(),
                ) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div {
                        border_width,
                        border_color,
                        ..
                    } => {
                        *border_width = width;
                        *border_color = Some((r, g, b));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_BG_COLOR => {
                let (Some(r), Some(g), Some(b), Some(a)) = (
                    reader.read_u8(),
                    reader.read_u8(),
                    reader.read_u8(),
                    reader.read_u8(),
                ) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { bg_color, .. } => {
                        *bg_color = Some((r, g, b, a));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_MARGIN => {
                let (Some(top), Some(right), Some(bottom), Some(left)) = (
                    reader.read_i32(),
                    reader.read_i32(),
                    reader.read_i32(),
                    reader.read_i32(),
                ) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { margin, .. } => {
                        *margin = Some((top as f32, right as f32, bottom as f32, left as f32));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_MIN_SIZE => {
                let (Some(w), Some(h)) = (reader.read_i32(), reader.read_i32()) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { min_size, .. } => {
                        *min_size = Some((w as f32, h as f32));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_MAX_SIZE => {
                let (Some(w), Some(h)) = (reader.read_i32(), reader.read_i32()) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { max_size, .. } => {
                        *max_size = Some((w as f32, h as f32));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_FLEX_ITEM => {
                let (Some(grow), Some(shrink), Some(basis)) = (
                    reader.read_i32(),
                    reader.read_i32(),
                    reader.read_i32(),
                ) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { flex_item, .. } => {
                        *flex_item = Some((
                            grow as f32 / 1000.0,
                            shrink as f32 / 1000.0,
                            basis as f32,
                        ));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_ALIGN => {
                let (Some(align_items), Some(justify_content)) =
                    (reader.read_i32(), reader.read_i32())
                else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { align, .. } => {
                        *align = Some((align_items, justify_content));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_OVERFLOW => {
                let (Some(x), Some(y)) = (reader.read_i32(), reader.read_i32()) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { overflow, .. } => {
                        *overflow = Some((x, y));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_OPACITY => {
                let Some(x1000) = reader.read_i32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { opacity, .. } => {
                        *opacity = Some(x1000 as f32 / 1000.0);
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_SHADOW => {
                let (
                    Some(x),
                    Some(y),
                    Some(blur),
                    Some(spread),
                    Some(r),
                    Some(g),
                    Some(b),
                    Some(a),
                ) = (
                    reader.read_i32(),
                    reader.read_i32(),
                    reader.read_i32(),
                    reader.read_i32(),
                    reader.read_u8(),
                    reader.read_u8(),
                    reader.read_u8(),
                    reader.read_u8(),
                ) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { shadow, .. } => {
                        *shadow = Some(Shadow {
                            x: x as f32,
                            y: y as f32,
                            blur: blur as f32,
                            spread: spread as f32,
                            color: (r, g, b, a),
                        });
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_CURSOR => {
                let Some(kind) = reader.read_i32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { cursor, .. } => {
                        *cursor = Some(kind);
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_POSITION => {
                let Some(mode) = reader.read_i32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { position, .. } => {
                        *position = Some(mode);
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_INSET => {
                let (Some(top), Some(right), Some(bottom), Some(left)) = (
                    reader.read_i32(),
                    reader.read_i32(),
                    reader.read_i32(),
                    reader.read_i32(),
                ) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { inset, .. } => {
                        *inset = Some((top as f32, right as f32, bottom as f32, left as f32));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_PADDING_SIDES => {
                let (Some(top), Some(right), Some(bottom), Some(left)) = (
                    reader.read_i32(),
                    reader.read_i32(),
                    reader.read_i32(),
                    reader.read_i32(),
                ) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { padding_sides, .. } => {
                        *padding_sides =
                            Some((top as f32, right as f32, bottom as f32, left as f32));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_TEXT_SIZE => {
                let Some(size) = reader.read_i32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { text_size, .. } => {
                        *text_size = Some(size as f32);
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_TEXT_COLOR => {
                let (Some(r), Some(g), Some(b), Some(a)) = (
                    reader.read_u8(),
                    reader.read_u8(),
                    reader.read_u8(),
                    reader.read_u8(),
                ) else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { text_color, .. } => {
                        *text_color = Some((r, g, b, a));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_FONT_WEIGHT => {
                let Some(weight) = reader.read_i32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { font_weight, .. } => {
                        // gpui's FontWeight is a free f32, but the CSS-style
                        // 100–900 range is the documented contract; clamp
                        // out-of-range operands rather than reject them.
                        *font_weight = Some(weight.clamp(100, 900));
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_LINE_HEIGHT => {
                let Some(px_x1000) = reader.read_i32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { line_height, .. } => {
                        // Negative = unset (restores gpui's default line
                        // height); the px×1000 fixed-point matches the
                        // opacity/flex milliunit convention.
                        *line_height = if px_x1000 < 0 {
                            None
                        } else {
                            Some(px_x1000 as f32 / 1000.0)
                        };
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_TEXT_ALIGN => {
                let Some(id) = reader.read_i32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { text_align, .. } => {
                        *text_align = Some(id);
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_WHITESPACE => {
                let Some(id) = reader.read_i32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { whitespace, .. } => {
                        *whitespace = Some(id);
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_FONT_FAMILY => {
                let Some(family) = reader.read_string() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { font_family, .. } => {
                        *font_family = Some(family);
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            // --- Keyboard navigation / a11y (issue #52) -----------------
            OP_SET_FOCUSABLE => {
                let Some(mode) = reader.read_i32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { focusable, .. } => {
                        *focusable = Some(mode != 0);
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_TAB_INDEX => {
                let Some(index) = reader.read_i32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { tab_index, .. } => {
                        *tab_index = Some(index as isize);
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_SET_TAB_STOP => {
                let Some(mode) = reader.read_i32() else {
                    return GPUI_STATUS_TRUNCATED_BUFFER;
                };
                with_top_div(&stack, &mut nodes, |node| match node {
                    UiNode::Div { tab_stop, .. } => {
                        *tab_stop = Some(mode != 0);
                        GPUI_STATUS_OK
                    }
                    _ => unreachable!("with_top_div guarantees a div"),
                })
            }
            OP_ADD_CHILD => {
                let (Some(child), Some(parent)) = (stack.pop(), stack.pop()) else {
                    return GPUI_STATUS_INVALID_HANDLE;
                };
                if parent < 0 || child < 0 || parent == child {
                    return GPUI_STATUS_INVALID_HANDLE;
                }
                let parent_index = parent as usize;
                let child_index = child as usize;
                if parent_index >= nodes.len() || child_index >= nodes.len() {
                    return GPUI_STATUS_INVALID_HANDLE;
                }
                match &nodes[parent_index] {
                    None => return GPUI_STATUS_NODE_ABSENT,
                    Some(UiNode::Text { .. }) => return GPUI_STATUS_WRONG_NODE_KIND,
                    Some(UiNode::Div { .. }) => {}
                }
                if nodes[child_index].is_none() {
                    return GPUI_STATUS_NODE_ABSENT;
                }
                let child_node = nodes[child_index]
                    .take()
                    .expect("child presence was validated");
                let Some(UiNode::Div { children, .. }) = nodes[parent_index].as_mut() else {
                    unreachable!("parent kind was validated");
                };
                children.push(child_node);
                stack.push(parent);
                GPUI_STATUS_OK
            }
            OP_SET_ROOT => {
                let Some(handle) = stack.pop() else {
                    return GPUI_STATUS_INVALID_HANDLE;
                };
                if handle < 0 {
                    return GPUI_STATUS_INVALID_HANDLE;
                }
                match nodes.get(handle as usize) {
                    None => GPUI_STATUS_INVALID_HANDLE,
                    Some(None) => GPUI_STATUS_NODE_ABSENT,
                    Some(Some(_)) => {
                        root = Some(handle as usize);
                        GPUI_STATUS_OK
                    }
                }
            }
            _ => return GPUI_STATUS_UNKNOWN_OPCODE,
        };
        if status != GPUI_STATUS_OK {
            return status;
        }
    }

    // Commit: validate root + duplicate keys, then swap into VIEWS.
    let Some(root_index) = root else {
        return GPUI_STATUS_NO_ROOT;
    };
    if nodes[root_index].is_none() {
        return GPUI_STATUS_NODE_ABSENT;
    }
    {
        let mut seen = std::collections::HashSet::new();
        let root_ref = nodes[root_index].as_ref().expect("root present");
        let mut walk: Vec<&UiNode> = vec![root_ref];
        while let Some(node) = walk.pop() {
            let UiNode::Div { key, children, .. } = node else {
                continue;
            };
            if let Some(key) = key {
                if !seen.insert(key.as_str()) {
                    return GPUI_STATUS_DUPLICATE_KEY;
                }
            }
            walk.extend(children.iter());
        }
    }
    let root_node = nodes[root_index].take().expect("root presence was validated");
    let mut views = VIEWS.lock().unwrap_or_else(|e| e.into_inner());
    if view >= views.len() {
        views.resize(view + 1, None);
    }
    views[view] = Some(root_node);
    GPUI_STATUS_OK
}

/// Recursively locate the div carrying `key` and overwrite the `content` of its
/// first `UiNode::Text` child in place. Returns `true` on a successful update.
///
/// A keyed div whose first child is a text node is the canonical "labelled
/// value" shape (the Counter's count card: a keyed div wrapping one text node).
/// Only that first text child is touched — sibling text nodes and the rest of
/// the subtree are left untouched, so an incremental update is a single string
/// assignment rather than a rebuild. A keyed div with no text child, or a key
/// that resolves to a text node, yields no update (the caller falls back to a
/// full rebuild).
fn update_keyed_text(node: &mut UiNode, key: &str, text: &str) -> bool {
    let UiNode::Div {
        key: node_key,
        children,
        ..
    } = node
    else {
        return false;
    };
    if node_key.as_deref() == Some(key) {
        if let Some(UiNode::Text { content, .. }) = children.first_mut() {
            *content = text.to_string();
            return true;
        }
        return false;
    }
    children
        .iter_mut()
        .any(|child| update_keyed_text(child, key, text))
}

/// Update the text of a keyed node in the committed tree for `view` in place,
/// without rebuilding the tree (issue #10: measurement-justified incremental
/// update).
///
/// `key_ptr`/`key_len` and `text_ptr`/`text_len` are UTF-8 byte slices (no NUL
/// terminator; the explicit lengths carry the size, matching how `OP_SET_KEY`
/// and `OP_TEXT` carry their strings). The function walks the retained
/// `VIEWS[view]` tree for the div whose `OP_SET_KEY` value equals `key` and
/// overwrites its first text child's content. The re-render still flows through
/// the existing dispatch→notify path: `dispatch` returns 1, Rust calls
/// `cx.notify()`, and `render_node` reads the now-updated `VIEWS[view]`.
///
/// Returns `GPUI_STATUS_OK` on success. Returns `GPUI_STATUS_KEY_NOT_FOUND` when
/// the view has no committed tree or no keyed text node matches — the caller
/// (MoonBit) then falls back to a full `gpui_build_tree`. `GPUI_STATUS_INVALID_HANDLE`
/// for a negative view, `GPUI_STATUS_TRUNCATED_BUFFER` for a null/negative
/// pointer or length.
#[unsafe(no_mangle)]
pub extern "C" fn gpui_update_text(
    view: i32,
    key_ptr: *const u8,
    key_len: i32,
    text_ptr: *const u8,
    text_len: i32,
) -> i32 {
    ffi_export("gpui_update_text", || {
        if view < 0 {
            return GPUI_STATUS_INVALID_HANDLE;
        }
        if key_ptr.is_null() || key_len < 0 || text_ptr.is_null() || text_len < 0 {
            return GPUI_STATUS_TRUNCATED_BUFFER;
        }
        let key_bytes = unsafe { std::slice::from_raw_parts(key_ptr, key_len as usize) };
        let text_bytes = unsafe { std::slice::from_raw_parts(text_ptr, text_len as usize) };
        let (Ok(key), Ok(text)) = (std::str::from_utf8(key_bytes), std::str::from_utf8(text_bytes))
        else {
            return GPUI_STATUS_TRUNCATED_BUFFER;
        };
        let mut views = VIEWS.lock().unwrap_or_else(|e| e.into_inner());
        let Some(Some(root)) = views.get_mut(view as usize) else {
            return GPUI_STATUS_KEY_NOT_FOUND;
        };
        if update_keyed_text(root, key, text) {
            GPUI_STATUS_OK
        } else {
            GPUI_STATUS_KEY_NOT_FOUND
        }
    })
}

/// Open a window rendering the committed tree for `view` (index into
/// `VIEWS`) and block in the GPUI event loop. A negative `view` fails with
/// `GPUI_STATUS_INVALID_HANDLE` before any GPUI startup.
#[unsafe(no_mangle)]
pub extern "C" fn gpui_run_window(view: i32, width: f32, height: f32) -> i32 {
    ffi_export("gpui_run_window", || {
        if view < 0 {
            return GPUI_STATUS_INVALID_HANDLE;
        }
        run_window_with_fallback(view as usize, width, height)
    })
}

fn run_window(view: usize, width: f32, height: f32) {
    Application::new().run(move |cx: &mut App| {
        let bounds = Bounds::centered(None, size(px(width), px(height)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..Default::default()
            },
            |window, cx| {
                cx.new(|cx| {
                    // Focus the view at construction (with `window` available), the
                    // same way GPUI's own examples do — focusing during `render`
                    // does not reliably make the element the OS first responder,
                    // so key events never arrive.
                    let focus = cx.focus_handle();
                    window.focus(&focus);
                    FfiView {
                        focus,
                        view,
                        scroll_handles: Rc::new(RefCell::new(HashMap::new())),
                    }
                })
            },
        )
        .unwrap();
        cx.activate(true);
    });
}

fn run_window_with_fallback(view: usize, width: f32, height: f32) -> i32 {
    match catch_unwind(AssertUnwindSafe(|| run_window(view, width, height))) {
        Ok(()) => GPUI_STATUS_OK,
        Err(first_panic) => {
            #[cfg(target_os = "linux")]
            if std::env::var_os("WAYLAND_DISPLAY").is_some() {
                report_panic("gpui_run_window (Wayland attempt)", first_panic.as_ref());
                eprintln!(
                    "gpui-sys: Wayland startup failed; unsetting WAYLAND_DISPLAY and retrying with X11"
                );
                // SAFETY: window startup is single-threaded and happens before GPUI
                // creates worker threads that could concurrently read the environment.
                unsafe { std::env::remove_var("WAYLAND_DISPLAY") };
                return match catch_unwind(AssertUnwindSafe(|| run_window(view, width, height))) {
                    Ok(()) => GPUI_STATUS_OK,
                    Err(second_panic) => {
                        report_panic("gpui_run_window (X11 retry)", second_panic.as_ref());
                        GPUI_STATUS_INTERNAL_PANIC
                    }
                };
            }

            report_panic("gpui_run_window", first_panic.as_ref());
            GPUI_STATUS_INTERNAL_PANIC
        }
    }
}

struct FfiView {
    focus: FocusHandle,
    /// Index into `VIEWS` whose committed tree this view renders.
    view: usize,
    /// Retained scroll handles, keyed by the div's `OP_SET_KEY` value. The tree
    /// is rebuilt from scratch on every state change, so a scroll div's
    /// position only survives the rebuild if its `ScrollHandle` lives outside
    /// the tree. `ScrollHandle` is `Rc`-based (not `Send`), so the store lives
    /// here in the per-view entity — which only ever runs on the main thread —
    /// rather than in the `Mutex`-guarded `VIEWS` global. `render_node` looks
    /// up (or inserts) the handle for keyed scroll divs; keyless scroll divs
    /// get a fresh handle per render and reset to the top on each rebuild.
    scroll_handles: Rc<RefCell<HashMap<String, ScrollHandle>>>,
}

impl Render for FfiView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        // Render the committed root for this view (swapped in by `commit_tree`).
        // Cloned out so the lock is not held while building GPUI elements.
        let root = {
            let guard = VIEWS.lock().unwrap_or_else(|e| e.into_inner());
            guard.get(self.view).cloned().flatten()
        };
        let mut d = div()
            .size_full()
            .flex()
            .flex_col()
            .track_focus(&self.focus)
            .on_key_down(cx.listener(|this, ev: &KeyDownEvent, win, cx| {
                let view = this.view as i32;
                // Keyboard navigation (issue #52): Tab moves focus to the next
                // tab stop, Shift+Tab to the previous one. The framework owns
                // this traversal, so Tab is consumed here and NOT forwarded to
                // MoonBit as a named key; every other key falls through to the
                // normal key/text dispatch below. `focus_next`/`focus_prev`
                // walk the tab stops the focusable divs registered at paint
                // time (see `render_node`); with no tab stops they are no-ops.
                if ev.keystroke.key == "tab" {
                    if ev.keystroke.modifiers.shift {
                        win.focus_prev();
                    } else {
                        win.focus_next();
                    }
                    return;
                }
                let code = key_code(ev);
                let mods = mods_bits(&ev.keystroke.modifiers);
                if code != 0 {
                    let changed =
                        unsafe { mb_dispatch(ABI_VERSION, EVENT_KEY, view, code, mods) };
                    notify_if_changed(changed, || cx.notify());
                } else if let Some(key_id) = named_key_id(&ev.keystroke.key) {
                    let changed =
                        unsafe { mb_dispatch(ABI_VERSION, EVENT_NAMED_KEY, view, key_id, mods) };
                    notify_if_changed(changed, || cx.notify());
                }
                // Emit a text event for keys that produce typed characters
                // (including multi-char keys and IME-composed text). The
                // payload lives in EVENT_QUEUE; MoonBit copies it via
                // gpui_event_copy_text during the synchronous dispatch.
                if let Some(text) = typed_text(ev) {
                    let bytes = text.as_bytes();
                    let token = {
                        let mut q = EVENT_QUEUE.lock().unwrap_or_else(|e| e.into_inner());
                        q.push(bytes.to_vec());
                        (q.len() - 1) as i32
                    };
                    let changed = unsafe {
                        mb_dispatch(ABI_VERSION, EVENT_TEXT, view, token, bytes.len() as i32)
                    };
                    notify_if_changed(changed, || cx.notify());
                }
            }));
        if let Some(node) = &root {
            if let Some(el) =
                render_node(node, cx, true, &self.scroll_handles, &Cell::new(0), &Cell::new(0))
            {
                d = d.child(el);
            }
        }
        d
    }
}

/// Codepoint of a single-character key (letters/digits/…); 0 for named or
/// multi-char keys (up/down/enter/…), which `named_key_id` maps to an ABI id.
/// Rust only translates the platform key to a scalar; MoonBit decides what it does.
fn key_code(ev: &KeyDownEvent) -> i32 {
    let mut chars = ev.keystroke.key.chars();
    match (chars.next(), chars.next()) {
        (Some(c), None) => c as i32,
        _ => 0,
    }
}

/// Map a GPUI named key string to its ABI id. Returns `None` for single-char
/// keys (handled by `key_code`) and unrecognized names.
fn named_key_id(key: &str) -> Option<i32> {
    match key {
        "enter" => Some(KEY_ENTER),
        "escape" => Some(KEY_ESCAPE),
        "up" => Some(KEY_UP),
        "down" => Some(KEY_DOWN),
        "left" => Some(KEY_LEFT),
        "right" => Some(KEY_RIGHT),
        "tab" => Some(KEY_TAB),
        "backspace" => Some(KEY_BACKSPACE),
        "delete" => Some(KEY_DELETE),
        "home" => Some(KEY_HOME),
        "end" => Some(KEY_END),
        "pageup" => Some(KEY_PAGEUP),
        "pagedown" => Some(KEY_PAGEDOWN),
        _ => None,
    }
}

/// Typed text for a key event: `key_char` if present (the character that would
/// be inserted, including IME-composed and multi-char keys), else the single
/// `key` character. Returns `None` for pure modifier/navigation keys.
fn typed_text(ev: &KeyDownEvent) -> Option<String> {
    if let Some(s) = &ev.keystroke.key_char {
        if !s.is_empty() {
            return Some(s.clone());
        }
    }
    let k = &ev.keystroke.key;
    if k.chars().count() == 1 && !k.chars().next().unwrap().is_control() {
        Some(k.clone())
    } else {
        None
    }
}

/// Pack modifier flags into the `b` payload slot (bit0 ctrl, 1 alt, 2 shift,
/// 3 platform/cmd, 4 fn). Unused by the demo but kept for completeness.
fn mods_bits(m: &Modifiers) -> i32 {
    (m.control as i32) * MOD_CTRL
        | (m.alt as i32) * MOD_ALT
        | (m.shift as i32) * MOD_SHIFT
        | (m.platform as i32) * MOD_PLATFORM
        | (m.function as i32) * MOD_FUNCTION
}

fn notify_if_changed(changed: i32, notify: impl FnOnce()) {
    if changed == 1 {
        notify();
    }
}

/// A non-negative pixel value as a definite `Length`; a negative sentinel maps to
/// `Length::Auto` (the "unset/auto" encoding used by inset operands).
fn px_or_auto(v: f32) -> Length {
    if v >= 0.0 {
        px(v).into()
    } else {
        Length::Auto
    }
}

/// Map an ABI `ALIGN_*` id to a gpui `AlignItems`. `ALIGN_DEFAULT` (0) and any
fn map_align_items(id: i32) -> Option<AlignItems> {
    match id {
        ALIGN_DEFAULT => None,
        ALIGN_START => Some(AlignItems::Start),
        ALIGN_CENTER => Some(AlignItems::Center),
        ALIGN_END => Some(AlignItems::End),
        ALIGN_STRETCH => Some(AlignItems::Stretch),
        _ => None,
    }
}

/// Map an ABI `JUSTIFY_*` id to a gpui `JustifyContent` (an `AlignContent`).
/// `JUSTIFY_DEFAULT` (0) and any unknown id map to `None`.
fn map_justify_content(id: i32) -> Option<JustifyContent> {
    match id {
        JUSTIFY_DEFAULT => None,
        JUSTIFY_START => Some(JustifyContent::Start),
        JUSTIFY_CENTER => Some(JustifyContent::Center),
        JUSTIFY_END => Some(JustifyContent::End),
        JUSTIFY_SPACE_BETWEEN => Some(JustifyContent::SpaceBetween),
        JUSTIFY_SPACE_AROUND => Some(JustifyContent::SpaceAround),
        _ => None,
    }
}

/// Map an ABI `OVERFLOW_*` id to a gpui `Overflow`. Unknown ids map to `None`.
/// `Scroll` becomes real scrolling in `render_node`: any div whose overflow is
/// `Scroll` on either axis is tracked with a retained `ScrollHandle` (keyed by
/// the node's `OP_SET_KEY` value when present), so scroll position survives the
/// full tree rebuild that every state change triggers.
fn map_overflow(id: i32) -> Option<Overflow> {
    match id {
        OVERFLOW_VISIBLE => Some(Overflow::Visible),
        OVERFLOW_HIDDEN => Some(Overflow::Hidden),
        OVERFLOW_SCROLL => Some(Overflow::Scroll),
        _ => None,
    }
}

/// Map an ABI `CURSOR_*` id to a gpui `CursorStyle`. Unknown ids map to `None`.
fn map_cursor(id: i32) -> Option<CursorStyle> {
    match id {
        CURSOR_ARROW => Some(CursorStyle::Arrow),
        CURSOR_POINTER => Some(CursorStyle::PointingHand),
        CURSOR_TEXT => Some(CursorStyle::IBeam),
        CURSOR_CROSSHAIR => Some(CursorStyle::Crosshair),
        CURSOR_GRAB => Some(CursorStyle::OpenHand),
        CURSOR_GRABBING => Some(CursorStyle::ClosedHand),
        CURSOR_NOT_ALLOWED => Some(CursorStyle::OperationNotAllowed),
        CURSOR_EW_RESIZE => Some(CursorStyle::ResizeLeftRight),
        CURSOR_NS_RESIZE => Some(CursorStyle::ResizeUpDown),
        CURSOR_COL_RESIZE => Some(CursorStyle::ResizeColumn),
        CURSOR_ROW_RESIZE => Some(CursorStyle::ResizeRow),
        CURSOR_NONE => Some(CursorStyle::None),
        _ => None,
    }
}

/// Map an ABI `TEXT_ALIGN_*` id to a gpui `TextAlign`. `TEXT_ALIGN_DEFAULT` (0)
/// and unknown ids map to `None`. `TEXT_ALIGN_JUSTIFY` maps to `Left`: gpui
/// 0.2.2's `TextAlign` has no `Justify` variant, so the closest supported
/// alignment is used (see `docs/framework-gaps.md` G8).
fn map_text_align(id: i32) -> Option<TextAlign> {
    match id {
        TEXT_ALIGN_DEFAULT => None,
        TEXT_ALIGN_LEFT => Some(TextAlign::Left),
        TEXT_ALIGN_CENTER => Some(TextAlign::Center),
        TEXT_ALIGN_RIGHT => Some(TextAlign::Right),
        TEXT_ALIGN_JUSTIFY => Some(TextAlign::Left),
        _ => None,
    }
}

/// Map an ABI `WHITESPACE_*` id to a gpui `WhiteSpace`. `WHITESPACE_DEFAULT`
/// (0) and unknown ids map to `None`. `PRE`/`PRE_WRAP` map to `Nowrap`/`Normal`:
/// gpui 0.2.2's `WhiteSpace` has only `Normal` (wrap) and `Nowrap` (no wrap);
/// literal-whitespace preservation is a property of the text content itself.
fn map_whitespace(id: i32) -> Option<WhiteSpace> {
    match id {
        WHITESPACE_DEFAULT => None,
        WHITESPACE_NORMAL => Some(WhiteSpace::Normal),
        WHITESPACE_NOWRAP => Some(WhiteSpace::Nowrap),
        WHITESPACE_PRE => Some(WhiteSpace::Nowrap),
        WHITESPACE_PRE_WRAP => Some(WhiteSpace::Normal),
        _ => None,
    }
}

/// Look up (or create) the retained `ScrollHandle` for a scroll div. Keyed
/// divs (those with an `OP_SET_KEY` value) reuse the same handle across every
/// rebuild, so their scroll position persists; keyless divs get a fresh handle
/// each render and reset to the top. Handles live in the per-view store because
/// `ScrollHandle` is `Rc`-based and not `Send`, so it cannot sit in the
/// `Mutex`-guarded `VIEWS` global.
fn scroll_handle_for(
    scroll_handles: &Rc<RefCell<HashMap<String, ScrollHandle>>>,
    key: Option<&str>,
) -> ScrollHandle {
    match key {
        Some(key) => scroll_handles
            .borrow_mut()
            .entry(key.to_owned())
            .or_insert_with(ScrollHandle::new)
            .clone(),
        None => ScrollHandle::new(),
    }
}

/// Build the GPUI element for one committed node. `scroll_handles` is the
/// per-view retained-handle store (see `FfiView.scroll_handles`): scroll divs
/// look up or insert their handle here so scroll position survives the full
/// tree rebuild that every state change triggers. `keyless_scroll_id` hands
/// out per-render ids for scroll divs without an `OP_SET_KEY` (their handle is
/// ephemeral and their position resets on each rebuild). `keyless_focus_id`
/// does the same for focusable divs that have neither a key nor a click id:
/// the focus builders need element state, which needs an id, so one is
/// synthesized per render (and the focus handle resets on each rebuild).
fn render_node(
    node: &UiNode,
    cx: &mut Context<FfiView>,
    fill_available_space: bool,
    scroll_handles: &Rc<RefCell<HashMap<String, ScrollHandle>>>,
    keyless_scroll_id: &Cell<usize>,
    keyless_focus_id: &Cell<usize>,
) -> Option<AnyElement> {
    match node {
        UiNode::Div {
            width,
            height,
            bg,
            flex,
            flex_col,
            center,
            gap,
            rounded,
            padding,
            border_width,
            border_color,
            bg_color,
            margin,
            min_size,
            max_size,
            flex_item,
            align,
            overflow,
            opacity,
            shadow,
            cursor,
            position,
            inset,
            padding_sides,
            text_size,
            text_color,
            font_weight,
            line_height,
            text_align,
            whitespace,
            font_family,
            on_click,
            focusable,
            tab_index,
            tab_stop,
            key,
            children,
        } => {
            // Build children first (recursion borrows `cx`), then attach the
            // click listener (also borrows `cx`) — kept sequential to avoid an
            // aliasing borrow.
            let mut child_elements: Vec<AnyElement> = Vec::new();
            for child in children {
                if let Some(el) = render_node(
                    child,
                    cx,
                    false,
                    scroll_handles,
                    keyless_scroll_id,
                    keyless_focus_id,
                ) {
                    child_elements.push(el);
                }
            }
            let mut d = div();
            if fill_available_space {
                d = d.size_full();
            }
            if *width > 0.0 && *height > 0.0 {
                d = d.w(px(*width)).h(px(*height));
            }
            if let Some((r, g, b, a)) = bg_color {
                // G9: RGBA background with alpha. `rgba()` packs 0xRRGGBBAA
                // (big-endian byte order), so alpha rides in the low byte.
                d = d.bg(rgba(
                    ((*r as u32) << 24)
                        | ((*g as u32) << 16)
                        | ((*b as u32) << 8)
                        | (*a as u32),
                ));
            } else if let Some((r, g, b)) = bg {
                d = d.bg(rgb(((*r as u32) << 16) | ((*g as u32) << 8) | (*b as u32)));
            }
            if *flex {
                d = d.flex();
                if *flex_col {
                    d = d.flex_col();
                }
            }
            if *center {
                d = d.justify_center().items_center();
            }
            if *gap > 0.0 {
                d = d.gap(px(*gap));
            }
            if *rounded > 0.0 {
                d = d.rounded(px(*rounded));
            }
            if let Some((top, right, bottom, left)) = padding_sides {
                // Per-side padding (G7) overrides the uniform `padding` above.
                d.style().padding.top = Some(px(*top).into());
                d.style().padding.right = Some(px(*right).into());
                d.style().padding.bottom = Some(px(*bottom).into());
                d.style().padding.left = Some(px(*left).into());
            } else if *padding > 0.0 {
                d = d.p(px(*padding));
            }
            if *border_width > 0.0 {
                d = d.border(px(*border_width));
                if let Some((r, g, b)) = border_color {
                    d = d.border_color(rgb(
                        ((*r as u32) << 16) | ((*g as u32) << 8) | (*b as u32),
                    ));
                }
            }
            // --- G7 core layout/style (issue #51) -------------------------
            if let Some((top, right, bottom, left)) = margin {
                d.style().margin.top = Some(px(*top).into());
                d.style().margin.right = Some(px(*right).into());
                d.style().margin.bottom = Some(px(*bottom).into());
                d.style().margin.left = Some(px(*left).into());
            }
            if let Some((w, h)) = min_size {
                if *w >= 0.0 {
                    d.style().min_size.width = Some(px(*w).into());
                }
                if *h >= 0.0 {
                    d.style().min_size.height = Some(px(*h).into());
                }
            }
            if let Some((w, h)) = max_size {
                if *w >= 0.0 {
                    d.style().max_size.width = Some(px(*w).into());
                }
                if *h >= 0.0 {
                    d.style().max_size.height = Some(px(*h).into());
                }
            }
            if let Some((grow, shrink, basis)) = flex_item {
                d.style().flex_grow = Some(*grow);
                d.style().flex_shrink = Some(*shrink);
                d.style().flex_basis = Some(if *basis >= 0.0 {
                    px(*basis).into()
                } else {
                    Length::Auto
                });
            }
            if let Some((align_items, justify_content)) = align {
                if let Some(v) = map_align_items(*align_items) {
                    d.style().align_items = Some(v);
                }
                if let Some(v) = map_justify_content(*justify_content) {
                    d.style().justify_content = Some(v);
                }
            }
            // G6 scroll: `Overflow::Scroll` on either axis makes this a real
            // scroll container. The handle is retained per view (keyed by the
            // node's `OP_SET_KEY` value) so the scroll position survives the
            // full tree rebuild every state change triggers; keyless scroll
            // divs get a fresh handle and reset to the top on each rebuild.
            // The handle is applied in the identity branches below, where the
            // element has an id (`track_scroll` needs `StatefulInteractiveElement`).
            let scroll_handle = if let Some((x, y)) = overflow {
                if let Some(v) = map_overflow(*x) {
                    d.style().overflow.x = Some(v);
                }
                if let Some(v) = map_overflow(*y) {
                    d.style().overflow.y = Some(v);
                }
                if *x == OVERFLOW_SCROLL || *y == OVERFLOW_SCROLL {
                    Some(scroll_handle_for(scroll_handles, key.as_deref()))
                } else {
                    None
                }
            } else {
                None
            };
            if let Some(op) = opacity {
                d = d.opacity(*op);
            }
            if let Some(shadow) = shadow {
                let (r, g, b, a) = shadow.color;
                let color = rgba(
                    ((r as u32) << 24) | ((g as u32) << 16) | ((b as u32) << 8) | (a as u32),
                );
                d = d.shadow(vec![BoxShadow {
                    color: color.into(),
                    offset: point(px(shadow.x), px(shadow.y)),
                    blur_radius: px(shadow.blur),
                    spread_radius: px(shadow.spread),
                }]);
            }
            if let Some(mode) = position {
                if *mode == POSITION_ABSOLUTE {
                    d.style().position = Some(Position::Absolute);
                } else if *mode == POSITION_RELATIVE {
                    d.style().position = Some(Position::Relative);
                }
            }
            if let Some((top, right, bottom, left)) = inset {
                d.style().inset.top = Some(px_or_auto(*top));
                d.style().inset.right = Some(px_or_auto(*right));
                d.style().inset.bottom = Some(px_or_auto(*bottom));
                d.style().inset.left = Some(px_or_auto(*left));
            }
            if let Some(kind) = cursor {
                // An explicit cursor on a clickable div is superseded by the
                // pointer applied in the identity/click branches below.
                if let Some(v) = map_cursor(*kind) {
                    d.style().mouse_cursor = Some(v);
                }
            }
            // --- G8 typography (issue #51) --------------------------------
            // Applied to the div's `Style.text` refinement: gpui pushes it via
            // `with_text_style` around child layout/paint (div.rs), and the
            // text element reads the folded stack (`window.text_style()`), so
            // every descendant text node inherits these values.
            if text_size.is_some()
                || text_color.is_some()
                || font_weight.is_some()
                || line_height.is_some()
                || text_align.is_some()
                || whitespace.is_some()
                || font_family.is_some()
            {
                let text = d.style().text.get_or_insert_with(Default::default);
                if let Some(size) = text_size {
                    text.font_size = Some(AbsoluteLength::Pixels(px(*size)));
                }
                if let Some((r, g, b, a)) = text_color {
                    text.color = Some(
                        rgba(
                            ((*r as u32) << 24)
                                | ((*g as u32) << 16)
                                | ((*b as u32) << 8)
                                | (*a as u32),
                        )
                        .into(),
                    );
                }
                if let Some(weight) = font_weight {
                    text.font_weight = Some(FontWeight(*weight as f32));
                }
                if let Some(lh) = line_height {
                    text.line_height = Some(px(*lh).into());
                }
                if let Some(id) = text_align {
                    if let Some(v) = map_text_align(*id) {
                        text.text_align = Some(v);
                    }
                }
                if let Some(id) = whitespace {
                    if let Some(v) = map_whitespace(*id) {
                        text.white_space = Some(v);
                    }
                }
                if let Some(family) = font_family {
                    text.font_family = Some(SharedString::from(family.clone()));
                }
            }
            d.extend(child_elements);
            // Element identity: an explicit key (set via `gpui_set_key`) is the
            // stable identity, independent of click routing. Without a key, a
            // clickable div falls back to its click id (the historical scheme).
            // A keyed div gets an id even when not clickable, so stateful
            // elements that only need identity (not click routing) are stable
            // across rebuilds. Duplicate keys are rejected at commit, so ids
            // never collide here. A scroll div always gets an id (scroll
            // tracking requires element state): keyed ones use their key,
            // keyless scroll divs get an ephemeral per-render id.
            //
            // Keyboard navigation (issue #52): `.focusable()` / `.tab_index()` /
            // `.tab_stop()` all live on `StatefulInteractiveElement`, so they
            // need an element id. A focusable div without a key or click id
            // synthesizes one below (the `keyless_focus_id` counter, mirroring
            // the keyless-scroll scheme). `tab_index`/`tab_stop` imply
            // focusability, so setting either also makes the div focusable.
            let focus_nav = focusable.unwrap_or(false)
                || tab_index.is_some()
                || tab_stop.is_some();
            // Apply the a11y focus builders to a stateful element. Order
            // matters only in that `tab_index` sets `tab_stop = true`, so an
            // explicit `tab_stop(false)` must come after to win.
            let apply_focus = |mut el: Stateful<Div>| {
                if focus_nav {
                    el = el.focusable();
                }
                if let Some(idx) = tab_index {
                    el = el.tab_index(*idx);
                }
                if let Some(stop) = tab_stop {
                    el = el.tab_stop(*stop);
                }
                el
            };
            match (key.as_deref(), *on_click) {
                (Some(key), on_click) => {
                    let mut d = d.id(SharedString::from(format!("gpui_key:{key}")));
                    // G24 headless harness: expose this div's laid-out bounds to
                    // `VisualTestContext::debug_bounds` under its key. Compiles
                    // to a no-op without gpui's `test-support` feature, so the
                    // shipped staticlib pays nothing.
                    d = d.debug_selector(|| key.to_string());
                    if let Some(handle) = &scroll_handle {
                        d = d.track_scroll(handle);
                    }
                    d = apply_focus(d);
                    if let Some(cid) = on_click {
                        d = d
                            .cursor_pointer()
                            .on_click(cx.listener(move |this, _ev: &ClickEvent, _win, cx| {
                                let view = this.view as i32;
                                let changed = unsafe { mb_dispatch(ABI_VERSION, EVENT_CLICK, view, cid, 0) };
                                notify_if_changed(changed, || cx.notify());
                            }));
                    }
                    Some(d.into_any_element())
                }
                (None, Some(cid)) => {
                    // Legacy: identity synthesized from the click id.
                    let mut el = d.id(("gpui_click", cid as usize));
                    if let Some(handle) = &scroll_handle {
                        el = el.track_scroll(handle);
                    }
                    el = apply_focus(el);
                    let el = el
                        .cursor_pointer()
                        .on_click(cx.listener(move |this, _ev: &ClickEvent, _win, cx| {
                            let view = this.view as i32;
                            let changed = unsafe { mb_dispatch(ABI_VERSION, EVENT_CLICK, view, cid, 0) };
                            notify_if_changed(changed, || cx.notify());
                        }))
                        .into_any_element();
                    Some(el)
                }
                (None, None) => match (&scroll_handle, focus_nav) {
                    (Some(handle), _) => {
                        // Keyless scroll div: `track_scroll` needs element state,
                        // which needs an id, so synthesize one. The counter only
                        // disambiguates multiple keyless scroll divs within one
                        // render; it resets each render. Position still resets on
                        // every rebuild because the handle is fresh (a tracked
                        // handle's offset comes from the handle, not element state).
                        let id = keyless_scroll_id.get();
                        keyless_scroll_id.set(id + 1);
                        let el = d.id(("gpui_scroll", id)).track_scroll(handle);
                        Some(apply_focus(el).into_any_element())
                    }
                    (None, true) => {
                        // Focusable but neither keyed nor clickable: synthesize
                        // an id so the focus builders (which require element
                        // state) can attach. The counter disambiguates multiple
                        // such divs within one render and resets each render, so
                        // the focus handle is ephemeral across rebuilds — exactly
                        // like a keyless scroll div. Give the div a key via
                        // `set_key` for focus that survives rebuilds.
                        let id = keyless_focus_id.get();
                        keyless_focus_id.set(id + 1);
                        Some(apply_focus(d.id(("gpui_focus", id))).into_any_element())
                    }
                    (None, false) => Some(d.into_any_element()),
                },
            }
        }
        UiNode::Text {
            content,
            color: (r, g, b),
            size,
        } => {
            // The content string flows through unmodified (issue #16). The
            // first-glyph subpixel fix lives in `TextGlyphInset`, a
            // paint-time-only shim — see its doc comment and
            // `docs/troubleshooting.md` §2.
            let text = div()
                .text_color(rgb(((*r as u32) << 16) | ((*g as u32) << 8) | (*b as u32)))
                .text_size(px(*size))
                // G24 headless harness: expose this text element's laid-out
                // bounds under `text:<content>` (no-op without `test-support`).
                .debug_selector(|| format!("text:{content}"))
                .child(content.clone());
            let inset = TextGlyphInset {
                child: text.into_any_element(),
            };
            Some(inset.into_any_element())
        }
    }
}

/// Paint-time-only wrapper that shifts a text element's prepaint origin by a
/// fractional ¼px so its first glyph escapes GPUI's subpixel variant 0.
///
/// GPUI rounds taffy layout to whole pixels (`taffy.enable_rounding()`), so a
/// text element's left edge always lands at an integer x and its first glyph
/// is rasterized at subpixel variant 0 — a hard, un-antialiased left edge
/// (the ~1px "cut" on a leading round glyph such as "G"; see
/// `docs/troubleshooting.md` §2 for the full incident).
///
/// The historical workaround padded the content string with spaces, which
/// polluted the text MoonBit sent (issue #16). This shim keeps the content
/// string untouched: it delegates layout transparently to the child (the
/// layout box is unchanged), and applies the ¼px shift only to the prepaint
/// origin via `Window::with_element_offset`. `Window::layout_bounds` folds
/// the element offset into the child's prepaint bounds, so the first glyph's
/// pen position carries a ¼px fraction — subpixel variant 1 — and gets the
/// same antialiasing as interior glyphs.
///
/// ¼px was chosen because it stays fractional at the scale factors GPUI
/// actually ships (1×, 2×, 3×: 0.25·n is never an integer), whereas ½px would
/// re-snap to variant 0 at 2× HiDPI — the very platform where the original
/// incident was observed. At an exotic scale where 0.25·n is integral (4×,
/// 8×) the glyph falls back to variant 0, i.e. exactly what GPUI renders for
/// every line-leading glyph by default — never worse than unmitigated. The
/// inset is invisible: it moves glyph ink by a quarter pixel and reserves no
/// layout space, so siblings and centering are unaffected.
struct TextGlyphInset {
    child: AnyElement,
}

impl Element for TextGlyphInset {
    type RequestLayoutState = ();
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        // Transparent: the child's own layout node is ours.
        (self.child.request_layout(window, cx), ())
    }

    fn prepaint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        _bounds: Bounds<Pixels>,
        _request_layout: &mut Self::RequestLayoutState,
        window: &mut Window,
        cx: &mut App,
    ) -> Self::PrepaintState {
        window.with_element_offset(point(px(0.25), px(0.0)), |window| {
            self.child.prepaint(window, cx);
        });
    }

    fn paint(
        &mut self,
        _id: Option<&GlobalElementId>,
        _inspector_id: Option<&InspectorElementId>,
        _bounds: Bounds<Pixels>,
        _request_layout: &mut Self::RequestLayoutState,
        _prepaint: &mut Self::PrepaintState,
        window: &mut Window,
        cx: &mut App,
    ) {
        self.child.paint(window, cx);
    }
}

impl IntoElement for TextGlyphInset {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

/// G24 golden layout tests: decode → headless render → assert exact bounds.
#[cfg(test)]
mod headless_tests;

#[cfg(test)]
mod tests {
    use super::*;


    fn clear_state() {
        VIEWS.lock().unwrap_or_else(|e| e.into_inner()).clear();
    }

    struct TestReset;

    impl Drop for TestReset {
        fn drop(&mut self) {
            clear_state();
        }
    }

    fn with_test(f: impl FnOnce()) {
        let _lock = TEST_VIEWS_MUTEX.lock().unwrap_or_else(|e| e.into_inner());
        clear_state();
        let _reset = TestReset;
        f();
    }

    /// Inspect the committed view trees.
    fn with_views<F, R>(f: F) -> R
    where
        F: FnOnce(&[Option<UiNode>]) -> R,
    {
        let guard = VIEWS.lock().unwrap_or_else(|e| e.into_inner());
        f(&guard)
    }

    // --- Command buffer builder (mirrors the MoonBit encoder) --------------

    struct Buf(Vec<u8>);

    impl Buf {
        fn new() -> Self {
            let mut b = Buf(Vec::new());
            b.0.extend_from_slice(BUFFER_MAGIC);
            b.u32(BUFFER_VERSION as u32);
            b
        }

        fn u8(&mut self, v: u8) -> &mut Self {
            self.0.push(v);
            self
        }

        fn u32(&mut self, v: u32) -> &mut Self {
            self.0.extend_from_slice(&v.to_le_bytes());
            self
        }

        fn i32(&mut self, v: i32) -> &mut Self {
            self.u32(v as u32)
        }

        fn f32(&mut self, v: f32) -> &mut Self {
            self.u32(v.to_bits())
        }

        fn op(&mut self, opcode: i32) -> &mut Self {
            self.u8(opcode as u8)
        }

        fn str(&mut self, s: &str) -> &mut Self {
            let bytes = s.as_bytes();
            self.u32(bytes.len() as u32);
            self.0.extend_from_slice(bytes);
            self
        }

        fn div(&mut self) -> &mut Self {
            self.op(OP_DIV)
        }

        fn text(&mut self, content: &str, r: u8, g: u8, b: u8, size: f32) -> &mut Self {
            self.op(OP_TEXT).str(content).u8(r).u8(g).u8(b).f32(size)
        }

        fn set_root(&mut self) -> &mut Self {
            self.op(OP_SET_ROOT)
        }

        fn add_child(&mut self) -> &mut Self {
            self.op(OP_ADD_CHILD)
        }

        fn build(&self, view: i32) -> i32 {
            gpui_build_tree(view, self.0.as_ptr(), self.0.len() as i32)
        }
    }

    // --- Happy path --------------------------------------------------------

    #[::core::prelude::v1::test]
    fn builds_and_commits_a_full_tree() {
        with_test(|| {
            let mut b = Buf::new();
            // root: bg(1,2,3), flex col, center, gap 7, rounded 8, padding 5,
            // border 2 (9,9,9), key "root"
            b.div()
                .op(OP_SET_BG)
                .u8(1)
                .u8(2)
                .u8(3)
                .op(OP_SET_FLEX)
                .u8(1)
                .op(OP_SET_CENTER)
                .op(OP_SET_GAP)
                .f32(7.0)
                .op(OP_SET_ROUNDED)
                .f32(8.0)
                .op(OP_SET_PADDING)
                .f32(5.0)
                .op(OP_SET_BORDER)
                .f32(2.0)
                .u8(9)
                .u8(9)
                .u8(9)
                .op(OP_SET_SIZE)
                .f32(100.0)
                .f32(50.0)
                .op(OP_SET_KEY)
                .str("root");
            // child button: clickable, keyed
            b.div()
                .op(OP_SET_ON_CLICK)
                .i32(9)
                .op(OP_SET_KEY)
                .str("btn");
            b.add_child();
            // text child (non-ASCII + embedded NUL)
            b.text("A\0あ", 4, 5, 6, 14.0);
            b.add_child();
            b.set_root();

            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                let Some(UiNode::Div {
                    width,
                    height,
                    bg: Some((1, 2, 3)),
                    flex: true,
                    flex_col: true,
                    center: true,
                    gap,
                    rounded,
                    padding,
                    border_width,
                    border_color: Some((9, 9, 9)),
                    on_click: None,
                    key: Some(root_key),
                    children,
                    ..
                }) = &views[0]
                else {
                    panic!("root div mismatch");
                };
                assert_eq!(*width, 100.0);
                assert_eq!(*height, 50.0);
                assert_eq!(*gap, 7.0);
                assert_eq!(*rounded, 8.0);
                assert_eq!(*padding, 5.0);
                assert_eq!(*border_width, 2.0);
                assert_eq!(root_key, "root");
                assert_eq!(children.len(), 2);
                assert!(matches!(
                    &children[0],
                    UiNode::Div {
                        on_click: Some(9),
                        key: Some(k),
                        ..
                    } if k == "btn"
                ));
                assert!(matches!(
                    &children[1],
                    UiNode::Text {
                        content,
                        color: (4, 5, 6),
                        size,
                    } if content == "A\0あ" && *size == 14.0
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn commit_replaces_previous_tree() {
        with_test(|| {
            let mut first = Buf::new();
            first.div().op(OP_SET_BG).u8(1).u8(2).u8(3).set_root();
            assert_eq!(first.build(0), GPUI_STATUS_OK);

            let mut second = Buf::new();
            second.div().op(OP_SET_BG).u8(4).u8(5).u8(6).set_root();
            assert_eq!(second.build(0), GPUI_STATUS_OK);

            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { bg: Some((4, 5, 6)), .. })
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn commits_to_distinct_views() {
        with_test(|| {
            let mut v0 = Buf::new();
            v0.div().op(OP_SET_BG).u8(1).u8(0).u8(0).set_root();
            assert_eq!(v0.build(0), GPUI_STATUS_OK);

            let mut v1 = Buf::new();
            v1.div().op(OP_SET_BG).u8(0).u8(1).u8(0).set_root();
            assert_eq!(v1.build(1), GPUI_STATUS_OK);

            with_views(|views| {
                assert!(matches!(&views[0], Some(UiNode::Div { bg: Some((1, 0, 0)), .. })));
                assert!(matches!(&views[1], Some(UiNode::Div { bg: Some((0, 1, 0)), .. })));
            });
        });
    }

    // --- Header / framing validation ---------------------------------------

    #[::core::prelude::v1::test]
    fn rejects_bad_magic_and_version() {
        with_test(|| {
            let mut bad_magic = Buf::new();
            bad_magic.0[0] = b'X';
            bad_magic.div().set_root();
            assert_eq!(bad_magic.build(0), GPUI_STATUS_BAD_BUFFER_VERSION);

            let mut bad_version = Buf::new();
            bad_version.0[4] = 0xFF; // corrupt the version u32
            bad_version.div().set_root();
            assert_eq!(bad_version.build(0), GPUI_STATUS_BAD_BUFFER_VERSION);
        });
    }

    #[::core::prelude::v1::test]
    fn rejects_null_pointer_and_negative_length() {
        with_test(|| {
            assert_eq!(
                gpui_build_tree(0, std::ptr::null(), 8),
                GPUI_STATUS_TRUNCATED_BUFFER
            );
            let b = Buf::new();
            assert_eq!(
                gpui_build_tree(0, b.0.as_ptr(), -1),
                GPUI_STATUS_TRUNCATED_BUFFER
            );
        });
    }

    #[::core::prelude::v1::test]
    fn rejects_truncated_operand() {
        with_test(|| {
            // OP_SET_BG needs 3 bytes; supply only 2 then end the buffer.
            let mut b = Buf::new();
            b.div().op(OP_SET_BG).u8(1).u8(2);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);

            // OP_TEXT with a declared length longer than the remaining bytes.
            let mut t = Buf::new();
            t.op(OP_TEXT).u32(999).u8(b'a').set_root();
            assert_eq!(t.build(0), GPUI_STATUS_TRUNCATED_BUFFER);

            // OP_SET_PADDING needs an f32; end the buffer right after the opcode.
            let mut p = Buf::new();
            p.div().op(OP_SET_PADDING);
            assert_eq!(p.build(0), GPUI_STATUS_TRUNCATED_BUFFER);

            // OP_SET_BORDER needs f32 + 3 bytes; supply width and only 2 bytes.
            let mut br = Buf::new();
            br.div().op(OP_SET_BORDER).f32(1.0).u8(1).u8(2);
            assert_eq!(br.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn rejects_huge_string_length_without_panic() {
        with_test(|| {
            // A declared length near the address-space ceiling must report
            // truncation, not overflow the cursor's bounds check.
            let mut t = Buf::new();
            t.op(OP_TEXT).u32(u32::MAX).u8(b'a').set_root();
            assert_eq!(t.build(0), GPUI_STATUS_TRUNCATED_BUFFER);

            let mut k = Buf::new();
            k.div().op(OP_SET_KEY).u32(0x7FFF_FFFF);
            assert_eq!(k.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn invalid_utf8_text_is_lossy_not_fatal() {
        with_test(|| {
            // The boundary replaces invalid UTF-8 with U+FFFD rather than
            // rejecting: a malformed payload still commits, never panics.
            let mut b = Buf::new();
            b.op(OP_TEXT)
                .u32(2)
                .u8(0xFF)
                .u8(0xFE)
                .u8(1)
                .u8(2)
                .u8(3)
                .f32(10.0)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Text {
                        content,
                        color: (1, 2, 3),
                        size,
                    }) if content == "\u{FFFD}\u{FFFD}" && *size == 10.0
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn rejects_unknown_opcode() {
        with_test(|| {
            let mut b = Buf::new();
            b.div().u8(0xFE).set_root();
            assert_eq!(b.build(0), GPUI_STATUS_UNKNOWN_OPCODE);
        });
    }

    #[::core::prelude::v1::test]
    fn rejects_negative_view() {
        with_test(|| {
            let b = Buf::new();
            assert_eq!(b.build(-1), GPUI_STATUS_INVALID_HANDLE);
        });
    }

    #[::core::prelude::v1::test]
    fn run_window_rejects_negative_view() {
        assert_eq!(
            gpui_run_window(-1, 10.0, 10.0),
            GPUI_STATUS_INVALID_HANDLE
        );
    }

    // --- Stack / handle validation -----------------------------------------

    #[::core::prelude::v1::test]
    fn setter_on_empty_stack_fails() {
        with_test(|| {
            let mut b = Buf::new();
            b.op(OP_SET_CENTER).set_root();
            assert_eq!(b.build(0), GPUI_STATUS_INVALID_HANDLE);
        });
    }

    #[::core::prelude::v1::test]
    fn setter_on_text_top_fails() {
        with_test(|| {
            let mut b = Buf::new();
            b.text("x", 0, 0, 0, 12.0).op(OP_SET_CENTER);
            assert_eq!(b.build(0), GPUI_STATUS_WRONG_NODE_KIND);
        });
    }

    #[::core::prelude::v1::test]
    fn padding_and_border_apply_to_div() {
        with_test(|| {
            let mut b = Buf::new();
            b.div()
                .op(OP_SET_PADDING)
                .f32(12.0)
                .op(OP_SET_BORDER)
                .f32(3.0)
                .u8(10)
                .u8(20)
                .u8(30)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div {
                        padding,
                        border_width,
                        border_color: Some((10, 20, 30)),
                        ..
                    }) if *padding == 12.0 && *border_width == 3.0
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn padding_and_border_on_text_top_fail() {
        with_test(|| {
            let mut p = Buf::new();
            p.text("x", 0, 0, 0, 12.0).op(OP_SET_PADDING).f32(4.0);
            assert_eq!(p.build(0), GPUI_STATUS_WRONG_NODE_KIND);

            let mut br = Buf::new();
            br.text("x", 0, 0, 0, 12.0)
                .op(OP_SET_BORDER)
                .f32(1.0)
                .u8(0)
                .u8(0)
                .u8(0);
            assert_eq!(br.build(0), GPUI_STATUS_WRONG_NODE_KIND);
        });
    }

    #[::core::prelude::v1::test]
    fn add_child_underflow_fails() {
        with_test(|| {
            // One node on the stack: add_child needs two.
            let mut one = Buf::new();
            one.div().add_child();
            assert_eq!(one.build(0), GPUI_STATUS_INVALID_HANDLE);

            // Empty stack.
            let mut zero = Buf::new();
            zero.add_child();
            assert_eq!(zero.build(0), GPUI_STATUS_INVALID_HANDLE);
        });
    }

    #[::core::prelude::v1::test]
    fn add_child_to_text_parent_fails() {
        with_test(|| {
            let mut b = Buf::new();
            b.text("p", 0, 0, 0, 12.0).div().add_child();
            assert_eq!(b.build(0), GPUI_STATUS_WRONG_NODE_KIND);
        });
    }

    #[::core::prelude::v1::test]
    fn set_root_on_empty_stack_fails() {
        with_test(|| {
            // OP_SET_ROOT with nothing pushed: the stack underflows.
            let mut b = Buf::new();
            b.set_root();
            assert_eq!(b.build(0), GPUI_STATUS_INVALID_HANDLE);
        });
    }

    #[::core::prelude::v1::test]
    fn build_without_root_fails() {
        with_test(|| {
            let mut b = Buf::new();
            b.div(); // created but never set_root
            assert_eq!(b.build(0), GPUI_STATUS_NO_ROOT);
        });
    }

    #[::core::prelude::v1::test]
    fn nested_attachment_commits() {
        with_test(|| {
            // grandparent absorbs parent absorbs child; root = grandparent.
            let mut b = Buf::new();
            b.div(); // grandparent (0)
            b.div(); // parent (1)
            b.div(); // child (2)
            b.add_child(); // parent(1) absorbs child(2); stack [0, 1]
            b.add_child(); // grandparent(0) absorbs parent(1); stack [0]
            b.set_root(); // root = grandparent(0)
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { children, .. })
                        if matches!(children.as_slice(),
                            [UiNode::Div { children: inner, .. }]
                                if matches!(inner.as_slice(), [UiNode::Div { .. }]))
                ));
            });
        });
    }

    // --- Move / forest semantics (issue #8) --------------------------------

    #[::core::prelude::v1::test]
    fn add_child_moves_not_copies() {
        with_test(|| {
            // Two children attached in order; each appears exactly once under
            // the parent, in attachment order.
            let mut b = Buf::new();
            b.div(); // parent (0)
            b.div().op(OP_SET_BG).u8(1).u8(0).u8(0); // child A (1)
            b.add_child();
            b.div().op(OP_SET_BG).u8(0).u8(1).u8(0); // child B (2)
            b.add_child();
            b.set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { children, .. })
                        if matches!(
                            children.as_slice(),
                            [
                                UiNode::Div {
                                    bg: Some((1, 0, 0)),
                                    children: a,
                                    ..
                                },
                                UiNode::Div {
                                    bg: Some((0, 1, 0)),
                                    children: c,
                                    ..
                                },
                            ] if a.is_empty() && c.is_empty()
                        )
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn subtree_moves_intact() {
        with_test(|| {
            // Grandchild attached to child, then child moved into root: the
            // whole subtree relocates with its contents, nothing duplicated.
            let mut b = Buf::new();
            b.div(); // root (0)
            b.div(); // child (1)
            b.div().op(OP_SET_BG).u8(7).u8(7).u8(7); // grandchild (2)
            b.add_child(); // 2 into 1
            b.add_child(); // 1 into 0
            b.set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { children: root_kids, .. })
                        if matches!(
                            root_kids.as_slice(),
                            [UiNode::Div { children: inner, .. }]
                                if matches!(
                                    inner.as_slice(),
                                    [UiNode::Div {
                                        bg: Some((7, 7, 7)),
                                        children: leaf,
                                        ..
                                    }] if leaf.is_empty()
                                )
                        )
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn unattached_nodes_are_dropped_from_commit() {
        with_test(|| {
            // Forest model: only the designated root is committed; a node
            // never attached nor rooted (here handle 0) is silently discarded.
            let mut b = Buf::new();
            b.div().op(OP_SET_BG).u8(9).u8(9).u8(9); // orphan (0)
            b.div().op(OP_SET_BG).u8(1).u8(2).u8(3); // root (1)
            b.set_root(); // pops 1
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div {
                        bg: Some((1, 2, 3)),
                        children,
                        ..
                    }) if children.is_empty()
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn last_set_root_wins() {
        with_test(|| {
            // Two OP_SET_ROOT in one buffer: the last designation commits.
            let mut b = Buf::new();
            b.div().op(OP_SET_BG).u8(1).u8(0).u8(0);
            b.set_root();
            b.div().op(OP_SET_BG).u8(0).u8(1).u8(0);
            b.set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { bg: Some((0, 1, 0)), .. })
                ));
            });
        });
    }

    // --- Key semantics (issue #9, now via the buffer) ----------------------

    #[::core::prelude::v1::test]
    fn commit_rejects_duplicate_keys_in_tree() {
        with_test(|| {
            let mut b = Buf::new();
            b.div(); // root
            b.div().op(OP_SET_KEY).str("same");
            b.add_child();
            b.div().op(OP_SET_KEY).str("same");
            b.add_child();
            b.set_root();
            assert_eq!(b.build(0), GPUI_STATUS_DUPLICATE_KEY);
            // Failed build leaves the previous (empty) committed tree untouched.
            with_views(|views| assert!(views.is_empty() || views[0].is_none()));
        });
    }

    #[::core::prelude::v1::test]
    fn commit_allows_distinct_keys() {
        with_test(|| {
            let mut b = Buf::new();
            b.div();
            b.div().op(OP_SET_KEY).str("a");
            b.add_child();
            b.div().op(OP_SET_KEY).str("b");
            b.add_child();
            b.set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
        });
    }

    #[::core::prelude::v1::test]
    fn commit_allows_duplicate_click_ids() {
        with_test(|| {
            // click_id is action routing, not identity: duplicates are allowed.
            let mut b = Buf::new();
            b.div();
            b.div().op(OP_SET_ON_CLICK).i32(7);
            b.add_child();
            b.div().op(OP_SET_ON_CLICK).i32(7);
            b.add_child();
            b.set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
        });
    }

    // --- Notification gate -------------------------------------------------

    #[::core::prelude::v1::test]
    fn notification_gate_accepts_only_changed_one() {
        let calls = std::cell::Cell::new(0);
        notify_if_changed(0, || calls.set(calls.get() + 1));
        notify_if_changed(-1, || calls.set(calls.get() + 1));
        notify_if_changed(2, || calls.set(calls.get() + 1));
        assert_eq!(calls.get(), 0);
        notify_if_changed(1, || calls.set(calls.get() + 1));
        assert_eq!(calls.get(), 1);
    }

    // --- Cross-boundary ABI drift guard ------------------------------------

    /// Cross-boundary drift guard (issue #8: EVENT_*/EV_* compatibility).
    ///
    /// The integers Rust ships as the callback `kind` and modifier bits must be
    /// the exact integers MoonBit decodes. Both sides are generated from
    /// `gpui-sys/abi.toml`, but generation is independent (build.rs for Rust,
    /// build.sh/awk for MoonBit) and only *warns* on drift — nothing fails. This
    /// pins the contract headlessly: every compiled Rust constant must equal
    /// `abi.toml`, and `abi.toml` must equal the generated MoonBit file, so a
    /// stale or hand-edited generated file on either side fails here rather than
    /// at runtime.
    #[::core::prelude::v1::test]
    fn abi_constants_match_across_boundary() {
        let manifest = std::env::var("CARGO_MANIFEST_DIR").unwrap();
        let root = std::path::Path::new(&manifest);

        // abi.toml is the single source of truth: [section] headers + key = int.
        let abi_toml = std::fs::read_to_string(root.join("abi.toml")).expect("read abi.toml");
        let mut expected: std::collections::BTreeMap<String, i32> =
            std::collections::BTreeMap::new();
        let mut in_callback = false;
        for raw in abi_toml.lines() {
            let line = raw.split('#').next().unwrap().trim();
            if line.is_empty() {
                continue;
            }
            if let Some(name) = line.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
                in_callback = name.trim() == "callback";
                continue;
            }
            if in_callback {
                continue; // callback signature is string-valued, not a numeric constant
            }
            let (key, value) = line.split_once('=').expect("abi.toml key = value");
            let key = key.trim();
            let Ok(value) = value.trim().parse::<i32>() else {
                continue; // skip non-integer values defensively
            };
            let key = if key == "abi_version" { "ABI_VERSION" } else { key };
            expected.insert(key.to_string(), value);
        }
        assert!(
            !expected.is_empty(),
            "abi.toml yielded no numeric constants; parser drift?"
        );

        // 1) Compiled Rust constants must equal the source of truth.
        let rust_constants = [
            ("ABI_VERSION", ABI_VERSION),
            ("EVENT_CLICK", EVENT_CLICK),
            ("EVENT_KEY", EVENT_KEY),
            ("EVENT_TEXT", EVENT_TEXT),
            ("EVENT_NAMED_KEY", EVENT_NAMED_KEY),
            ("MOD_CTRL", MOD_CTRL),
            ("MOD_ALT", MOD_ALT),
            ("MOD_SHIFT", MOD_SHIFT),
            ("MOD_PLATFORM", MOD_PLATFORM),
            ("MOD_FUNCTION", MOD_FUNCTION),
            ("KEY_ENTER", KEY_ENTER),
            ("KEY_ESCAPE", KEY_ESCAPE),
            ("KEY_UP", KEY_UP),
            ("KEY_DOWN", KEY_DOWN),
            ("KEY_LEFT", KEY_LEFT),
            ("KEY_RIGHT", KEY_RIGHT),
            ("KEY_TAB", KEY_TAB),
            ("KEY_BACKSPACE", KEY_BACKSPACE),
            ("KEY_DELETE", KEY_DELETE),
            ("KEY_HOME", KEY_HOME),
            ("KEY_END", KEY_END),
            ("KEY_PAGEUP", KEY_PAGEUP),
            ("KEY_PAGEDOWN", KEY_PAGEDOWN),
            ("OP_DIV", OP_DIV),
            ("OP_TEXT", OP_TEXT),
            ("OP_SET_SIZE", OP_SET_SIZE),
            ("OP_SET_BG", OP_SET_BG),
            ("OP_SET_FLEX", OP_SET_FLEX),
            ("OP_SET_CENTER", OP_SET_CENTER),
            ("OP_SET_GAP", OP_SET_GAP),
            ("OP_SET_ROUNDED", OP_SET_ROUNDED),
            ("OP_SET_ON_CLICK", OP_SET_ON_CLICK),
            ("OP_SET_KEY", OP_SET_KEY),
            ("OP_SET_PADDING", OP_SET_PADDING),
            ("OP_SET_BORDER", OP_SET_BORDER),
            ("OP_SET_BG_COLOR", OP_SET_BG_COLOR),
            ("OP_SET_MARGIN", OP_SET_MARGIN),
            ("OP_SET_MIN_SIZE", OP_SET_MIN_SIZE),
            ("OP_SET_MAX_SIZE", OP_SET_MAX_SIZE),
            ("OP_SET_FLEX_ITEM", OP_SET_FLEX_ITEM),
            ("OP_SET_ALIGN", OP_SET_ALIGN),
            ("OP_SET_OVERFLOW", OP_SET_OVERFLOW),
            ("OP_SET_OPACITY", OP_SET_OPACITY),
            ("OP_SET_SHADOW", OP_SET_SHADOW),
            ("OP_SET_CURSOR", OP_SET_CURSOR),
            ("OP_SET_POSITION", OP_SET_POSITION),
            ("OP_SET_INSET", OP_SET_INSET),
            ("OP_SET_PADDING_SIDES", OP_SET_PADDING_SIDES),
            ("ALIGN_DEFAULT", ALIGN_DEFAULT),
            ("ALIGN_START", ALIGN_START),
            ("ALIGN_CENTER", ALIGN_CENTER),
            ("ALIGN_END", ALIGN_END),
            ("ALIGN_STRETCH", ALIGN_STRETCH),
            ("JUSTIFY_DEFAULT", JUSTIFY_DEFAULT),
            ("JUSTIFY_START", JUSTIFY_START),
            ("JUSTIFY_CENTER", JUSTIFY_CENTER),
            ("JUSTIFY_END", JUSTIFY_END),
            ("JUSTIFY_SPACE_BETWEEN", JUSTIFY_SPACE_BETWEEN),
            ("JUSTIFY_SPACE_AROUND", JUSTIFY_SPACE_AROUND),
            ("OVERFLOW_VISIBLE", OVERFLOW_VISIBLE),
            ("OVERFLOW_HIDDEN", OVERFLOW_HIDDEN),
            ("OVERFLOW_SCROLL", OVERFLOW_SCROLL),
            ("CURSOR_ARROW", CURSOR_ARROW),
            ("CURSOR_POINTER", CURSOR_POINTER),
            ("CURSOR_TEXT", CURSOR_TEXT),
            ("CURSOR_CROSSHAIR", CURSOR_CROSSHAIR),
            ("CURSOR_GRAB", CURSOR_GRAB),
            ("CURSOR_GRABBING", CURSOR_GRABBING),
            ("CURSOR_NOT_ALLOWED", CURSOR_NOT_ALLOWED),
            ("CURSOR_EW_RESIZE", CURSOR_EW_RESIZE),
            ("CURSOR_NS_RESIZE", CURSOR_NS_RESIZE),
            ("CURSOR_COL_RESIZE", CURSOR_COL_RESIZE),
            ("CURSOR_ROW_RESIZE", CURSOR_ROW_RESIZE),
            ("CURSOR_NONE", CURSOR_NONE),
            ("POSITION_RELATIVE", POSITION_RELATIVE),
            ("POSITION_ABSOLUTE", POSITION_ABSOLUTE),
            ("OP_SET_TEXT_SIZE", OP_SET_TEXT_SIZE),
            ("OP_SET_TEXT_COLOR", OP_SET_TEXT_COLOR),
            ("OP_SET_FONT_WEIGHT", OP_SET_FONT_WEIGHT),
            ("OP_SET_LINE_HEIGHT", OP_SET_LINE_HEIGHT),
            ("OP_SET_TEXT_ALIGN", OP_SET_TEXT_ALIGN),
            ("OP_SET_WHITESPACE", OP_SET_WHITESPACE),
            ("OP_SET_FONT_FAMILY", OP_SET_FONT_FAMILY),
            ("OP_SET_FOCUSABLE", OP_SET_FOCUSABLE),
            ("OP_SET_TAB_INDEX", OP_SET_TAB_INDEX),
            ("OP_SET_TAB_STOP", OP_SET_TAB_STOP),
            ("TEXT_ALIGN_DEFAULT", TEXT_ALIGN_DEFAULT),
            ("TEXT_ALIGN_LEFT", TEXT_ALIGN_LEFT),
            ("TEXT_ALIGN_CENTER", TEXT_ALIGN_CENTER),
            ("TEXT_ALIGN_RIGHT", TEXT_ALIGN_RIGHT),
            ("TEXT_ALIGN_JUSTIFY", TEXT_ALIGN_JUSTIFY),
            ("WHITESPACE_DEFAULT", WHITESPACE_DEFAULT),
            ("WHITESPACE_NORMAL", WHITESPACE_NORMAL),
            ("WHITESPACE_NOWRAP", WHITESPACE_NOWRAP),
            ("WHITESPACE_PRE", WHITESPACE_PRE),
            ("WHITESPACE_PRE_WRAP", WHITESPACE_PRE_WRAP),
            ("OP_ADD_CHILD", OP_ADD_CHILD),
            ("OP_SET_ROOT", OP_SET_ROOT),
            ("BUFFER_VERSION", BUFFER_VERSION),
        ];
        for (name, compiled) in rust_constants {
            assert_eq!(
                expected.get(name).copied(),
                Some(compiled),
                "Rust {name} drifted from abi.toml (regenerate src/abi_constants.rs via build.rs)"
            );
        }
        for name in expected.keys() {
            assert!(
                rust_constants.iter().any(|(n, _)| n == name),
                "abi.toml constant {name} has no compiled Rust counterpart"
            );
        }

        // 2) The generated MoonBit file must carry the same values. Whitespace is
        //    stripped so the check survives `moon fmt` spacing changes.
        let mb = std::fs::read_to_string(root.join("../moonbit-bindings/abi_constants.mbt"))
            .expect("read moonbit-bindings/abi_constants.mbt (run build.sh to regenerate)");
        let mb_compact: String = mb.chars().filter(|c| !c.is_whitespace()).collect();
        for (name, value) in &expected {
            let needle = format!("pubconst{name}:Int={value}");
            assert!(
                mb_compact.contains(&needle),
                "MoonBit abi_constants.mbt missing `pub const {name} : Int = {value}` — regenerate via build.sh"
            );
        }
    }

    #[::core::prelude::v1::test]
    fn debug_dump_text_round_trips() {
        with_test(|| {
            // div { text("A\0あ"), text("🎉") }
            let mut b = Buf::new();
            b.div()
                .text("A\0あ", 255, 255, 255, 16.0)
                .add_child()
                .text("🎉", 255, 255, 255, 16.0)
                .add_child()
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);

            // Expected: len u32 LE + utf8 for each text node, DFS pre-order.
            let mut expected = Vec::new();
            for s in ["A\0あ", "🎉"] {
                let bytes = s.as_bytes();
                expected.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
                expected.extend_from_slice(bytes);
            }

            let mut buf = vec![0u8; 256];
            let n = gpui_debug_dump_text(0, buf.as_mut_ptr(), buf.len() as i32);
            assert_eq!(n, expected.len() as i32);
            assert_eq!(&buf[..n as usize], &expected[..]);
        });
    }

    #[::core::prelude::v1::test]
    fn debug_dump_text_rejects_bad_args() {
        with_test(|| {
            let mut buf = [0u8; 8];
            assert_eq!(
                gpui_debug_dump_text(-1, buf.as_mut_ptr(), 8),
                GPUI_STATUS_INVALID_HANDLE
            );
            assert_eq!(
                gpui_debug_dump_text(0, std::ptr::null_mut(), 8),
                GPUI_STATUS_INVALID_HANDLE
            );
            assert_eq!(
                gpui_debug_dump_text(0, buf.as_mut_ptr(), -1),
                GPUI_STATUS_INVALID_HANDLE
            );
            // No tree committed yet.
            assert_eq!(
                gpui_debug_dump_text(0, buf.as_mut_ptr(), 8),
                GPUI_STATUS_INVALID_HANDLE
            );
        });
    }

    #[::core::prelude::v1::test]
    fn named_key_id_maps_known_keys() {
        assert_eq!(named_key_id("enter"), Some(KEY_ENTER));
        assert_eq!(named_key_id("escape"), Some(KEY_ESCAPE));
        assert_eq!(named_key_id("up"), Some(KEY_UP));
        assert_eq!(named_key_id("down"), Some(KEY_DOWN));
        assert_eq!(named_key_id("left"), Some(KEY_LEFT));
        assert_eq!(named_key_id("right"), Some(KEY_RIGHT));
        assert_eq!(named_key_id("tab"), Some(KEY_TAB));
        assert_eq!(named_key_id("backspace"), Some(KEY_BACKSPACE));
        assert_eq!(named_key_id("delete"), Some(KEY_DELETE));
        assert_eq!(named_key_id("home"), Some(KEY_HOME));
        assert_eq!(named_key_id("end"), Some(KEY_END));
        assert_eq!(named_key_id("pageup"), Some(KEY_PAGEUP));
        assert_eq!(named_key_id("pagedown"), Some(KEY_PAGEDOWN));
    }

    #[::core::prelude::v1::test]
    fn named_key_id_rejects_unknown() {
        assert_eq!(named_key_id("k"), None);
        assert_eq!(named_key_id("space"), None);
        assert_eq!(named_key_id(""), None);
        assert_eq!(named_key_id("f13"), None);
    }

    #[::core::prelude::v1::test]
    fn abi_probe_echoes_boundary_values() {
        // The MoonBit side of this check lives in cmd/roundtrip (cross-boundary);
        // here we pin the Rust half: the probe is a pure identity, including the
        // i32 extremes the round-trip sends.
        for v in [i32::MAX, i32::MIN, 0, -1, 42, -42] {
            assert_eq!(gpui_abi_probe(v), v);
        }
    }

    // --- G7 core layout/style + G9 color (issue #51) ----------------------

    #[::core::prelude::v1::test]
    fn set_bg_color_decodes_rgba() {
        with_test(|| {
            let mut b = Buf::new();
            b.div().op(OP_SET_BG_COLOR).u8(1).u8(2).u8(3).u8(128).set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div {
                        bg_color: Some((1, 2, 3, 128)),
                        bg: None,
                        ..
                    })
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_bg_color_truncated_fails() {
        with_test(|| {
            // OP_SET_BG_COLOR needs 4 bytes; supply only 3.
            let mut b = Buf::new();
            b.div().op(OP_SET_BG_COLOR).u8(1).u8(2).u8(3);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn set_margin_decodes_four_sides() {
        with_test(|| {
            let mut b = Buf::new();
            b.div()
                .op(OP_SET_MARGIN)
                .i32(1)
                .i32(2)
                .i32(3)
                .i32(4)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div {
                        margin: Some(m),
                        ..
                    }) if *m == (1.0, 2.0, 3.0, 4.0)
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_margin_truncated_fails() {
        with_test(|| {
            // OP_SET_MARGIN needs 4 i32; supply only 3.
            let mut b = Buf::new();
            b.div().op(OP_SET_MARGIN).i32(1).i32(2).i32(3);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn set_padding_sides_decodes_four_sides() {
        with_test(|| {
            let mut b = Buf::new();
            b.div()
                .op(OP_SET_PADDING_SIDES)
                .i32(5)
                .i32(6)
                .i32(7)
                .i32(8)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div {
                        padding_sides: Some(p),
                        ..
                    }) if *p == (5.0, 6.0, 7.0, 8.0)
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_padding_sides_truncated_fails() {
        with_test(|| {
            // OP_SET_PADDING_SIDES needs 4 i32; supply only 3.
            let mut b = Buf::new();
            b.div().op(OP_SET_PADDING_SIDES).i32(1).i32(2).i32(3);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn set_flex_item_scales_milliunits() {
        with_test(|| {
            let mut b = Buf::new();
            // grow 1.5 (1500), shrink 0.5 (500), basis 100px.
            b.div()
                .op(OP_SET_FLEX_ITEM)
                .i32(1500)
                .i32(500)
                .i32(100)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div {
                        flex_item: Some(f),
                        ..
                    }) if *f == (1.5, 0.5, 100.0)
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_flex_item_truncated_fails() {
        with_test(|| {
            // OP_SET_FLEX_ITEM needs 3 i32; supply only 2.
            let mut b = Buf::new();
            b.div().op(OP_SET_FLEX_ITEM).i32(1000).i32(1000);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn set_opacity_scales_milliunits() {
        with_test(|| {
            let mut b = Buf::new();
            b.div().op(OP_SET_OPACITY).i32(500).set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div {
                        opacity: Some(o),
                        ..
                    }) if (*o - 0.5).abs() < 1e-6
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_opacity_truncated_fails() {
        with_test(|| {
            // OP_SET_OPACITY needs an i32; end the buffer right after the opcode.
            let mut b = Buf::new();
            b.div().op(OP_SET_OPACITY);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn set_shadow_decodes_geometry_and_color() {
        with_test(|| {
            let mut b = Buf::new();
            b.div()
                .op(OP_SET_SHADOW)
                .i32(0)
                .i32(4)
                .i32(6)
                .i32(-1)
                .u8(0)
                .u8(0)
                .u8(0)
                .u8(64)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div {
                        shadow: Some(s),
                        ..
                    }) if s.x == 0.0
                        && s.y == 4.0
                        && s.blur == 6.0
                        && s.spread == -1.0
                        && s.color == (0, 0, 0, 64)
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_shadow_truncated_fails() {
        with_test(|| {
            // OP_SET_SHADOW needs 4 i32 + 4 bytes; supply geometry + 2 bytes.
            let mut b = Buf::new();
            b.div()
                .op(OP_SET_SHADOW)
                .i32(0)
                .i32(0)
                .i32(0)
                .i32(0)
                .u8(0)
                .u8(0);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn set_align_overflow_cursor_position_inset_decode() {
        with_test(|| {
            let mut b = Buf::new();
            b.div()
                .op(OP_SET_ALIGN)
                .i32(ALIGN_CENTER)
                .i32(JUSTIFY_SPACE_BETWEEN)
                .op(OP_SET_OVERFLOW)
                .i32(OVERFLOW_HIDDEN)
                .i32(OVERFLOW_SCROLL)
                .op(OP_SET_CURSOR)
                .i32(CURSOR_POINTER)
                .op(OP_SET_POSITION)
                .i32(POSITION_ABSOLUTE)
                .op(OP_SET_INSET)
                .i32(10)
                .i32(-1)
                .i32(20)
                .i32(-1)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div {
                        align: Some((a, j)),
                        overflow: Some((ox, oy)),
                        cursor: Some(c),
                        position: Some(p),
                        inset: Some(ins),
                        ..
                    }) if *a == ALIGN_CENTER
                        && *j == JUSTIFY_SPACE_BETWEEN
                        && *ox == OVERFLOW_HIDDEN
                        && *oy == OVERFLOW_SCROLL
                        && *c == CURSOR_POINTER
                        && *p == POSITION_ABSOLUTE
                        && *ins == (10.0, -1.0, 20.0, -1.0)
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_min_max_size_decode_with_auto_sentinel() {
        with_test(|| {
            let mut b = Buf::new();
            b.div()
                .op(OP_SET_MIN_SIZE)
                .i32(100)
                .i32(-1)
                .op(OP_SET_MAX_SIZE)
                .i32(-1)
                .i32(400)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div {
                        min_size: Some(mn),
                        max_size: Some(mx),
                        ..
                    }) if *mn == (100.0, -1.0) && *mx == (-1.0, 400.0)
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn new_setters_on_text_top_fail() {
        with_test(|| {
            // Every new setter routes through with_top_div, so a text top must
            // be rejected with WRONG_NODE_KIND rather than corrupting state.
            let cases: Vec<Box<dyn Fn(&mut Buf)>> = vec![
                Box::new(|b| { b.op(OP_SET_BG_COLOR).u8(0).u8(0).u8(0).u8(0); }),
                Box::new(|b| { b.op(OP_SET_MARGIN).i32(0).i32(0).i32(0).i32(0); }),
                Box::new(|b| { b.op(OP_SET_OPACITY).i32(1000); }),
                Box::new(|b| { b.op(OP_SET_CURSOR).i32(CURSOR_POINTER); }),
                Box::new(|b| { b.op(OP_SET_TEXT_SIZE).i32(14); }),
                Box::new(|b| { b.op(OP_SET_FONT_FAMILY).str("Arial"); }),
            ];
            for apply in cases {
                let mut b = Buf::new();
                b.text("x", 0, 0, 0, 12.0);
                apply(&mut b);
                assert_eq!(b.build(0), GPUI_STATUS_WRONG_NODE_KIND);
            }
        });
    }

    // --- G8 typography (issue #51) -----------------------------------------

    #[::core::prelude::v1::test]
    fn set_text_size_decodes_px() {
        with_test(|| {
            let mut b = Buf::new();
            b.div().op(OP_SET_TEXT_SIZE).i32(18).set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { text_size: Some(s), .. }) if *s == 18.0
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_text_size_truncated_fails() {
        with_test(|| {
            // OP_SET_TEXT_SIZE needs an i32; end the buffer right after the opcode.
            let mut b = Buf::new();
            b.div().op(OP_SET_TEXT_SIZE);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn set_text_color_decodes_rgba() {
        with_test(|| {
            let mut b = Buf::new();
            b.div()
                .op(OP_SET_TEXT_COLOR)
                .u8(10)
                .u8(20)
                .u8(30)
                .u8(128)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div {
                        text_color: Some((10, 20, 30, 128)),
                        ..
                    })
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_text_color_truncated_fails() {
        with_test(|| {
            // OP_SET_TEXT_COLOR needs 4 bytes; supply only 3.
            let mut b = Buf::new();
            b.div().op(OP_SET_TEXT_COLOR).u8(1).u8(2).u8(3);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn set_font_weight_clamps_out_of_range() {
        with_test(|| {
            let mut b = Buf::new();
            // 50 clamps up to 100; 1000 clamps down to 900; 700 passes through.
            b.div()
                .op(OP_SET_FONT_WEIGHT)
                .i32(50)
                .op(OP_SET_FONT_WEIGHT)
                .i32(1000)
                .op(OP_SET_FONT_WEIGHT)
                .i32(700)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { font_weight: Some(700), .. })
                ));
            });
            // The clamp is observable on the first two writes too: rebuild a
            // tree that stops at each clamp boundary.
            let mut lo = Buf::new();
            lo.div().op(OP_SET_FONT_WEIGHT).i32(50).set_root();
            assert_eq!(lo.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { font_weight: Some(100), .. })
                ));
            });
            let mut hi = Buf::new();
            hi.div().op(OP_SET_FONT_WEIGHT).i32(1000).set_root();
            assert_eq!(hi.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { font_weight: Some(900), .. })
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_font_weight_truncated_fails() {
        with_test(|| {
            let mut b = Buf::new();
            b.div().op(OP_SET_FONT_WEIGHT);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn set_line_height_scales_milliunits_and_negative_unsets() {
        with_test(|| {
            let mut b = Buf::new();
            // 1500 → 1.5px; a later negative operand unsets it again.
            b.div()
                .op(OP_SET_LINE_HEIGHT)
                .i32(1500)
                .op(OP_SET_LINE_HEIGHT)
                .i32(-1)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { line_height: None, .. })
                ));
            });
            let mut set = Buf::new();
            set.div().op(OP_SET_LINE_HEIGHT).i32(2250).set_root();
            assert_eq!(set.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { line_height: Some(lh), .. }) if *lh == 2.25
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_line_height_truncated_fails() {
        with_test(|| {
            let mut b = Buf::new();
            b.div().op(OP_SET_LINE_HEIGHT);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn set_text_align_and_whitespace_decode_ids() {
        with_test(|| {
            let mut b = Buf::new();
            b.div()
                .op(OP_SET_TEXT_ALIGN)
                .i32(TEXT_ALIGN_CENTER)
                .op(OP_SET_WHITESPACE)
                .i32(WHITESPACE_NOWRAP)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div {
                        text_align: Some(TEXT_ALIGN_CENTER),
                        whitespace: Some(WHITESPACE_NOWRAP),
                        ..
                    })
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_text_align_truncated_fails() {
        with_test(|| {
            let mut b = Buf::new();
            b.div().op(OP_SET_TEXT_ALIGN);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn set_font_family_decodes_string() {
        with_test(|| {
            let mut b = Buf::new();
            b.div().op(OP_SET_FONT_FAMILY).str("Fira Code").set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { font_family: Some(f), .. }) if f == "Fira Code"
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_font_family_truncated_fails() {
        with_test(|| {
            // Declares a 16-byte string but the buffer ends before the payload.
            let mut b = Buf::new();
            b.div().op(OP_SET_FONT_FAMILY).u32(16);
            assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
        });
    }

    #[::core::prelude::v1::test]
    fn typography_setters_on_text_top_fail() {
        with_test(|| {
            // The G8 setters route through with_top_div like every other
            // setter, so a text top must be rejected with WRONG_NODE_KIND.
            let cases: Vec<Box<dyn Fn(&mut Buf)>> = vec![
                Box::new(|b| { b.op(OP_SET_TEXT_SIZE).i32(14); }),
                Box::new(|b| { b.op(OP_SET_TEXT_COLOR).u8(0).u8(0).u8(0).u8(0); }),
                Box::new(|b| { b.op(OP_SET_FONT_WEIGHT).i32(400); }),
                Box::new(|b| { b.op(OP_SET_LINE_HEIGHT).i32(1500); }),
                Box::new(|b| { b.op(OP_SET_TEXT_ALIGN).i32(TEXT_ALIGN_LEFT); }),
                Box::new(|b| { b.op(OP_SET_WHITESPACE).i32(WHITESPACE_NORMAL); }),
                Box::new(|b| { b.op(OP_SET_FONT_FAMILY).str("Arial"); }),
            ];
            for apply in cases {
                let mut b = Buf::new();
                b.text("x", 0, 0, 0, 12.0);
                apply(&mut b);
                assert_eq!(b.build(0), GPUI_STATUS_WRONG_NODE_KIND);
            }
        });
    }

    // --- Keyboard navigation / a11y (issue #52) ---------------------------

    #[::core::prelude::v1::test]
    fn set_focusable_decodes_mode() {
        with_test(|| {
            // Nonzero → focusable; a later zero clears it back to not-focusable.
            let mut b = Buf::new();
            b.div()
                .op(OP_SET_FOCUSABLE)
                .i32(1)
                .op(OP_SET_FOCUSABLE)
                .i32(0)
                .set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { focusable: Some(false), .. })
                ));
            });
            let mut on = Buf::new();
            on.div().op(OP_SET_FOCUSABLE).i32(1).set_root();
            assert_eq!(on.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { focusable: Some(true), .. })
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_tab_index_decodes_value() {
        with_test(|| {
            let mut b = Buf::new();
            b.div().op(OP_SET_TAB_INDEX).i32(3).set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { tab_index: Some(3), .. })
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn set_tab_stop_decodes_mode() {
        with_test(|| {
            let mut b = Buf::new();
            b.div().op(OP_SET_TAB_STOP).i32(0).set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { tab_stop: Some(false), .. })
                ));
            });
            let mut on = Buf::new();
            on.div().op(OP_SET_TAB_STOP).i32(1).set_root();
            assert_eq!(on.build(0), GPUI_STATUS_OK);
            with_views(|views| {
                assert!(matches!(
                    &views[0],
                    Some(UiNode::Div { tab_stop: Some(true), .. })
                ));
            });
        });
    }

    #[::core::prelude::v1::test]
    fn focus_setters_truncated_fail() {
        with_test(|| {
            // Each focus setter needs one i32 operand; end the buffer right
            // after the opcode so the reader runs out of bytes.
            for opcode in [OP_SET_FOCUSABLE, OP_SET_TAB_INDEX, OP_SET_TAB_STOP] {
                let mut b = Buf::new();
                b.div().op(opcode);
                assert_eq!(b.build(0), GPUI_STATUS_TRUNCATED_BUFFER);
            }
        });
    }

    #[::core::prelude::v1::test]
    fn focus_setters_on_text_top_fail() {
        with_test(|| {
            // The focus setters route through with_top_div like every other
            // setter, so a text top must be rejected with WRONG_NODE_KIND.
            for opcode in [OP_SET_FOCUSABLE, OP_SET_TAB_INDEX, OP_SET_TAB_STOP] {
                let mut b = Buf::new();
                b.text("x", 0, 0, 0, 12.0).op(opcode).i32(1);
                assert_eq!(b.build(0), GPUI_STATUS_WRONG_NODE_KIND);
            }
        });
    }

    // --- G6 scroll handle retention (issue #51) ----------------------------

    /// A keyed scroll div must reuse the same `ScrollHandle` across renders so
    /// its scroll position survives the full tree rebuild every state change
    /// triggers. `ScrollHandle` is `Rc`-based, so two lookups of the same key
    /// share one underlying offset cell: mutating it through one handle is
    /// visible through the other. This is the headless proof of the retention
    /// contract (the real scroll wiring needs a window and is exercised by the
    /// demo). Keyless divs get a fresh handle each call and share nothing.
    #[::core::prelude::v1::test]
    fn keyed_scroll_handle_is_retained_across_renders() {
        let store = Rc::new(RefCell::new(HashMap::new()));

        // Two renders of the same keyed div → the same retained handle.
        let first = scroll_handle_for(&store, Some("list"));
        let second = scroll_handle_for(&store, Some("list"));
        first.set_offset(point(px(0.0), px(-120.0)));
        assert_eq!(second.offset(), point(px(0.0), px(-120.0)));

        // A distinct key gets an independent handle (still at the origin).
        let other = scroll_handle_for(&store, Some("other"));
        assert_eq!(other.offset(), point(px(0.0), px(0.0)));

        // Keyless divs never retain: every call is a fresh, isolated handle.
        let keyless_a = scroll_handle_for(&store, None);
        let keyless_b = scroll_handle_for(&store, None);
        keyless_a.set_offset(point(px(0.0), px(-50.0)));
        assert_eq!(keyless_b.offset(), point(px(0.0), px(0.0)));
    }

    // --- Incremental keyed text update (issue #10) -------------------------

    /// Commit a small tree: a keyed `count` div wrapping one text node, plus a
    /// sibling keyed `static` div with its own text. Mirrors the Counter's
    /// count-card shape (keyed div → single text child).
    fn commit_count_tree(view: i32) {
        let mut b = Buf::new();
        b.div().op(OP_SET_KEY).str("root");
        b.div().op(OP_SET_KEY).str("count");
        b.text("Count: 0", 120, 200, 255, 44.0);
        b.add_child(); // text -> count
        b.add_child(); // count -> root
        b.div().op(OP_SET_KEY).str("static");
        b.text("keys: k j r", 130, 135, 148, 14.0);
        b.add_child(); // text -> static
        b.add_child(); // static -> root
        b.set_root();
        assert_eq!(b.build(view), GPUI_STATUS_OK);
    }

    /// Read the content of the first text child of the keyed div `key` in the
    /// committed tree for `view`.
    fn keyed_text(view: usize, key: &str) -> Option<String> {
        fn find<'a>(node: &'a UiNode, key: &str) -> Option<&'a str> {
            let UiNode::Div {
                key: node_key,
                children,
                ..
            } = node
            else {
                return None;
            };
            if node_key.as_deref() == Some(key) {
                return match children.first() {
                    Some(UiNode::Text { content, .. }) => Some(content.as_str()),
                    _ => None,
                };
            }
            children.iter().find_map(|c| find(c, key))
        }
        with_views(|views| {
            views
                .get(view)
                .and_then(|slot| slot.as_ref())
                .and_then(|root| find(root, key))
                .map(str::to_string)
        })
    }

    #[::core::prelude::v1::test]
    fn update_text_updates_keyed_node_in_place() {
        with_test(|| {
            commit_count_tree(0);
            assert_eq!(keyed_text(0, "count").as_deref(), Some("Count: 0"));

            let key = b"count";
            let text = b"Count: 42";
            let status = gpui_update_text(
                0,
                key.as_ptr(),
                key.len() as i32,
                text.as_ptr(),
                text.len() as i32,
            );
            assert_eq!(status, GPUI_STATUS_OK);
            // The keyed node's text changed in place...
            assert_eq!(keyed_text(0, "count").as_deref(), Some("Count: 42"));
            // ...and the sibling subtree is untouched (no rebuild happened).
            assert_eq!(keyed_text(0, "static").as_deref(), Some("keys: k j r"));
        });
    }

    #[::core::prelude::v1::test]
    fn update_text_missing_key_returns_not_found() {
        with_test(|| {
            commit_count_tree(0);
            let key = b"does-not-exist";
            let text = b"x";
            let status = gpui_update_text(
                0,
                key.as_ptr(),
                key.len() as i32,
                text.as_ptr(),
                text.len() as i32,
            );
            assert_eq!(status, GPUI_STATUS_KEY_NOT_FOUND);
            // Tree untouched.
            assert_eq!(keyed_text(0, "count").as_deref(), Some("Count: 0"));
        });
    }

    #[::core::prelude::v1::test]
    fn update_text_no_committed_tree_returns_not_found() {
        with_test(|| {
            // No build_tree call: the view slot is empty.
            let key = b"count";
            let text = b"x";
            let status = gpui_update_text(
                0,
                key.as_ptr(),
                key.len() as i32,
                text.as_ptr(),
                text.len() as i32,
            );
            assert_eq!(status, GPUI_STATUS_KEY_NOT_FOUND);
        });
    }

    #[::core::prelude::v1::test]
    fn update_text_rejects_bad_handles() {
        with_test(|| {
            commit_count_tree(0);
            let key = b"count";
            let text = b"x";
            // Negative view.
            assert_eq!(
                gpui_update_text(
                    -1,
                    key.as_ptr(),
                    key.len() as i32,
                    text.as_ptr(),
                    text.len() as i32,
                ),
                GPUI_STATUS_INVALID_HANDLE
            );
            // Null key pointer / negative length.
            assert_eq!(
                gpui_update_text(0, std::ptr::null(), 0, text.as_ptr(), text.len() as i32),
                GPUI_STATUS_TRUNCATED_BUFFER
            );
            assert_eq!(
                gpui_update_text(0, key.as_ptr(), -1, text.as_ptr(), text.len() as i32),
                GPUI_STATUS_TRUNCATED_BUFFER
            );
        });
    }

    #[::core::prelude::v1::test]
    fn update_text_keyed_div_without_text_child_returns_not_found() {
        with_test(|| {
            // A keyed div whose only child is another div (no text child).
            let mut b = Buf::new();
            b.div().op(OP_SET_KEY).str("root");
            b.div().op(OP_SET_KEY).str("empty");
            b.div(); // non-text child
            b.add_child(); // inner -> empty
            b.add_child(); // empty -> root
            b.set_root();
            assert_eq!(b.build(0), GPUI_STATUS_OK);

            let key = b"empty";
            let text = b"x";
            let status = gpui_update_text(
                0,
                key.as_ptr(),
                key.len() as i32,
                text.as_ptr(),
                text.len() as i32,
            );
            assert_eq!(status, GPUI_STATUS_KEY_NOT_FOUND);
        });
    }
}

/// G25 decoder fuzzing: deterministic seeded PRNG over random and
/// structurally-plausible command buffers; the decoder must never panic.
#[cfg(test)]
mod fuzz_tests;
