/**
 * Per-contact gesture arbitration for immersive reader controls (iOS touch).
 *
 * The hold arbiter registers capture-phase listeners on each section document,
 * ahead of Foliate's paginator and FoliateManager/BookmarkManager handlers, so a
 * recognized long-press owns its contact: no page turn, selection, highlight
 * edit, seek, or synthetic click/dblclick. Everything else passes through
 * untouched. Native selection is prevented up front with an iOS-only CSS lock
 * while browsing; Select Text mode and Classic remove the lock.
 */

export const HOLD_DELAY_MS = 500;
/** Same 5px rule FoliateManager uses to tell taps from swipes (dist² > 25). */
export const HOLD_MOVE_TOLERANCE_PX = 5;
/** Safety cap for swallowing the held contact's synthetic click/dblclick. */
export const HOLD_RELEASE_SUPPRESS_MS = 1000;
export const IMMERSIVE_BROWSE_CLASS = "inkamp-immersive-browse";
const STYLE_ID = "inkamp-immersive-browse-style";
/**
 * Swift writes `{immersive, selectionMode}` here (document-start script and
 * every later push) so a FoliateManager constructed afterwards can apply it
 * before the first section attaches.
 */
export const PENDING_READER_CONTROLS_GLOBAL = "inkampPendingReaderControls";

/** Valid pending controls state on `global`, or null (arbiter stays inert). */
export function pendingReaderControls(global) {
  const state = global?.[PENDING_READER_CONTROLS_GLOBAL];
  if (!state || typeof state !== "object" || typeof state.immersive !== "boolean") return null;
  return { immersive: state.immersive, selectionMode: state.selectionMode === true };
}

/** Targets that keep their native long-press (link previews, form editing). */
const INTERACTIVE_SELECTOR =
  "a[href], button, input, textarea, select, label, [contenteditable]:not([contenteditable='false'])";

export const IMMERSIVE_BROWSE_CSS = `
html.${IMMERSIVE_BROWSE_CLASS},
html.${IMMERSIVE_BROWSE_CLASS} body,
html.${IMMERSIVE_BROWSE_CLASS} body * {
  -webkit-user-select: none !important;
  user-select: none !important;
  -webkit-touch-callout: none !important;
}
html.${IMMERSIVE_BROWSE_CLASS} :is(input, textarea, select, [contenteditable]) {
  -webkit-user-select: text !important;
  user-select: text !important;
}
html.${IMMERSIVE_BROWSE_CLASS} a[href] {
  -webkit-touch-callout: default !important;
}
`;

const defaultClock = {
  setTimeout: (fn, ms) => setTimeout(fn, ms),
  clearTimeout: (id) => clearTimeout(id),
  now: () => Date.now(),
};

/** Section document whose iframe was unloaded or removed from the reader. */
function isGone(doc) {
  const win = doc.defaultView;
  if (!win) return true;
  try {
    return win.frameElement != null && win.frameElement.isConnected === false;
  } catch {
    return false;
  }
}

function point(event) {
  const t = event.touches?.[0] ?? event.changedTouches?.[0];
  return t ? { x: t.screenX ?? t.clientX, y: t.screenY ?? t.clientY } : null;
}

export class ReaderHoldArbiter {
  #clock;
  #onHold;
  #onHoldRelease;
  #isTurnInProgress;
  #isScrolled;
  // null until Swift sends state, so a delayed bridge keeps legacy behavior.
  #immersive = null;
  #selectionMode = false;
  #docs = new Map();
  #contact = null;
  #suppress = null;

  constructor({
    clock = defaultClock,
    onHold = () => {},
    onHoldRelease = () => {},
    isTurnInProgress = () => false,
    isScrolled = () => false,
  } = {}) {
    this.#clock = clock;
    this.#onHold = onHold;
    this.#onHoldRelease = onHoldRelease;
    this.#isTurnInProgress = isTurnInProgress;
    this.#isScrolled = isScrolled;
  }

  get enabled() {
    return this.#immersive === true && !this.#selectionMode;
  }

  get attachedCount() {
    return this.#docs.size;
  }

  setState({ immersive, selectionMode }) {
    const wasSelecting = this.#selectionMode;
    this.#immersive = !!immersive;
    this.#selectionMode = !!selectionMode;
    if (!this.enabled) this.cancelPending();
    this.#prune();
    for (const doc of this.#docs.keys()) {
      this.#applyLock(doc);
      if (wasSelecting && !this.#selectionMode) {
        try {
          doc.getSelection?.()?.removeAllRanges?.();
        } catch {
          /* detached doc */
        }
      }
    }
  }

  attach(doc) {
    if (!doc?.addEventListener || this.#docs.has(doc)) return;
    this.#prune();
    if (isGone(doc)) return;
    const capture = { capture: true };
    const handlers = {
      touchstart: [(e) => this.#touchStart(e, doc), { capture: true, passive: true }],
      touchmove: [(e) => this.#touchMove(e), { capture: true, passive: false }],
      touchend: [(e) => this.#touchEnd(e, doc), { capture: true, passive: false }],
      touchcancel: [(e) => this.#touchCancel(e, doc), { capture: true, passive: true }],
      click: [(e) => this.#swallow(e), capture],
      dblclick: [(e) => this.#swallow(e), capture],
      contextmenu: [(e) => this.#swallow(e), capture],
    };
    for (const [type, [fn, opts]] of Object.entries(handlers)) {
      doc.addEventListener(type, fn, opts);
    }
    // Foliate replaces the section iframe; its window unloads with it.
    const win = doc.defaultView;
    const onGone = () => this.detach(doc);
    win?.addEventListener?.("pagehide", onGone);
    win?.addEventListener?.("unload", onGone);
    this.#docs.set(doc, { handlers, win, onGone });
    this.#ensureStyle(doc);
    this.#applyLock(doc);
  }

  /** Removes listeners, the selection lock, and any contact owned by `doc`. */
  detach(doc) {
    const entry = this.#docs.get(doc);
    if (!entry) return;
    for (const [type, [fn, opts]] of Object.entries(entry.handlers)) {
      doc.removeEventListener?.(type, fn, opts);
    }
    entry.win?.removeEventListener?.("pagehide", entry.onGone);
    entry.win?.removeEventListener?.("unload", entry.onGone);
    this.#docs.delete(doc);
    if (this.#contact?.doc === doc) this.#clearContact();
    if (this.#suppress?.doc === doc) this.#suppress = null;
    try {
      doc.documentElement?.classList?.remove(IMMERSIVE_BROWSE_CLASS);
      doc.getElementById?.(STYLE_ID)?.remove?.();
    } catch {
      /* document already torn down */
    }
  }

  detachAll() {
    for (const doc of [...this.#docs.keys()]) this.detach(doc);
    this.#clearContact();
    this.#suppress = null;
  }

  /** Reader teardown: release every document and return to the inert state. */
  dispose() {
    this.detachAll();
    this.#immersive = null;
    this.#selectionMode = false;
  }

  /** Navigation, page flip, or mode change: drop a not-yet-recognized hold. */
  cancelPending() {
    if (this.#contact && !this.#contact.consumed) this.#clearContact();
  }

  #prune() {
    for (const doc of [...this.#docs.keys()]) {
      if (isGone(doc)) this.detach(doc);
    }
  }

  #ensureStyle(doc) {
    try {
      if (doc.getElementById?.(STYLE_ID)) return;
      const style = doc.createElement("style");
      style.id = STYLE_ID;
      style.textContent = IMMERSIVE_BROWSE_CSS;
      (doc.head || doc.documentElement)?.appendChild(style);
    } catch {
      /* non-HTML section */
    }
  }

  #applyLock(doc) {
    doc.documentElement?.classList?.toggle(IMMERSIVE_BROWSE_CLASS, this.enabled);
  }

  #clearContact() {
    if (this.#contact?.timer != null) this.#clock.clearTimeout(this.#contact.timer);
    this.#contact = null;
  }

  #touchStart(event, doc) {
    // A new contact ends any leftover swallow window from the previous hold.
    this.#suppress = null;
    const touches = event.touches?.length ?? 0;
    if (this.#contact) {
      if (!this.#contact.consumed && touches > 1) this.#clearContact();
      return;
    }
    if (!this.enabled || touches !== 1) return;
    if (event.target?.closest?.(INTERACTIVE_SELECTOR)) return;
    const start = point(event);
    if (!start) return;
    const contact = { doc, start, consumed: false, timer: null };
    contact.timer = this.#clock.setTimeout(() => this.#fire(contact), HOLD_DELAY_MS);
    this.#contact = contact;
  }

  #fire(contact) {
    if (this.#contact !== contact) return;
    contact.timer = null;
    if (isGone(contact.doc)) {
      this.detach(contact.doc);
      return;
    }
    const selection = contact.doc.getSelection?.();
    if (
      !this.enabled
      || this.#isTurnInProgress()
      || (selection && !selection.isCollapsed)
    ) {
      this.#clearContact();
      return;
    }
    contact.consumed = true;
    this.#onHold({ doc: contact.doc });
  }

  #touchMove(event) {
    const contact = this.#contact;
    if (!contact) return;
    if (contact.consumed) {
      if (this.#isScrolled()) return;
      event.preventDefault();
      event.stopImmediatePropagation();
      return;
    }
    if ((event.touches?.length ?? 1) > 1 || this.#isTurnInProgress()) {
      this.#clearContact();
      return;
    }
    const p = point(event);
    if (!p) return;
    const dx = p.x - contact.start.x;
    const dy = p.y - contact.start.y;
    if (dx * dx + dy * dy > HOLD_MOVE_TOLERANCE_PX * HOLD_MOVE_TOLERANCE_PX) this.#clearContact();
  }

  #touchEnd(event, doc) {
    const contact = this.#contact;
    if (!contact) return;
    if (!contact.consumed) {
      this.#clearContact();
      return;
    }
    event.preventDefault();
    event.stopImmediatePropagation();
    this.#contact = null;
    this.#suppress = { doc, until: this.#clock.now() + HOLD_RELEASE_SUPPRESS_MS };
    this.#onHoldRelease({ doc });
  }

  #touchCancel(event, doc) {
    const contact = this.#contact;
    if (!contact) return;
    this.#clearContact();
    if (contact.consumed) this.#onHoldRelease({ doc });
  }

  #swallow(event) {
    const held = this.#contact?.consumed;
    const suppressing = this.#suppress && this.#clock.now() <= this.#suppress.until;
    if (!held && !suppressing) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }
}

/**
 * Click / dblclick routing shared by every section document. Margin taps turn
 * immediately; with narration a center tap waits one double-tap window so a
 * double-tap seeks instead of toggling chrome.
 */
export class ReaderTapRouter {
  #clock;
  #opts;
  #timer = null;

  constructor({
    clock = defaultClock,
    hasAudioNarration,
    isTurnActive,
    isTurnIdle,
    hasSelection,
    getZone,
    onMargin,
    onCenter,
    onSeek,
  }) {
    this.#clock = clock;
    this.#opts = { hasAudioNarration, isTurnActive, isTurnIdle, hasSelection, getZone, onMargin, onCenter, onSeek };
  }

  cancel() {
    if (this.#timer !== null) this.#clock.clearTimeout(this.#timer);
    this.#timer = null;
  }

  click(event, doc) {
    const o = this.#opts;
    // Active drag/curl gesture owns the interaction — never reveal chrome mid-turn.
    if (o.isTurnActive()) return;
    if (o.hasSelection(doc)) return;

    // Margin taps turn the page immediately (0ms latency) and never wait
    // on the double-click audio-seek timer, so rapid taps flip every page.
    const zone = o.getZone(event);
    if (zone === "left" || zone === "right") {
      this.cancel();
      o.onMargin(zone);
      return;
    }

    if (!o.hasAudioNarration()) {
      o.onCenter();
      return;
    }

    if (this.#timer !== null) {
      this.cancel();
      return;
    }

    this.#timer = this.#clock.setTimeout(() => {
      this.#timer = null;
      if (!o.isTurnIdle()) return;
      if (o.hasSelection(doc)) return;
      o.onCenter();
    }, 150);
  }

  dblclick(event, doc, sectionIndex) {
    this.cancel();
    this.#opts.onSeek(event, doc, sectionIndex);
  }
}

/**
 * Range under a double-tap for readaloud seek. Unlocked (Classic, macOS,
 * Select Text) this is exactly the legacy rule: WebKit's double-tap word
 * selection range, or nothing. Immersive browsing locks selection, so the tap
 * point is hit-tested instead (lock lifted for the probe) and only accepted
 * when it lands on visible text — never images or whitespace.
 */
export function resolveSeekRange(doc, event) {
  const selection = doc.getSelection?.() ?? null;
  const root = doc.documentElement;
  const locked = !!root?.classList?.contains(IMMERSIVE_BROWSE_CLASS);
  if (selection?.rangeCount > 0 && (!selection.isCollapsed || !locked)) {
    const range = selection.getRangeAt(0);
    if (range) return { range, selection };
  }
  if (!locked || typeof doc.caretRangeFromPoint !== "function") return null;

  root.classList.remove(IMMERSIVE_BROWSE_CLASS);
  try {
    const range = textCaretAtPoint(doc, event.clientX, event.clientY);
    return range ? { range, selection } : null;
  } catch {
    return null;
  } finally {
    root.classList.add(IMMERSIVE_BROWSE_CLASS);
  }
}

/**
 * The caret only counts when the finger is on a visible glyph next to it.
 * Each neighbouring character is hit-tested on its own client rects, so a tap
 * in the blank gap of a line wrap (between two separate rects) or on a
 * whitespace glyph never seeks.
 */
function textCaretAtPoint(doc, x, y) {
  const caret = doc.caretRangeFromPoint(x, y);
  const node = caret?.startContainer;
  if (node?.nodeType !== 3 || !node.data) return null;
  const probe = doc.createRange();
  for (const i of [caret.startOffset - 1, caret.startOffset]) {
    if (i < 0 || i >= node.data.length || /\s/.test(node.data[i])) continue;
    probe.setStart(node, i);
    probe.setEnd(node, i + 1);
    for (const r of probe.getClientRects()) {
      if (r.width > 0 && x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
        return caret;
      }
    }
  }
  return null;
}

/** Deepest non-numeric id assertion in a CFI (the media-overlay fragment). */
export function anchorFromCFI(cfi) {
  if (!cfi) return null;
  const matches = [...cfi.matchAll(/\[([^\]]+)\]/g)];
  for (let i = matches.length - 1; i >= 0; i--) {
    const id = matches[i][1];
    if (!id.match(/^\d+$/) && !id.includes(";") && !id.includes(",")) return id;
  }
  return null;
}
