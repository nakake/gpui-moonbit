//! Headless layout harness (G24).
//!
//! Decodes a command buffer through the real decoder ([`crate::build_tree_from_buffer`]),
//! renders the committed tree with the real [`crate::render_node`] path inside a
//! gpui `TestAppContext` window (headless: no GPU, no display, deterministic
//! `NoopTextSystem` metrics), and reads element geometry back through gpui's
//! `debug_bounds` hook.
//!
//! Geometry read-back needs per-element selectors: `render_node` tags every
//! keyed div (`OP_SET_KEY`) with `debug_selector(key)` and every text node with
//! `debug_selector("text:<content>")`. The `debug_selector` call compiles to a
//! no-op when gpui's `test-support` feature is off, so the shipped staticlib
//! pays nothing.
//!
//! Compiled for unit tests and behind the `test-support` feature (benches and
//! integration tests). The staticlib build enables neither, so gpui's
//! `test-support` never leaks into production artifacts.

use crate::{FfiView, build_tree_from_buffer};
use gpui::{Bounds, Pixels, Size, TestAppContext};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;
// Serialization is provided by the crate-level `TEST_VIEWS_MUTEX` (see
// `lib.rs`): the harness commits into the process-global `VIEWS`, which the
// unit tests and fuzz tests also touch, so all three share one lock.

/// Decode `buffer` through the real decoder, render the committed tree in a
/// headless window, and return the layout bounds of every element carrying a
/// debug selector: keyed divs under their `OP_SET_KEY` value, text nodes under
/// `"text:<content>"`.
///
/// The headless window is the `TestDisplay`'s full 1920×1080; `FfiView`'s root
/// fills it, so a root div without an explicit size measures 1920×1080 and
/// children lay out from the top-left corner. Returns `Err(status)` with a
/// negative `GPUI_STATUS_*` when the decoder rejects the buffer (nothing is
/// rendered in that case).
///
/// Panics only on genuine harness faults (a requested selector that matched no
/// laid-out element, or a poisoned lock) — never on decoder or render behavior.
pub fn layout_bounds(
    cx: &mut TestAppContext,
    buffer: &[u8],
    selectors: &[&'static str],
) -> Result<HashMap<&'static str, Bounds<Pixels>>, i32> {
    let _guard = crate::TEST_VIEWS_MUTEX
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());

    // Slot 0 is harness-private: the shared lock above excludes concurrent
    // harness callers and every `VIEWS`-mutating unit/fuzz test.
    let status = build_tree_from_buffer(0, buffer);
    if status != crate::GPUI_STATUS_OK {
        return Err(status);
    }

    let (_view, vcx) = cx.add_window_view(|_window, cx| FfiView {
        focus: cx.focus_handle(),
        view: 0,
        scroll_handles: Rc::new(RefCell::new(HashMap::new())),
    });

    // `add_window_view`'s initial draw leaves the rendered tree in the
    // window's `next_frame`; `debug_bounds` reads `rendered_frame`, which is
    // only populated by a *second* draw. Marking the window dirty makes
    // `App::flush_effects` (test-support) redraw it during this `update`,
    // swapping the laid-out tree into `rendered_frame`.
    vcx.update(|window, _| window.refresh());

    let mut bounds = HashMap::new();
    for &selector in selectors {
        let b = vcx
            .debug_bounds(selector)
            .unwrap_or_else(|| panic!("headless harness: no element with debug selector {selector:?}"));
        bounds.insert(selector, b);
    }

    // Drop the window before releasing the lock so the next harness call
    // starts from a clean window list.
    vcx.update(|window, _| window.remove_window());

    Ok(bounds)
}

/// Convenience for the common single-selector case.
pub fn layout_bound(
    cx: &mut TestAppContext,
    buffer: &[u8],
    selector: &'static str,
) -> Result<Bounds<Pixels>, i32> {
    Ok(layout_bounds(cx, buffer, &[selector])?[selector])
}

/// Assert `got` matches the golden bounds exactly. Layout is deterministic
/// under the headless harness (taffy rounding + `NoopTextSystem` metrics), so
/// exact equality is the regression net: any drift in decode, style mapping,
/// or gpui layout fails the test with the offending selector named.
pub fn assert_bounds_eq(
    selector: &str,
    got: Bounds<Pixels>,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
) {
    assert_eq!(
        got,
        Bounds {
            origin: gpui::point(gpui::px(x), gpui::px(y)),
            size: Size {
                width: gpui::px(w),
                height: gpui::px(h),
            },
        },
        "golden bounds mismatch for {selector:?}"
    );
}
