//! Async event injection tests (RFC 0002 §5-5).
//!
//! Exercises the full headless path: producer → `gpui_post_event` → drain pump
//! → `EVENT_ASYNC` dispatch, using the `test-dispatch-stub` recorder to observe
//! dispatches and drive the `changed` return value. The pump runs on the test's
//! foreground executor; `cx.run_until_parked()` drives it.

use crate::GPUI_STATUS_OK;
use crate::headless::setup_async_injection;
use crate::{EVENT_ASYNC, gpui_post_event, take_recorded_dispatches};
use gpui::TestAppContext;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

/// Serializes the whole async-injection suite, and against the
/// `gpui_post_event` unit tests: the injection queue, `EVENT_QUEUE`, and the
/// dispatch recorder are process globals, and these tests post/drain
/// concurrently with one another under `#[gpui::test]`, so they must not
/// overlap. Acquired before any post in each test.
fn lock_suite() -> std::sync::MutexGuard<'static, ()> {
    crate::INJECT_TEST_LOCK
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

/// The full path: a producer thread posts, the pump drains it on the main
/// thread, and the stub records one `EVENT_ASYNC` dispatch carrying the
/// payload.
#[gpui::test]
async fn injected_event_reaches_dispatch(cx: &mut TestAppContext) {
    let _suite = lock_suite();
    let _recorder = crate::install_dispatch_recorder();
    let test = setup_async_injection(cx);

    let producer = std::thread::spawn(|| {
        let payload = b"hello-from-thread";
        assert_eq!(
            gpui_post_event(0, payload.as_ptr(), payload.len() as i32),
            GPUI_STATUS_OK
        );
    });
    producer.join().unwrap();

    cx.run_until_parked();

    let events = take_recorded_dispatches();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].kind, EVENT_ASYNC);
    assert_eq!(events[0].view, 0);
    assert_eq!(events[0].data_b, 17); // byte length
    assert_eq!(events[0].payload, b"hello-from-thread");

    drop(test);
}

/// Multiple producer threads: every post is delivered exactly once, in a
/// single global FIFO. Each producer's own posts keep their relative order
/// (they carry a per-producer sequence number), even though the interleaving
/// across producers is nondeterministic.
#[gpui::test]
async fn multi_producer_preserves_per_producer_order(cx: &mut TestAppContext) {
    let _suite = lock_suite();
    let _recorder = crate::install_dispatch_recorder();
    let test = setup_async_injection(cx);

    const PRODUCERS: usize = 4;
    const PER_PRODUCER: usize = 25;
    let mut handles = Vec::new();
    for p in 0..PRODUCERS {
        handles.push(std::thread::spawn(move || {
            for seq in 0..PER_PRODUCER {
                let payload = [p as u8, seq as u8];
                assert_eq!(gpui_post_event(0, payload.as_ptr(), 2), GPUI_STATUS_OK);
            }
        }));
    }
    for handle in handles {
        handle.join().unwrap();
    }

    cx.run_until_parked();

    let events = take_recorded_dispatches();
    assert_eq!(events.len(), PRODUCERS * PER_PRODUCER);

    // Per-producer sequence numbers must be strictly increasing.
    let mut last_seq = [usize::MAX; PRODUCERS];
    let mut counts = [0usize; PRODUCERS];
    for event in &events {
        assert_eq!(event.payload.len(), 2);
        let (p, seq) = (event.payload[0] as usize, event.payload[1] as usize);
        assert!(p < PRODUCERS);
        if last_seq[p] != usize::MAX {
            assert!(seq > last_seq[p], "producer {p} order violated: {seq} after {}", last_seq[p]);
        }
        last_seq[p] = seq;
        counts[p] += 1;
    }
    assert_eq!(counts, [PER_PRODUCER; PRODUCERS]);

    drop(test);
}

/// A post made before the window (and pump) exists is queued and delivered by
/// the pump's startup drain on the first `run_until_parked`.
#[gpui::test]
async fn pre_startup_post_is_drained_on_first_park(cx: &mut TestAppContext) {
    let _suite = lock_suite();
    let _recorder = crate::install_dispatch_recorder();

    // Post before any window/pump exists.
    let payload = b"early";
    assert_eq!(gpui_post_event(0, payload.as_ptr(), payload.len() as i32), GPUI_STATUS_OK);

    let test = setup_async_injection(cx);
    cx.run_until_parked();

    let events = take_recorded_dispatches();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].kind, EVENT_ASYNC);
    assert_eq!(events[0].payload, b"early");

    drop(test);
}

/// When the dispatch reports a change (returns 1), the pump notifies the view
/// through the `WeakEntity` registry. A dispatch returning 0 does not notify.
#[gpui::test]
async fn dispatch_change_notifies_view(cx: &mut TestAppContext) {
    let _suite = lock_suite();
    let _recorder = crate::install_dispatch_recorder();
    let test = setup_async_injection(cx);

    let notify_count = Arc::new(AtomicUsize::new(0));
    let counter = notify_count.clone();
    let _subscription = cx.update(|app| {
        app.observe(&test.view, move |_, _| {
            counter.fetch_add(1, Ordering::SeqCst);
        })
    });

    // changed = 0 → no notification.
    crate::set_dispatch_changed(0);
    let payload = b"a";
    assert_eq!(gpui_post_event(0, payload.as_ptr(), 1), GPUI_STATUS_OK);
    cx.run_until_parked();
    assert_eq!(notify_count.load(Ordering::SeqCst), 0);

    // changed = 1 → exactly one notification.
    crate::set_dispatch_changed(1);
    assert_eq!(gpui_post_event(0, payload.as_ptr(), 1), GPUI_STATUS_OK);
    cx.run_until_parked();
    assert_eq!(notify_count.load(Ordering::SeqCst), 1);

    drop(test);
}

/// An event addressed to a view with no committed tree is dropped at drain
/// (RFC 0002 §6-2) rather than dispatched.
#[gpui::test]
async fn unknown_view_is_dropped_at_drain(cx: &mut TestAppContext) {
    let _suite = lock_suite();
    let _recorder = crate::install_dispatch_recorder();
    let test = setup_async_injection(cx);

    // View 0 has a committed tree; view 7 does not.
    let payload = b"x";
    assert_eq!(gpui_post_event(7, payload.as_ptr(), 1), GPUI_STATUS_OK);
    assert_eq!(gpui_post_event(0, payload.as_ptr(), 1), GPUI_STATUS_OK);
    cx.run_until_parked();

    let events = take_recorded_dispatches();
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].view, 0);

    drop(test);
}
