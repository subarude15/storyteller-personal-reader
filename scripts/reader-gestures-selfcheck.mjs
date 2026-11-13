/**
 * Assert-based check for immersive reader gesture arbitration (no framework).
 * Drives the real ReaderGestures.js arbiter with a fake clock and fake section
 * documents. This is NOT native WKWebView verification: iOS long-press
 * selection, synthetic click timing, and the edit menu need a device pass.
 * Run: node scripts/reader-gestures-selfcheck.mjs
 */
import {
  HOLD_DELAY_MS,
  IMMERSIVE_BROWSE_CLASS,
  PENDING_READER_CONTROLS_GLOBAL,
  ReaderHoldArbiter,
  pendingReaderControls,
  ReaderTapRouter,
  anchorFromCFI,
  resolveSeekRange,
} from "../SilveranKit/Sources/Kit/Resources/WebResources/ReaderGestures.js";

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

function fakeClock() {
  let now = 0;
  let nextId = 1;
  const timers = new Map();
  return {
    now: () => now,
    setTimeout(fn, ms) {
      const id = nextId++;
      timers.set(id, { at: now + ms, fn });
      return id;
    },
    clearTimeout(id) {
      timers.delete(id);
    },
    advance(ms) {
      const until = now + ms;
      for (;;) {
        let due = null;
        for (const [id, t] of timers) {
          if (t.at <= until && (!due || t.at < due[1].at)) due = [id, t];
        }
        if (!due) break;
        timers.delete(due[0]);
        now = due[1].at;
        due[1].fn();
      }
      now = until;
    },
    get pending() {
      return timers.size;
    },
  };
}

function fakeClassList() {
  const set = new Set();
  return {
    add: (c) => set.add(c),
    remove: (c) => set.delete(c),
    contains: (c) => set.has(c),
    toggle(c, on) {
      const next = on === undefined ? !set.has(c) : !!on;
      if (next) set.add(c);
      else set.delete(c);
      return next;
    },
  };
}

/** `charRects(i)` returns the client rects of the character at offset i. */
function fakeDoc({ selection = null, caret = null, charRects = () => [] } = {}) {
  const listeners = new Map();
  const byId = new Map();
  const head = {
    appendChild(el) {
      if (el.id) byId.set(el.id, el);
    },
  };
  const doc = {
    defaultView: {},
    documentElement: { classList: fakeClassList() },
    head,
    selection,
    caret,
    caretCalls: [],
    addEventListener(type, fn, opts) {
      const capture = typeof opts === "object" ? !!opts.capture : !!opts;
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push({ fn, capture, passive: typeof opts === "object" ? opts.passive : undefined });
    },
    removeEventListener(type, fn) {
      listeners.set(type, (listeners.get(type) || []).filter((l) => l.fn !== fn));
    },
    listenerCount(type) {
      return (listeners.get(type) || []).length;
    },
    listener(type) {
      return listeners.get(type) || [];
    },
    getElementById: (id) => byId.get(id) || null,
    createElement: (tag) => ({
      tagName: tag,
      id: "",
      textContent: "",
      remove() {
        byId.delete(this.id);
      },
    }),
    getSelection: () => doc.selection,
    caretRangeFromPoint(x, y) {
      doc.caretCalls.push({ x, y, lifted: !doc.documentElement.classList.contains(IMMERSIVE_BROWSE_CLASS) });
      return doc.caret;
    },
    createRange() {
      return {
        selected: null,
        selectNodeContents(node) {
          this.selected = node;
        },
        start: -1,
        end: -1,
        setStart(_node, offset) {
          this.start = offset;
        },
        setEnd(_node, offset) {
          this.end = offset;
        },
        getClientRects() {
          if (this.end !== this.start + 1) throw new Error("probe must cover exactly one character");
          return charRects(this.start);
        },
      };
    },
    /** Dispatch through capture listeners only (the arbiter registers capture). */
    fire(type, init = {}) {
      const event = {
        type,
        target: init.target ?? { closest: () => null },
        touches: init.touches ?? [],
        changedTouches: init.changedTouches ?? init.touches ?? [],
        clientX: init.clientX ?? 0,
        clientY: init.clientY ?? 0,
        defaultPrevented: false,
        propagationStopped: false,
        immediateStopped: false,
        preventDefault() {
          this.defaultPrevented = true;
        },
        stopPropagation() {
          this.propagationStopped = true;
        },
        stopImmediatePropagation() {
          this.immediateStopped = true;
          this.propagationStopped = true;
        },
      };
      for (const l of listeners.get(type) || []) {
        l.fn(event);
        if (event.immediateStopped) break;
      }
      return event;
    },
  };
  return doc;
}

/** Section iframe window: teardown listeners and the hosting <iframe>'s connection. */
function fakeWindow() {
  const listeners = new Map();
  return {
    frameElement: { isConnected: true },
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, []);
      listeners.get(type).push(fn);
    },
    removeEventListener(type, fn) {
      listeners.set(type, (listeners.get(type) || []).filter((f) => f !== fn));
    },
    count: (type) => (listeners.get(type) || []).length,
    fire: (type) => [...(listeners.get(type) || [])].forEach((fn) => fn({ type })),
  };
}

function liveDoc() {
  const doc = fakeDoc();
  doc.defaultView = fakeWindow();
  return doc;
}

const ARBITER_EVENTS = ["touchstart", "touchmove", "touchend", "touchcancel", "click", "dblclick", "contextmenu"];
const hasNoListeners = (doc) => ARBITER_EVENTS.every((t) => doc.listenerCount(t) === 0);
const isLocked = (doc) => doc.documentElement.classList.contains(IMMERSIVE_BROWSE_CLASS);

const touch = (x, y) => [{ clientX: x, clientY: y, screenX: x, screenY: y }];

function makeArbiter(overrides = {}) {
  const clock = fakeClock();
  const calls = { hold: 0, release: 0 };
  let turn = false;
  let scrolled = false;
  const arbiter = new ReaderHoldArbiter({
    clock,
    onHold: () => calls.hold++,
    onHoldRelease: () => calls.release++,
    isTurnInProgress: () => turn,
    isScrolled: () => scrolled,
    ...overrides,
  });
  return {
    arbiter,
    clock,
    calls,
    setTurn: (v) => (turn = v),
    setScrolled: (v) => (scrolled = v),
  };
}

// --- Delayed bridge state: no state yet means legacy behavior --------------
{
  const { arbiter, clock, calls } = makeArbiter();
  const doc = fakeDoc();
  arbiter.attach(doc);
  assert(!arbiter.enabled, "arbiter is inert until Swift sends reader-controls state");
  assert(!doc.documentElement.classList.contains(IMMERSIVE_BROWSE_CLASS), "no selection lock before state");
  doc.fire("touchstart", { touches: touch(100, 100) });
  clock.advance(HOLD_DELAY_MS + 50);
  const end = doc.fire("touchend", { changedTouches: touch(100, 100) });
  assert(calls.hold === 0 && !end.defaultPrevented, "pre-state hold falls through to native selection");

  // State arriving mid-contact must not retroactively consume that contact.
  doc.fire("touchstart", { touches: touch(100, 100) });
  arbiter.setState({ immersive: true, selectionMode: false });
  clock.advance(HOLD_DELAY_MS + 50);
  const end2 = doc.fire("touchend", { changedTouches: touch(100, 100) });
  assert(calls.hold === 0 && !end2.defaultPrevented, "late state does not hijack an in-flight contact");
  assert(doc.documentElement.classList.contains(IMMERSIVE_BROWSE_CLASS), "late state applies selection lock");
}

// --- Consumed hold: reveal once, own the release, no click/dblclick ---------
{
  const { arbiter, clock, calls } = makeArbiter();
  arbiter.setState({ immersive: true, selectionMode: false });
  const doc = fakeDoc();
  arbiter.attach(doc);
  arbiter.attach(doc);
  assert(doc.listenerCount("touchstart") === 1, "attaching the same doc twice does not duplicate listeners");
  assert(doc.listener("touchstart")[0].capture, "touchstart is a capture listener (runs before paginator)");
  assert(doc.listener("touchmove")[0].passive === false, "touchmove can preventDefault after a hold");
  assert(doc.getElementById("inkamp-immersive-browse-style"), "selection-lock CSS injected into section doc");

  doc.fire("touchstart", { touches: touch(200, 300) });
  clock.advance(HOLD_DELAY_MS - 1);
  assert(calls.hold === 0, "no reveal before the hold delay");
  clock.advance(1);
  assert(calls.hold === 1, "hold reveals once at the delay");
  clock.advance(5000);
  assert(calls.hold === 1, "no duplicate hold callback");

  const move = doc.fire("touchmove", { touches: touch(240, 300) });
  assert(move.defaultPrevented && move.immediateStopped, "post-hold drag cannot turn the page");
  const end = doc.fire("touchend", { changedTouches: touch(240, 300) });
  assert(end.defaultPrevented, "hold release prevents synthetic click");
  assert(end.immediateStopped, "hold release never reaches paginator snap / selection handlers");
  assert(calls.release === 1, "release callback runs once (settles paginator in place)");
  const click = doc.fire("click", { clientX: 240, clientY: 300 });
  assert(click.immediateStopped && click.defaultPrevented, "stray click after hold is swallowed");
  const dbl = doc.fire("dblclick", { clientX: 240, clientY: 300 });
  assert(dbl.immediateStopped, "stray dblclick after hold cannot seek");

  // The next real contact is a normal tap again.
  doc.fire("touchstart", { touches: touch(10, 300) });
  const end2 = doc.fire("touchend", { changedTouches: touch(10, 300) });
  const click2 = doc.fire("click", { clientX: 10, clientY: 300 });
  assert(!end2.defaultPrevented && !click2.immediateStopped, "a new tap after a hold is never eaten");
  assert(calls.release === 1, "plain tap does not fire release");
}

// --- Movement: 5px click rule, 2-5px curl conflict, second finger ----------
{
  const { arbiter, clock, calls, setTurn } = makeArbiter();
  arbiter.setState({ immersive: true, selectionMode: false });
  const doc = fakeDoc();
  arbiter.attach(doc);

  doc.fire("touchstart", { touches: touch(100, 100) });
  doc.fire("touchmove", { touches: touch(104, 100) });
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 1, "4px jitter without a turn is still a hold");
  doc.fire("touchend", { changedTouches: touch(104, 100) });

  doc.fire("touchstart", { touches: touch(100, 100) });
  setTurn(true); // animator locked a curl at 2px
  const move = doc.fire("touchmove", { touches: touch(103, 100) });
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 1, "2-5px drift that started a curl stays a page turn");
  assert(!move.defaultPrevented, "curl drag is never blocked by the arbiter");
  setTurn(false);
  doc.fire("touchend", { changedTouches: touch(103, 100) });

  doc.fire("touchstart", { touches: touch(100, 100) });
  setTurn(true);
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 1, "turn in progress at the deadline cancels the hold");
  setTurn(false);
  doc.fire("touchend", { changedTouches: touch(100, 100) });

  doc.fire("touchstart", { touches: touch(100, 100) });
  doc.fire("touchmove", { touches: touch(106, 100) });
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 1, ">5px movement cancels the hold");
  doc.fire("touchend", { changedTouches: touch(106, 100) });

  doc.fire("touchstart", { touches: touch(100, 100) });
  doc.fire("touchstart", { touches: [...touch(100, 100), ...touch(300, 100)] });
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 1, "second finger cancels the hold");
  doc.fire("touchend", { changedTouches: touch(100, 100) });

  doc.fire("touchstart", { touches: touch(100, 100) });
  doc.fire("touchcancel", { changedTouches: touch(100, 100) });
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 1, "touchcancel cancels the hold");

  doc.fire("touchstart", { touches: touch(100, 100) });
  arbiter.cancelPending(); // page-flip / navigation
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 1, "navigation cancels a pending hold");
  doc.fire("touchend", { changedTouches: touch(100, 100) });

  const link = { closest: (sel) => (sel.includes("a[href]") ? {} : null) };
  doc.fire("touchstart", { touches: touch(100, 100), target: link });
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 1, "links keep native long-press");
  assert(clock.pending === 0, "no leaked timers");
}

// --- Continuous scroll: a hold reveals but never blocks native scrolling ---
{
  const { arbiter, clock, calls, setScrolled } = makeArbiter();
  arbiter.setState({ immersive: true, selectionMode: false });
  setScrolled(true);
  const doc = fakeDoc();
  arbiter.attach(doc);
  doc.fire("touchstart", { touches: touch(100, 100) });
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 1, "hold works in scrolled mode");
  const move = doc.fire("touchmove", { touches: touch(100, 160) });
  assert(!move.defaultPrevented, "scrolled mode keeps native scroll after a hold");
  doc.fire("touchend", { changedTouches: touch(100, 160) });
}

// --- Select Text mode and Classic bypass the arbiter entirely --------------
{
  const { arbiter, clock, calls } = makeArbiter();
  const doc = fakeDoc({ selection: { rangeCount: 0, isCollapsed: true, removeAllRanges() { this.cleared = true; } } });
  arbiter.attach(doc);
  arbiter.setState({ immersive: true, selectionMode: true });
  assert(!doc.documentElement.classList.contains(IMMERSIVE_BROWSE_CLASS), "Select Text restores native selection CSS");
  doc.fire("touchstart", { touches: touch(100, 100) });
  clock.advance(HOLD_DELAY_MS);
  const end = doc.fire("touchend", { changedTouches: touch(100, 100) });
  assert(calls.hold === 0 && !end.defaultPrevented, "Select Text long-press is native selection");

  arbiter.setState({ immersive: true, selectionMode: false });
  assert(doc.selection.cleared, "leaving Select Text clears stale selection");
  assert(doc.documentElement.classList.contains(IMMERSIVE_BROWSE_CLASS), "browse mode re-locks selection");

  doc.fire("touchstart", { touches: touch(100, 100) });
  arbiter.setState({ immersive: false, selectionMode: false });
  clock.advance(HOLD_DELAY_MS);
  const end2 = doc.fire("touchend", { changedTouches: touch(100, 100) });
  assert(calls.hold === 0 && !end2.defaultPrevented, "switching to Classic cancels an in-flight hold");
  assert(!doc.documentElement.classList.contains(IMMERSIVE_BROWSE_CLASS), "Classic keeps native long-press selection");
}

// --- Iframe lifecycle: unloaded section docs are released ------------------
{
  const { arbiter, clock, calls } = makeArbiter();
  arbiter.setState({ immersive: true, selectionMode: false });
  const doc = fakeDoc();
  arbiter.attach(doc);
  doc.fire("touchstart", { touches: touch(100, 100) });
  doc.defaultView = null; // section iframe torn down mid-hold
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 0, "hold on an unloaded section never fires");
  arbiter.setState({ immersive: true, selectionMode: false });
  assert(arbiter.attachedCount === 0, "unloaded docs are pruned");

  const doc2 = fakeDoc();
  arbiter.attach(doc2);
  arbiter.detach(doc2);
  assert(doc2.listenerCount("touchstart") === 0 && doc2.listenerCount("click") === 0, "detach removes listeners");
  arbiter.attach(doc2);
  doc2.fire("touchstart", { touches: touch(1, 1) });
  arbiter.detachAll();
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 0 && clock.pending === 0, "detachAll cancels pending hold timers");
}

// --- Lifecycle: removed iframes, pagehide, live spread docs, disposal -------
{
  const { arbiter, clock, calls } = makeArbiter();
  arbiter.setState({ immersive: true, selectionMode: false });

  // Removed <iframe> whose window object is still reachable (defaultView non-null).
  const removed = liveDoc();
  const removedWin = removed.defaultView;
  arbiter.attach(removed);
  assert(removedWin.count("pagehide") === 1 && removedWin.count("unload") === 1, "section window teardown is observed");
  removed.fire("touchstart", { touches: touch(100, 100) });
  removedWin.frameElement.isConnected = false;
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 0, "hold in a removed iframe (non-null defaultView) never fires");
  assert(arbiter.attachedCount === 0 && clock.pending === 0, "removed iframe is released and its timer cleared");
  assert(hasNoListeners(removed), "every section listener is removed");
  assert(removedWin.count("pagehide") === 0 && removedWin.count("unload") === 0, "window teardown listeners are removed");
  assert(!isLocked(removed) && !removed.getElementById("inkamp-immersive-browse-style"), "selection lock and CSS are removed");

  // No touch needed: a disconnected doc is pruned by the next attach.
  const idle = liveDoc();
  arbiter.attach(idle);
  idle.defaultView.frameElement.isConnected = false;
  const live = liveDoc();
  arbiter.attach(live);
  assert(arbiter.attachedCount === 1 && hasNoListeners(idle), "next section attach prunes a disconnected one");
  arbiter.detach(live);

  // pagehide releases the doc, including a consumed hold's swallow window.
  const hidden = liveDoc();
  arbiter.attach(hidden);
  hidden.fire("touchstart", { touches: touch(100, 100) });
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 1, "hold fires on a live section");
  hidden.fire("touchend", { changedTouches: touch(100, 100) });
  hidden.defaultView.fire("pagehide");
  assert(arbiter.attachedCount === 0 && hasNoListeners(hidden), "pagehide releases the section");
  const next = liveDoc();
  arbiter.attach(next);
  const click = next.fire("click", { clientX: 5, clientY: 5 });
  assert(!click.immediateStopped, "a released section's swallow window does not eat the next section's click");

  // Several live documents (spread) stay attached; only the gone one is pruned.
  const left = liveDoc();
  const right = liveDoc();
  const gone = liveDoc();
  for (const d of [left, right, gone]) arbiter.attach(d);
  gone.defaultView.frameElement.isConnected = false;
  arbiter.setState({ immersive: true, selectionMode: false });
  assert(arbiter.attachedCount === 3, "next, left, right stay attached");
  assert(isLocked(left) && isLocked(right) && hasNoListeners(gone), "live docs keep the lock; gone doc is released");

  const stale = liveDoc();
  stale.defaultView.frameElement.isConnected = false;
  arbiter.attach(stale);
  assert(hasNoListeners(stale) && arbiter.attachedCount === 3, "an already-removed doc is never attached");

  // Reader teardown releases everything and returns to the inert, pre-state mode.
  left.fire("touchstart", { touches: touch(100, 100) });
  arbiter.dispose();
  clock.advance(HOLD_DELAY_MS);
  assert(calls.hold === 1 && clock.pending === 0, "dispose cancels a pending hold");
  assert(arbiter.attachedCount === 0 && !arbiter.enabled, "dispose releases all docs and state");
  for (const d of [next, left, right]) {
    assert(hasNoListeners(d) && !isLocked(d) && d.defaultView.count("pagehide") === 0, "dispose removes listeners and locks");
  }
}

// --- Startup: Swift's pending controls state ---------------------------------
{
  const G = PENDING_READER_CONTROLS_GLOBAL;
  assert(G === "inkampPendingReaderControls", "global name matches ReaderCommsBridge.pendingReaderControlsGlobal");
  assert(pendingReaderControls({}) === null, "no pending state: stay inert (legacy, macOS, unloaded settings)");
  assert(pendingReaderControls(undefined) === null, "no window: inert");
  assert(pendingReaderControls({ [G]: { immersive: "yes" } }) === null, "malformed state is ignored");
  const pending = pendingReaderControls({ [G]: { immersive: true } });
  assert(pending.immersive === true && pending.selectionMode === false, "selection mode defaults off");

  // FoliateManager applies pending state in its constructor, before open():
  // the first section therefore attaches already locked and the first hold works.
  const { arbiter, clock, calls } = makeArbiter();
  arbiter.setState(pending);
  const first = liveDoc();
  arbiter.attach(first);
  assert(isLocked(first), "first section attaches with the selection lock (no native selection window)");
  first.fire("touchstart", { touches: touch(100, 100) });
  clock.advance(HOLD_DELAY_MS);
  const end = first.fire("touchend", { changedTouches: touch(100, 100) });
  assert(calls.hold === 1 && end.defaultPrevented, "first long-press on the first page reveals chrome");

  // Classic pending state keeps native long-press from the start.
  const classic = makeArbiter();
  classic.arbiter.setState(pendingReaderControls({ [G]: { immersive: false, selectionMode: false } }));
  const cdoc = liveDoc();
  classic.arbiter.attach(cdoc);
  cdoc.fire("touchstart", { touches: touch(100, 100) });
  classic.clock.advance(HOLD_DELAY_MS);
  assert(!isLocked(cdoc) && classic.calls.hold === 0, "Classic pending state never locks selection");

  // Recovery: the fresh page's document-start state never resumes Select Text.
  const recovered = pendingReaderControls({ [G]: { immersive: true, selectionMode: false } });
  const fresh = makeArbiter();
  fresh.arbiter.setState(recovered);
  assert(fresh.arbiter.enabled, "recovered WebView starts in immersive browse");
}

// --- Tap router: margins turn immediately, center dismisses, dbltap seeks ---
function makeRouter({ audio = true, zone = () => "center" } = {}) {
  const clock = fakeClock();
  const calls = { margin: [], center: 0, seek: 0 };
  const router = new ReaderTapRouter({
    clock,
    hasAudioNarration: () => audio,
    isTurnActive: () => false,
    isTurnIdle: () => true,
    hasSelection: () => false,
    getZone: zone,
    onMargin: (z) => calls.margin.push(z),
    onCenter: () => calls.center++,
    onSeek: () => calls.seek++,
  });
  return { router, clock, calls };
}

{
  const { router, calls } = makeRouter({ zone: (e) => (e.clientX < 50 ? "left" : "right") });
  const doc = fakeDoc();
  for (let i = 0; i < 4; i++) router.click({ clientX: 400 }, doc);
  router.click({ clientX: 10 }, doc);
  assert(calls.margin.join(",") === "right,right,right,right,left", "rapid margin taps each turn immediately");
  assert(calls.center === 0 && calls.seek === 0, "margin taps never toggle chrome or seek");
}

{
  const { router, clock, calls } = makeRouter();
  const doc = fakeDoc();
  router.click({ clientX: 200 }, doc);
  assert(calls.center === 0, "center tap waits for double-tap window with narration");
  clock.advance(150);
  assert(calls.center === 1 && calls.seek === 0, "single center tap dismisses/toggles, never seeks");

  router.click({ clientX: 200 }, doc);
  router.click({ clientX: 200 }, doc);
  router.dblclick({ clientX: 200 }, doc, 3);
  clock.advance(500);
  assert(calls.seek === 1 && calls.center === 1, "double-tap seeks without toggling chrome");
}

{
  const { router, calls } = makeRouter({ audio: false });
  router.click({ clientX: 200 }, fakeDoc());
  assert(calls.center === 1, "pure ebook center tap reports immediately");
}

// --- Double-tap seek target with and without native selection -------------
{
  const span = { nodeType: 1, id: "f012" };
  const textInSpan = { nodeType: 3, parentNode: span };
  const selRange = { startContainer: textInSpan };
  const withSel = fakeDoc({ selection: { rangeCount: 1, isCollapsed: false, getRangeAt: () => selRange } });
  const a = resolveSeekRange(withSel, { clientX: 5, clientY: 6, target: span });
  assert(a.range === selRange, "legacy path: native double-tap selection wins");

  const text = { nodeType: 3, parentNode: span, data: "Call me Ishmael." };
  const caretRange = { startContainer: text, startOffset: 3 };
  const rect = (left, top, right, bottom) => ({ left, top, right, bottom, width: right - left });
  const glyph = rect(0, 0, 12, 20);
  const everyGlyph = () => [glyph];
  const noSelection = { rangeCount: 0, isCollapsed: true };
  const locked = (opts) => {
    const d = fakeDoc(opts);
    d.documentElement.classList.add(IMMERSIVE_BROWSE_CLASS);
    return d;
  };

  // Caret at offset 3 sits between "l"(2) and "l"(3); only char 2 is under the finger.
  const b = locked({ selection: noSelection, caret: caretRange, charRects: (i) => (i === 2 ? [glyph] : []) });
  const bRes = resolveSeekRange(b, { clientX: 5, clientY: 6, target: span });
  assert(bRes.range === caretRange, "immersive path: hit-test caret on text at the tap point");
  assert(bRes.range.startContainer.parentNode === a.range.startContainer.parentNode, "same fragment as legacy selection");
  assert(b.caretCalls[0].lifted, "hit-test runs with selection lock lifted");
  assert(b.documentElement.classList.contains(IMMERSIVE_BROWSE_CLASS), "selection lock restored after hit-test");

  // Line wrap: "p"(3) ends line 1 at the right edge, "a"(4) starts line 2 at the
  // left edge. Their union box covers (50, 15); neither glyph does.
  const wrapped = { nodeType: 3, parentNode: span, data: "wraparound" };
  const wrapRects = (i) => (i === 3 ? [rect(90, 0, 100, 20)] : i === 4 ? [rect(0, 20, 10, 40)] : []);
  const wrap = locked({ selection: noSelection, caret: { startContainer: wrapped, startOffset: 4 }, charRects: wrapRects });
  assert(resolveSeekRange(wrap, { clientX: 50, clientY: 15, target: span }) === null, "locked: blank gap inside a line-wrap union does not seek");
  assert(resolveSeekRange(wrap, { clientX: 95, clientY: 10, target: span }) !== null, "locked: same wrapped text seeks on the glyph itself");
  const split = locked({
    selection: noSelection,
    caret: { startContainer: wrapped, startOffset: 4 },
    charRects: (i) => (i === 3 ? [rect(90, 0, 100, 20), rect(0, 20, 10, 40)] : []),
  });
  assert(resolveSeekRange(split, { clientX: 50, clientY: 15, target: span }) === null, "locked: one glyph split across fragments only hits its own rects");

  // Whitespace glyph: caret after the space in "a b"; the space's rect is under the finger.
  const spaced = { nodeType: 3, parentNode: span, data: "a b" };
  const onSpace = locked({ selection: noSelection, caret: { startContainer: spaced, startOffset: 2 }, charRects: (i) => (i === 1 ? [glyph] : []) });
  assert(resolveSeekRange(onSpace, { clientX: 5, clientY: 6, target: span }) === null, "locked: whitespace glyph inside text does not seek");

  // Classic / macOS / Select Text (unlocked): exactly the legacy rule.
  const unlocked = fakeDoc({ selection: noSelection, caret: caretRange, charRects: everyGlyph });
  assert(resolveSeekRange(unlocked, { clientX: 5, clientY: 6, target: span }) === null, "unlocked, no selection: no seek");
  assert(unlocked.caretCalls.length === 0, "unlocked never hit-tests");
  const collapsed = { startContainer: text };
  const caretSel = fakeDoc({ selection: { rangeCount: 1, isCollapsed: true, getRangeAt: () => collapsed } });
  assert(resolveSeekRange(caretSel, { target: span }).range === collapsed, "unlocked collapsed range still seeks (legacy)");
  assert(resolveSeekRange(fakeDoc({ selection: null }), { target: span }) === null, "unlocked, no selection object: no seek");

  // Locked: no seeks from images, whitespace, or points beside the text.
  const img = { nodeType: 1, tagName: "IMG" };
  const onImage = locked({ selection: noSelection, caret: { startContainer: img, startOffset: 0 }, charRects: everyGlyph });
  assert(resolveSeekRange(onImage, { clientX: 5, clientY: 6, target: img }) === null, "locked: image tap does not seek");
  const ws = { nodeType: 3, parentNode: span, data: "\n   " };
  const onWhitespace = locked({ selection: noSelection, caret: { startContainer: ws, startOffset: 1 }, charRects: everyGlyph });
  assert(resolveSeekRange(onWhitespace, { clientX: 5, clientY: 6, target: span }) === null, "locked: whitespace node does not seek");
  const far = locked({ selection: noSelection, caret: caretRange, charRects: everyGlyph });
  assert(resolveSeekRange(far, { clientX: 5, clientY: 300, target: span }) === null, "locked: nearest caret far from the tap does not seek");
  assert(far.documentElement.classList.contains(IMMERSIVE_BROWSE_CLASS), "lock restored after a miss");
  const noCaret = locked({ selection: noSelection, caret: null });
  assert(resolveSeekRange(noCaret, { clientX: 5, clientY: 6, target: span }) === null, "locked: no caret → no element fallback");

  assert(anchorFromCFI("epubcfi(/6/8[ch03]!/4/2[f012]/1:4)") === "f012", "anchor is deepest id in CFI");
  assert(anchorFromCFI("epubcfi(/6/8!/4/2/1:4)") === null, "no id → no anchor");
}

console.log("reader-gestures-selfcheck: ok");
