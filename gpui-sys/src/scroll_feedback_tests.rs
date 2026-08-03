//! Scroll position feedback tests (issue #89).
//!
//! Exercises the full headless path: decode a tree whose keyed scroll div
//! carries an `OP_SET_SCROLL_ID`, render it in a `TestAppContext` window,
//! mutate the retained `ScrollHandle` (the same state gpui's wheel handler
//! mutates), and observe the paint-phase edge detection through the
//! `test-dispatch-stub` recorder plus the `gpui_scroll_copy_state` pull ABI.

use crate::{
    EVENT_SCROLL, FfiView, GPUI_STATUS_OK, SCROLL_STATE_BYTES, gpui_scroll_copy_state,
    take_recorded_dispatches,
};
use gpui::{TestAppContext, point, px};
use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

/// Pull and decode the six-f32 state record for `(view, scroll_id)`.
fn pull_state(view: i32, scroll_id: i32) -> [f32; 6] {
    let mut buf = [0u8; SCROLL_STATE_BYTES];
    let written = gpui_scroll_copy_state(view, scroll_id, buf.as_mut_ptr(), buf.len() as i32);
    assert_eq!(written, SCROLL_STATE_BYTES as i32, "pull failed: {written}");
    let mut values = [0f32; 6];
    for (v, c) in values.iter_mut().zip(buf.chunks_exact(4)) {
        *v = f32::from_le_bytes(c.try_into().unwrap());
    }
    values
}

fn recorded_scrolls() -> Vec<(i32, i32, i32)> {
    take_recorded_dispatches()
        .into_iter()
        .filter(|e| e.kind == EVENT_SCROLL)
        .map(|e| (e.view, e.data_a, e.data_b))
        .collect()
}

/// The whole contract in one deterministic scenario: the first paint seeds
/// silently, an offset change announces exactly once and is pullable, a
/// no-change redraw stays silent, and an overshooting offset is clamped to
/// the scrollable extent before it is announced.
#[gpui::test]
async fn scroll_offset_change_dispatches_once_and_pulls_clamped(cx: &mut TestAppContext) {
    // Same order as the async-injection suite (INJECT lock, then VIEWS): the
    // dispatch recorder and the scroll statics are process globals.
    let _suite = crate::INJECT_TEST_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    let _recorder = crate::install_dispatch_recorder();
    crate::set_dispatch_changed(0);
    let _views = crate::TEST_VIEWS_MUTEX
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    crate::VIEWS.lock().unwrap_or_else(|e| e.into_inner()).clear();
    *crate::SCROLL_MIRROR.lock().unwrap_or_else(|e| e.into_inner()) = None;
    *crate::SCROLL_SENT.lock().unwrap_or_else(|e| e.into_inner()) = None;

    // root > scroll div (200×100, overflow-y scroll, key "feed", id 7) >
    // content div (200×500) — a 400px scrollable extent.
    let mut buffer = Vec::new();
    buffer.extend_from_slice(crate::BUFFER_MAGIC);
    buffer.extend_from_slice(&(crate::BUFFER_VERSION as u32).to_le_bytes());
    let op = |buffer: &mut Vec<u8>, opcode: i32| buffer.push(opcode as u8);
    op(&mut buffer, crate::abi_constants::OP_DIV); // root
    op(&mut buffer, crate::abi_constants::OP_DIV); // scroll container
    op(&mut buffer, crate::abi_constants::OP_SET_SIZE);
    buffer.extend_from_slice(&200f32.to_le_bytes());
    buffer.extend_from_slice(&100f32.to_le_bytes());
    op(&mut buffer, crate::abi_constants::OP_SET_OVERFLOW);
    buffer.extend_from_slice(&0i32.to_le_bytes());
    buffer.extend_from_slice(&crate::abi_constants::OVERFLOW_SCROLL.to_le_bytes());
    op(&mut buffer, crate::abi_constants::OP_SET_KEY);
    buffer.extend_from_slice(&4u32.to_le_bytes());
    buffer.extend_from_slice(b"feed");
    op(&mut buffer, crate::abi_constants::OP_SET_SCROLL_ID);
    buffer.extend_from_slice(&7i32.to_le_bytes());
    op(&mut buffer, crate::abi_constants::OP_DIV); // content
    op(&mut buffer, crate::abi_constants::OP_SET_SIZE);
    buffer.extend_from_slice(&200f32.to_le_bytes());
    buffer.extend_from_slice(&500f32.to_le_bytes());
    op(&mut buffer, crate::abi_constants::OP_ADD_CHILD); // content -> scroll
    op(&mut buffer, crate::abi_constants::OP_ADD_CHILD); // scroll -> root
    op(&mut buffer, crate::abi_constants::OP_SET_ROOT);
    assert_eq!(crate::build_tree_from_buffer(0, &buffer), GPUI_STATUS_OK);

    let scroll_handles = Rc::new(RefCell::new(HashMap::new()));
    let handles = scroll_handles.clone();
    let (_view, vcx) = cx.add_window_view(|_window, cx| FfiView {
        focus: cx.focus_handle(),
        view: 0,
        scroll_handles,
        inputs: Rc::new(RefCell::new(HashMap::new())),
    });
    vcx.update(|window, _| window.refresh());
    vcx.run_until_parked();

    // First paint: mirror seeded, no event (nothing scrolled yet).
    assert_eq!(recorded_scrolls(), vec![]);
    let state = pull_state(0, 7);
    assert_eq!(state[0..2], [0.0, 0.0], "initial offset");
    assert_eq!(state[2..4], [0.0, 400.0], "scrollable extent");
    assert_eq!(state[4..6], [200.0, 100.0], "viewport");

    // Offset change (the same handle state gpui's wheel handler mutates):
    // exactly one EVENT_SCROLL, and the pull sees the settled value.
    let handle = handles
        .borrow()
        .get("feed")
        .cloned()
        .expect("keyed scroll handle is retained");
    handle.set_offset(point(px(0.), px(-30.)));
    vcx.update(|window, _| window.refresh());
    vcx.run_until_parked();
    assert_eq!(recorded_scrolls(), vec![(0, 7, 0)]);
    assert_eq!(pull_state(0, 7)[0..2], [0.0, -30.0]);

    // Redraw without a change: silent.
    vcx.update(|window, _| window.refresh());
    vcx.run_until_parked();
    assert_eq!(recorded_scrolls(), vec![]);

    // Overshoot: announced and pulled as the clamped extent, not the raw
    // value (gpui itself would clamp it one prepaint later, without a second
    // notify — see `ScrollFeedback`'s doc comment).
    handle.set_offset(point(px(0.), px(-10_000.)));
    vcx.update(|window, _| window.refresh());
    vcx.run_until_parked();
    assert_eq!(recorded_scrolls(), vec![(0, 7, 0)]);
    assert_eq!(pull_state(0, 7)[0..2], [0.0, -400.0]);

    vcx.update(|window, _| window.remove_window());
    crate::VIEWS.lock().unwrap_or_else(|e| e.into_inner()).clear();
}
