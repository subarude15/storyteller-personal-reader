/**
 * Owns page-turn *appearance* only. Foliate's paginator still owns which page
 * is shown and fires PageFlipped / Relocated. Do not put navigation logic here.
 *
 * Curl visual model (restrained peel):
 * - native WKWebView snapshot as a mostly-flat foreground layer
 * - clip-path reveals less of that snapshot as the finger moves
 * - solid underlay hides Foliate's intermediate scroll during the drag
 * - narrow fold/shadow strip at the free edge (not a full-page 3D card spin)
 *
 * Curl is bypassed when:
 * - Reduce Motion is effective
 * - scrolling mode is active
 * - read-aloud / page-follow is active
 * - native snapshot is unavailable / late / failed (falls back to slide for
 *   that gesture — never paints an opaque blank sheet)
 *
 * Instant may temporarily strip `animated`. Slide restores whatever the
 * renderer had before this animator first managed it. Curl also strips
 * `animated` so the underlying snap is immediate under the overlay.
 */

import { debugLog } from "./DebugConfig.js";

const VALID_STYLES = new Set(["slide", "curl", "instant"]);
const OVERLAY_ID = "inkamp-page-curl-overlay";
const STYLE_ID = "inkamp-page-curl-styles";
const COMPLETE_MS = 180;
const CANCEL_MS = 200;
/** How long to wait for a native snapshot before giving up on curl. */
const SNAPSHOT_TIMEOUT_MS = 220;
/** Fold strip as a fraction of viewport width (clamped 8–18%). */
const FOLD_FRAC_MIN = 0.08;
const FOLD_FRAC_MAX = 0.18;

const clamp01 = (value) => Math.max(0, Math.min(1, value));

/**
 * Document that originated a touch. Prefer the section document the listener
 * was attached to (event.currentTarget) over getContents()[0], which can lag
 * around section boundaries.
 *
 * @param {Event} event
 * @param {Document} [rootDocument] reader chrome document (not an EPUB section)
 * @returns {Document|null}
 */
export function docFromTouchEvent(event, rootDocument = globalThis.document) {
  const current = event?.currentTarget;
  // observeDocument attaches listeners directly on the section Document.
  if (current?.nodeType === 9) return current;
  const fromCurrent = current?.ownerDocument;
  if (fromCurrent && fromCurrent !== rootDocument) return fromCurrent;
  const fromTarget = event?.target?.ownerDocument;
  if (fromTarget && fromTarget !== rootDocument) return fromTarget;
  return null;
}

/**
 * Pure peel geometry for the restrained page-curl visual.
 * Progress maps linearly to the free-edge position so the clip tracks the finger.
 * The snapshot sheet itself is never rotated/skewed — only clipped.
 *
 * @param {number} progress 0..1
 * @param {number} width viewport width in CSS px
 * @param {boolean} [fromRight=true] free edge on the right (LTR forward)
 */
export function peelVisualState(progress, width, fromRight = true) {
  const p = clamp01(progress);
  const w = Math.max(1, width || 1);
  const remain = 1 - p;
  // Free edge x from the left: RTL/backward mirrors via fromRight=false.
  const edgeX = fromRight ? w * remain : w * p;
  const foldFrac = Math.min(FOLD_FRAC_MAX, Math.max(FOLD_FRAC_MIN, FOLD_FRAC_MIN + p * 0.1));
  const foldWidth = w * foldFrac;
  const peeledPct = p * 100;
  // inset(top, right, bottom, left) — peel away from the free edge.
  const clipPath = fromRight
    ? `inset(0 ${peeledPct}% 0 0)`
    : `inset(0 0 0 ${peeledPct}%)`;

  const foldLeft = fromRight ? Math.max(0, edgeX - foldWidth) : edgeX;
  const backWidth = foldWidth * 0.55;
  const backLeft = fromRight ? edgeX : Math.max(0, edgeX - backWidth);
  const shadowWidth = foldWidth * 0.75;
  const shadowLeft = fromRight ? Math.max(0, edgeX - shadowWidth * 0.15) : Math.max(0, edgeX - shadowWidth * 0.85);

  // Local fold-only rotation — kept small so text in the flat region stays readable.
  const foldRotateY = (fromRight ? -1 : 1) * (5 + p * 9);
  const foldVisible = p > 0.02 && p < 0.98;
  const foldOpacity = foldVisible ? Math.min(0.95, 0.35 + p * 0.45) : 0;
  const backOpacity = foldVisible ? Math.min(0.55, 0.12 + p * 0.4) : 0;
  const shadowOpacity = foldVisible ? Math.min(0.45, 0.1 + p * 0.35) : 0;

  return {
    progress: p,
    remain,
    edgeX,
    peeledPct,
    clipPath,
    foldWidth,
    foldLeft,
    foldRotateY,
    foldOrigin: fromRight ? "right center" : "left center",
    foldTransform: `perspective(1100px) rotateY(${foldRotateY}deg)`,
    foldOpacity,
    backWidth,
    backLeft,
    backOpacity,
    shadowWidth,
    shadowLeft,
    shadowOpacity,
    // Contract for tests / callers: the flat sheet must stay undistorted.
    sheetTranslateX: 0,
    sheetRotateY: 0,
    sheetSkewY: 0,
    sheetScaleX: 1,
  };
}

export default class PageTurnAnimator {
  #style = "slide";
  #reduceMotion = false;
  #readAloudActive = false;
  #originalAnimated = new WeakMap();
  #renderer = null;
  #host = null;

  #phase = "idle"; // idle | pending | curling | completing | cancelling
  #gesture = null;
  #overlay = null;
  #underlay = null;
  #sheet = null;
  #shadow = null;
  #fold = null;
  #back = null;
  #progress = 0;
  #raf = 0;
  #pendingProgress = null;
  #animToken = 0;
  #fallbackThisGesture = false;
  #pageFlipSeen = false;
  #awaitingSnap = false;
  #bound = false;

  /** Monotonic id for native snapshot requests; bumped to invalidate in-flight. */
  #snapshotRequestId = 0;
  /** Request id we currently expect a reply for (0 = none). */
  #pendingSnapshotRequestId = 0;
  /** data: URL from the latest accepted native snapshot, or null. */
  #pendingSnapshotUrl = null;
  /** True when the current request failed, timed out, or bridge is missing. */
  #snapshotFailed = false;
  #snapshotTimer = 0;

  #onTouchStart = (event) => this.#handleTouchStart(event);
  #onTouchEnd = (event) => this.#handleTouchEnd(event);
  #onScroll = () => this.#handleScroll();
  #onPageFlip = () => this.#handlePageFlip();
  #onRelocate = (event) => this.#handleRelocate(event);
  #onOrientation = () => this.#handleOrientationChange();
  #onReduceMotionChange = (event) => {
    this.setReduceMotion(!!event?.matches);
  };

  setStyle(style) {
    this.#style = VALID_STYLES.has(style) ? style : "slide";
    if (this.effectiveStyle !== "curl" && this.#phase !== "idle") {
      this.cancel({ reason: "style-change" });
    }
  }

  setReduceMotion(enabled) {
    this.#reduceMotion = !!enabled;
    if (this.#reduceMotion && this.#phase !== "idle") {
      this.cancel({ reason: "reduce-motion", durationMs: 0 });
    }
  }

  /** Called when read-aloud highlight / page-follow becomes active or inactive. */
  setReadAloudActive(active) {
    const next = !!active;
    if (next === this.#readAloudActive) return;
    this.#readAloudActive = next;
    if (next && this.#phase !== "idle") {
      // Drop the overlay immediately so narration page-follow is never blocked.
      this.cancel({ reason: "read-aloud", durationMs: 0 });
    }
  }

  get style() {
    return this.#style;
  }

  get reduceMotion() {
    return this.#reduceMotion;
  }

  get readAloudActive() {
    return this.#readAloudActive;
  }

  get phase() {
    return this.#phase;
  }

  get progress() {
    return this.#progress;
  }

  /** Request id awaiting a native snapshot reply (0 when none). */
  get pendingSnapshotRequestId() {
    return this.#pendingSnapshotRequestId;
  }

  /**
   * Style used for appearance after reduceMotion / curl bypass.
   * Note: curl no longer falls back to slide at the style level; per-gesture
   * fallback happens when visual creation fails or read-aloud/scroll blocks it.
   */
  get effectiveStyle() {
    if (this.#reduceMotion) return "instant";
    return this.#style;
  }

  /** Whether a new manual curl may begin right now. */
  get canCurl() {
    if (this.effectiveStyle !== "curl") return false;
    if (this.#readAloudActive) return false;
    if (this.#renderer?.scrolled) return false;
    return true;
  }

  applyToRenderer(renderer) {
    if (
      !renderer?.removeAttribute
      || !renderer?.setAttribute
      || !renderer?.hasAttribute
    ) {
      return;
    }
    if (!this.#originalAnimated.has(renderer)) {
      this.#originalAnimated.set(renderer, renderer.hasAttribute("animated"));
    }
    // Instant and curl: no Foliate slide animation. Curl paints its own overlay;
    // underlying snap should be immediate to avoid flash when the overlay lifts.
    if (this.effectiveStyle === "instant" || this.effectiveStyle === "curl") {
      renderer.removeAttribute("animated");
      return;
    }
    if (this.#originalAnimated.get(renderer)) {
      renderer.setAttribute("animated", "");
    } else {
      renderer.removeAttribute("animated");
    }
  }

  /**
   * Bind to a Foliate paginator/renderer. Observes its public scroll / page-flip
   * / relocate events; touch listeners are also attached per-document via
   * observeDocument because iframe touches do not bubble to the host.
   */
  attach(renderer, host = null) {
    if (this.#renderer === renderer && this.#bound) {
      this.#host = host || this.#host;
      return;
    }
    this.detach();
    this.#renderer = renderer;
    this.#host = host || document.getElementById("reader-container") || document.body;
    if (!renderer) return;

    renderer.addEventListener("scroll", this.#onScroll);
    renderer.addEventListener("page-flip", this.#onPageFlip);
    renderer.addEventListener("relocate", this.#onRelocate);
    renderer.addEventListener("touchstart", this.#onTouchStart, { passive: true });
    renderer.addEventListener("touchend", this.#onTouchEnd, { passive: true });
    renderer.addEventListener("touchcancel", this.#onTouchEnd, { passive: true });
    window.addEventListener("orientationchange", this.#onOrientation);
    window.addEventListener("resize", this.#onOrientation);

    const motionQuery = globalThis.matchMedia?.("(prefers-reduced-motion: reduce)");
    if (motionQuery) {
      this.#reduceMotion = !!motionQuery.matches;
      motionQuery.addEventListener?.("change", this.#onReduceMotionChange);
      this.#motionQuery = motionQuery;
    }

    this.#ensureStyles();
    this.#bound = true;
  }

  #motionQuery = null;

  /** Observe touch lifecycle inside a section document (iframe). */
  observeDocument(doc) {
    if (!doc?.addEventListener) return;
    doc.addEventListener("touchstart", this.#onTouchStart, { passive: true });
    doc.addEventListener("touchend", this.#onTouchEnd, { passive: true });
    doc.addEventListener("touchcancel", this.#onTouchEnd, { passive: true });
  }

  detach() {
    if (this.#renderer && this.#bound) {
      this.#renderer.removeEventListener("scroll", this.#onScroll);
      this.#renderer.removeEventListener("page-flip", this.#onPageFlip);
      this.#renderer.removeEventListener("relocate", this.#onRelocate);
      this.#renderer.removeEventListener("touchstart", this.#onTouchStart);
      this.#renderer.removeEventListener("touchend", this.#onTouchEnd);
      this.#renderer.removeEventListener("touchcancel", this.#onTouchEnd);
    }
    globalThis.window?.removeEventListener?.("orientationchange", this.#onOrientation);
    globalThis.window?.removeEventListener?.("resize", this.#onOrientation);
    this.#motionQuery?.removeEventListener?.("change", this.#onReduceMotionChange);
    this.#motionQuery = null;
    this.#cleanupOverlay();
    this.#invalidateSnapshot("detach");
    this.#phase = "idle";
    this.#gesture = null;
    this.#renderer = null;
    this.#bound = false;
  }

  // --- Public lifecycle (also used by self-check) ---------------------------

  /**
   * Ask the native host for a WKWebView snapshot of the current page.
   * Returns the request id (tests use this to drive receiveNativeSnapshot).
   */
  beginSnapshotRequest() {
    return this.#requestNativeSnapshot();
  }

  /**
   * Native host delivers a snapshot (or null on failure). Stale request ids and
   * replies after the gesture ends are ignored.
   *
   * @param {number} requestId
   * @param {string|null|undefined} dataUrl
   */
  receiveNativeSnapshot(requestId, dataUrl) {
    // Accept only the currently outstanding request. Phase may still be idle for
    // a beat while touchstart arms the gesture, so do not require pending here.
    if (requestId !== this.#pendingSnapshotRequestId || requestId === 0) {
      debugLog("PageTurnAnimator", "reject stale snapshot", {
        requestId,
        expected: this.#pendingSnapshotRequestId,
      });
      return;
    }

    if (typeof dataUrl !== "string" || !dataUrl.startsWith("data:image/")) {
      debugLog("PageTurnAnimator", "native snapshot failed or empty", { requestId });
      this.#snapshotFailed = true;
      this.#pendingSnapshotUrl = null;
      if (this.#phase === "pending" && this.#gesture?.moved) {
        // Drag already started; abandon curl rather than show a blank sheet.
        this.#fallbackThisGesture = true;
        this.#resetGesture();
      }
      return;
    }

    this.#snapshotFailed = false;
    this.#pendingSnapshotUrl = dataUrl;
    debugLog("PageTurnAnimator", "native snapshot ready", {
      requestId,
      bytes: dataUrl.length,
    });

    // If the finger already moved, start the curl with the real page image now.
    if (this.#phase === "pending" && this.#gesture?.moved && !this.#overlay) {
      this.#beginFromPendingGesture();
    }
  }

  begin(context = {}) {
    if (!this.canCurl) {
      if (this.#readAloudActive) {
        debugLog("PageTurnAnimator", "curl bypass: read-aloud active");
      } else if (this.#renderer?.scrolled) {
        debugLog("PageTurnAnimator", "curl bypass: scrolling mode");
      } else if (this.#reduceMotion) {
        debugLog("PageTurnAnimator", "curl bypass: reduce motion");
      }
      return false;
    }
    if (this.#phase === "curling" || this.#phase === "completing" || this.#phase === "cancelling") {
      return false;
    }

    const width = context.width ?? this.#renderer?.size ?? 0;
    const height = context.height ?? this.#host?.clientHeight ?? 0;
    if (!width || !height) {
      debugLog("PageTurnAnimator", "curl fallback: missing viewport geometry");
      this.#fallbackThisGesture = true;
      return false;
    }

    const fromRight = context.fromRight !== false;
    const rtl = !!context.rtl;
    // Prefer an explicit sourceUrl (tests / late injection); else the pending
    // native snapshot. Never invent a JS page clone or paint a blank sheet.
    const sourceUrl = context.sourceUrl ?? this.#pendingSnapshotUrl ?? null;
    if (!sourceUrl) {
      debugLog("PageTurnAnimator", "curl fallback: no native snapshot image");
      this.#fallbackThisGesture = true;
      return false;
    }

    try {
      this.#mountOverlay({
        width,
        height,
        fromRight,
        sourceUrl,
        paperColor: context.paperColor ?? "#f7f3ea",
      });
    } catch (error) {
      debugLog("PageTurnAnimator", "curl fallback: visual-layer creation failed", error);
      this.#fallbackThisGesture = true;
      this.#cleanupOverlay();
      return false;
    }

    if (!this.#overlay) {
      debugLog("PageTurnAnimator", "curl fallback: overlay missing after mount");
      this.#fallbackThisGesture = true;
      return false;
    }

    this.#phase = "curling";
    this.#progress = 0;
    this.#pageFlipSeen = false;
    this.#awaitingSnap = false;
    this.#fallbackThisGesture = false;
    this.#gesture = {
      fromRight,
      rtl,
      width,
      height,
      startOffset: context.startOffset ?? this.#renderer?.start ?? 0,
      moved: true,
    };
    this.#applyVisual(0);
    debugLog("PageTurnAnimator", "curl begin", { fromRight, rtl, width, height });
    return true;
  }

  update(context = {}) {
    if (this.#phase !== "curling") return;
    const progress = clamp01(
      context.progress ?? this.#progressFromOffset(context.offset),
    );
    this.#progress = progress;
    this.#scheduleVisual(progress);
  }

  complete(context = {}) {
    if (this.#phase !== "curling" && this.#phase !== "pending") {
      return;
    }
    if (this.#phase === "pending" && !this.#overlay) {
      this.#resetGesture();
      return;
    }
    this.#phase = "completing";
    debugLog("PageTurnAnimator", "curl complete");
    const from = this.#progress;
    this.#animateProgress(from, 1, context.durationMs ?? COMPLETE_MS, () => {
      this.#cleanupOverlay();
      this.#resetGesture();
    });
  }

  cancel(context = {}) {
    if (this.#phase === "idle") return;
    const reason = context.reason ?? "cancel";
    if (this.#phase === "pending" && !this.#overlay) {
      debugLog("PageTurnAnimator", "curl cancel", reason);
      this.#resetGesture();
      return;
    }
    if (!this.#overlay) {
      debugLog("PageTurnAnimator", "curl cancel", reason);
      this.#resetGesture();
      return;
    }
    this.#phase = "cancelling";
    debugLog("PageTurnAnimator", "curl cancel", reason);
    const from = this.#progress;
    this.#animateProgress(from, 0, context.durationMs ?? CANCEL_MS, () => {
      this.#cleanupOverlay();
      this.#resetGesture();
    });
  }

  // --- Gesture observation (paginator remains source of truth) -------------

  #handleTouchStart(event) {
    if (!this.canCurl) return;
    if (this.#phase !== "idle") return;
    const touch = event.changedTouches?.[0];
    if (!touch) return;

    const renderer = this.#renderer;
    if (!renderer || renderer.scrolled) return;

    this.#fallbackThisGesture = false;
    this.#pageFlipSeen = false;
    this.#awaitingSnap = false;
    // Arm the gesture before requesting so a fast native reply is not rejected.
    this.#phase = "pending";
    this.#gesture = {
      startX: touch.screenX ?? touch.clientX,
      startY: touch.screenY ?? touch.clientY,
      startOffset: renderer.start, // paginator scroll — progress only
      fromRight: true,
      rtl: renderer.getAttribute?.("dir") === "rtl",
      width: renderer.size,
      height: this.#host?.clientHeight || renderer.getBoundingClientRect?.().height || 0,
      moved: false,
      // Touched section doc kept for paperColor under the snapshot only.
      doc: docFromTouchEvent(event) || this.#currentDoc(),
    };
    // Capture the current rendered page before the paginator scrolls.
    this.#requestNativeSnapshot();
  }

  #handleScroll() {
    if (this.#phase !== "pending" && this.#phase !== "curling") return;
    if (this.#fallbackThisGesture) return;
    const renderer = this.#renderer;
    const gesture = this.#gesture;
    if (!renderer || !gesture) return;
    if (renderer.scrolled) {
      this.cancel({ reason: "scrolling-mode" });
      return;
    }

    const delta = renderer.start - gesture.startOffset;
    if (!gesture.moved) {
      if (Math.abs(delta) < 1) return;
      gesture.moved = true;
      // Lock curl direction from the paginator's scroll delta.
      // Higher start ⇒ higher page index (forward in reading order) for both LTR and RTL.
      const goingForward = delta > 0;
      const rtl = renderer.getAttribute?.("dir") === "rtl";
      // LTR forward: curl from right; RTL forward: curl from left.
      gesture.fromRight = rtl ? !goingForward : goingForward;
      gesture.rtl = rtl;
      gesture.width = renderer.size;
      gesture.height = this.#host?.clientHeight || gesture.height;

      if (this.#snapshotFailed) {
        debugLog("PageTurnAnimator", "curl fallback: snapshot unavailable at drag start");
        this.#fallbackThisGesture = true;
        this.#phase = "idle";
        this.#gesture = null;
        return;
      }

      if (!this.#pendingSnapshotUrl) {
        // Snapshot still in flight — stay pending; receiveNativeSnapshot will begin.
        debugLog("PageTurnAnimator", "curl waiting for native snapshot");
        return;
      }

      this.#beginFromPendingGesture();
      if (this.#phase !== "curling") return;
    }

    if (this.#phase === "curling") {
      const progress = clamp01(Math.abs(delta) / Math.max(1, renderer.size));
      this.update({ progress });
    }
  }

  #handleTouchEnd() {
    if (this.#phase === "pending" && !this.#gesture?.moved) {
      // Tap / no drag — nothing to curl.
      this.#resetGesture();
      return;
    }
    if (this.#phase === "pending" && this.#gesture?.moved && !this.#overlay) {
      // Drag ended while still waiting on a snapshot — abandon curl; Foliate snaps.
      debugLog("PageTurnAnimator", "curl abandon: touch ended before snapshot");
      this.#fallbackThisGesture = true;
      this.#resetGesture();
      return;
    }
    if (this.#phase === "curling") {
      this.#awaitingSnap = true;
      // Paginator will snap, then emit page-flip (if page changed) and relocate.
      // A safety timeout covers cases where snap yields no relocate.
      const token = ++this.#animToken;
      setTimeout(() => {
        if (token !== this.#animToken) return;
        if (this.#phase === "curling" && this.#awaitingSnap) {
          if (this.#pageFlipSeen) this.complete();
          else this.cancel({ reason: "snap-timeout" });
        }
      }, 450);
    }
  }

  #handlePageFlip() {
    if (this.#phase !== "curling" && this.#phase !== "pending") return;
    this.#pageFlipSeen = true;
    if (this.#phase === "pending" && !this.#overlay) {
      // Flip happened before we could mount a curl sheet — let Foliate win.
      this.#resetGesture();
      return;
    }
    // Foliate has accepted the turn; finish the visual curl. The underlying
    // page is already (or immediately) at the destination because curl strips
    // `animated`, so removing the overlay after completion shows the new page.
    this.complete();
  }

  #handleRelocate(event) {
    const reason = event?.detail?.reason;
    if (reason !== "snap") return;
    if (this.#phase !== "curling" && !(this.#phase === "pending" && this.#awaitingSnap)) {
      return;
    }
    if (this.#pageFlipSeen) return; // complete() already running
    // Snap without page change ⇒ cancelled turn.
    this.cancel({ reason: "snap-cancel" });
  }

  #handleOrientationChange() {
    if (this.#phase === "idle") return;
    this.cancel({ reason: "orientation", durationMs: 0 });
  }

  // --- Native snapshot -----------------------------------------------------

  #requestNativeSnapshot() {
    this.#clearSnapshotTimer();
    const id = ++this.#snapshotRequestId;
    this.#pendingSnapshotRequestId = id;
    this.#pendingSnapshotUrl = null;
    this.#snapshotFailed = false;

    const handler = globalThis.window?.webkit?.messageHandlers?.RequestPageSnapshot;
    if (!handler?.postMessage) {
      this.#snapshotFailed = true;
      debugLog("PageTurnAnimator", "curl fallback: no RequestPageSnapshot bridge");
      return id;
    }

    try {
      handler.postMessage({ requestId: id });
    } catch (error) {
      this.#snapshotFailed = true;
      debugLog("PageTurnAnimator", "curl fallback: snapshot request failed", error);
      return id;
    }

    this.#snapshotTimer = setTimeout(() => {
      if (id !== this.#pendingSnapshotRequestId) return;
      if (this.#pendingSnapshotUrl) return;
      this.#snapshotFailed = true;
      debugLog("PageTurnAnimator", "curl fallback: native snapshot timeout", { requestId: id });
      if (this.#phase === "pending" && this.#gesture?.moved && !this.#overlay) {
        this.#fallbackThisGesture = true;
        this.#resetGesture();
      }
    }, SNAPSHOT_TIMEOUT_MS);

    return id;
  }

  #beginFromPendingGesture() {
    const gesture = this.#gesture;
    const sourceUrl = this.#pendingSnapshotUrl;
    if (!gesture || !sourceUrl) return;

    const started = this.begin({
      fromRight: gesture.fromRight,
      rtl: gesture.rtl,
      width: gesture.width,
      height: gesture.height,
      startOffset: gesture.startOffset,
      sourceUrl,
      paperColor: this.#paperColor(gesture.doc),
    });
    if (!started) {
      this.#fallbackThisGesture = true;
      this.#phase = "idle";
      this.#gesture = null;
      return;
    }

    const renderer = this.#renderer;
    if (renderer) {
      const progress = clamp01(
        Math.abs(renderer.start - gesture.startOffset) / Math.max(1, renderer.size || 1),
      );
      this.update({ progress });
    }
  }

  #invalidateSnapshot(reason) {
    this.#clearSnapshotTimer();
    // Bump so any in-flight native reply is rejected as stale.
    this.#snapshotRequestId += 1;
    this.#pendingSnapshotRequestId = 0;
    this.#pendingSnapshotUrl = null;
    this.#snapshotFailed = false;
    if (reason) debugLog("PageTurnAnimator", "snapshot invalidated", reason);
  }

  #clearSnapshotTimer() {
    if (this.#snapshotTimer) {
      clearTimeout(this.#snapshotTimer);
      this.#snapshotTimer = 0;
    }
  }

  // --- Visual layer (restrained peel) --------------------------------------

  #ensureStyles() {
    if (typeof document === "undefined") return;
    if (document.getElementById(STYLE_ID)) return;
    const style = document.createElement("style");
    style.id = STYLE_ID;
    style.textContent = `
      #${OVERLAY_ID} {
        position: absolute;
        inset: 0;
        z-index: 30;
        pointer-events: none;
        overflow: hidden;
        contain: layout style paint;
      }
      #${OVERLAY_ID} .inkamp-curl-underlay {
        position: absolute;
        inset: 0;
        z-index: 0;
        pointer-events: none;
      }
      #${OVERLAY_ID} .inkamp-curl-sheet {
        position: absolute;
        inset: 0;
        z-index: 1;
        width: 100%;
        height: 100%;
        will-change: clip-path;
        background-size: 100% 100%;
        background-repeat: no-repeat;
        background-position: left top;
        transform: none;
      }
      #${OVERLAY_ID} .inkamp-curl-back {
        position: absolute;
        top: 0;
        bottom: 0;
        z-index: 2;
        pointer-events: none;
        opacity: 0;
      }
      #${OVERLAY_ID} .inkamp-curl-fold {
        position: absolute;
        top: 0;
        bottom: 0;
        z-index: 3;
        pointer-events: none;
        opacity: 0;
        transform-style: preserve-3d;
        will-change: transform, left, opacity;
      }
      #${OVERLAY_ID} .inkamp-curl-shadow {
        position: absolute;
        top: 0;
        bottom: 0;
        z-index: 4;
        pointer-events: none;
        opacity: 0;
        filter: blur(5px);
      }
    `;
    document.head.appendChild(style);
  }

  #mountOverlay({ width, height, fromRight, sourceUrl, paperColor }) {
    this.#cleanupOverlay();
    const host = this.#host;
    if (!host) throw new Error("no host");
    if (!sourceUrl) throw new Error("no snapshot");

    const overlay = document.createElement("div");
    overlay.id = OVERLAY_ID;

    // Solid theme-colored cover so Foliate's intermediate scroll never shows
    // through the peel during the interactive drag.
    const underlay = document.createElement("div");
    underlay.className = "inkamp-curl-underlay";
    underlay.style.backgroundColor = paperColor;

    const sheet = document.createElement("div");
    sheet.className = "inkamp-curl-sheet";
    sheet.style.width = `${width}px`;
    sheet.style.height = `${height}px`;
    sheet.style.backgroundColor = paperColor;
    sheet.style.backgroundImage = `url("${sourceUrl}")`;
    sheet.style.transform = "none";

    const back = document.createElement("div");
    back.className = "inkamp-curl-back";
    back.style.background = fromRight
      ? `linear-gradient(270deg, ${paperColor}, rgba(0,0,0,0.14) 55%, rgba(0,0,0,0.05))`
      : `linear-gradient(90deg, ${paperColor}, rgba(0,0,0,0.14) 55%, rgba(0,0,0,0.05))`;

    const fold = document.createElement("div");
    fold.className = "inkamp-curl-fold";
    fold.style.background = fromRight
      ? "linear-gradient(270deg, rgba(255,255,255,0.0), rgba(255,255,255,0.28) 45%, rgba(0,0,0,0.10))"
      : "linear-gradient(90deg, rgba(255,255,255,0.0), rgba(255,255,255,0.28) 45%, rgba(0,0,0,0.10))";

    const shadow = document.createElement("div");
    shadow.className = "inkamp-curl-shadow";
    shadow.style.background = fromRight
      ? "linear-gradient(270deg, rgba(0,0,0,0.28), rgba(0,0,0,0))"
      : "linear-gradient(90deg, rgba(0,0,0,0.28), rgba(0,0,0,0))";

    overlay.append(underlay, sheet, back, fold, shadow);

    const hostStyle = globalThis.getComputedStyle?.(host);
    if (hostStyle && hostStyle.position === "static") {
      host.style.position = "relative";
    }
    host.appendChild(overlay);

    this.#overlay = overlay;
    this.#underlay = underlay;
    this.#sheet = sheet;
    this.#fold = fold;
    this.#back = back;
    this.#shadow = shadow;
  }

  #scheduleVisual(progress) {
    this.#pendingProgress = progress;
    if (this.#raf) return;
    this.#raf = requestAnimationFrame(() => {
      this.#raf = 0;
      if (this.#pendingProgress == null) return;
      const p = this.#pendingProgress;
      this.#pendingProgress = null;
      this.#applyVisual(p);
    });
  }

  #applyVisual(progress) {
    const sheet = this.#sheet;
    const gesture = this.#gesture;
    if (!sheet || !gesture) return;

    const width = gesture.width || sheet.clientWidth || 1;
    const fromRight = gesture.fromRight !== false;
    // Linear progress so the free edge tracks the finger; no full-page 3D.
    const state = peelVisualState(progress, width, fromRight);

    sheet.style.transform = "none";
    sheet.style.transformOrigin = "left top";
    sheet.style.clipPath = state.clipPath;

    if (this.#fold) {
      this.#fold.style.left = `${state.foldLeft}px`;
      this.#fold.style.width = `${state.foldWidth}px`;
      this.#fold.style.right = "auto";
      this.#fold.style.opacity = String(state.foldOpacity);
      this.#fold.style.transformOrigin = state.foldOrigin;
      this.#fold.style.transform = state.foldTransform;
    }
    if (this.#back) {
      this.#back.style.left = `${state.backLeft}px`;
      this.#back.style.width = `${state.backWidth}px`;
      this.#back.style.right = "auto";
      this.#back.style.opacity = String(state.backOpacity);
    }
    if (this.#shadow) {
      this.#shadow.style.left = `${state.shadowLeft}px`;
      this.#shadow.style.width = `${state.shadowWidth}px`;
      this.#shadow.style.right = "auto";
      this.#shadow.style.opacity = String(state.shadowOpacity);
      this.#shadow.style.transform = "none";
    }
  }

  #animateProgress(from, to, durationMs, onDone) {
    this.#animToken += 1;
    const token = this.#animToken;
    if (this.#raf) {
      cancelAnimationFrame(this.#raf);
      this.#raf = 0;
    }
    if (!durationMs || durationMs <= 0 || !this.#sheet) {
      this.#progress = to;
      this.#applyVisual(to);
      onDone?.();
      return;
    }
    const start = performance.now();
    const step = (now) => {
      if (token !== this.#animToken) return;
      const t = clamp01((now - start) / durationMs);
      const eased = 1 - (1 - t) * (1 - t);
      this.#progress = from + (to - from) * eased;
      this.#applyVisual(this.#progress);
      if (t < 1) {
        this.#raf = requestAnimationFrame(step);
      } else {
        this.#raf = 0;
        onDone?.();
      }
    };
    this.#raf = requestAnimationFrame(step);
  }

  #cleanupOverlay() {
    if (this.#raf) {
      cancelAnimationFrame(this.#raf);
      this.#raf = 0;
    }
    this.#pendingProgress = null;
    const hadOverlay = !!this.#overlay;
    if (this.#sheet) {
      this.#sheet.style.willChange = "auto";
      // Release background image bitmap (native JPEG data-URL).
      this.#sheet.style.backgroundImage = "";
      this.#sheet.style.clipPath = "";
    }
    if (this.#fold) this.#fold.style.willChange = "auto";
    this.#overlay?.remove();
    this.#overlay = null;
    this.#underlay = null;
    this.#sheet = null;
    this.#fold = null;
    this.#back = null;
    this.#shadow = null;
    if (hadOverlay) debugLog("PageTurnAnimator", "visual-layer cleanup");
  }

  #resetGesture() {
    this.#clearSnapshotTimer();
    // Invalidate in-flight native replies tied to this gesture.
    this.#snapshotRequestId += 1;
    this.#pendingSnapshotRequestId = 0;
    this.#pendingSnapshotUrl = null;
    this.#snapshotFailed = false;
    this.#phase = "idle";
    this.#gesture = null;
    this.#progress = 0;
    this.#pageFlipSeen = false;
    this.#awaitingSnap = false;
    this.#fallbackThisGesture = false;
  }

  #progressFromOffset(offset) {
    const gesture = this.#gesture;
    const renderer = this.#renderer;
    if (offset != null && gesture) {
      return Math.abs(offset - gesture.startOffset) / Math.max(1, gesture.width || renderer?.size || 1);
    }
    if (!gesture || !renderer) return this.#progress;
    return Math.abs(renderer.start - gesture.startOffset) / Math.max(1, renderer.size || 1);
  }

  #currentDoc() {
    try {
      const contents = this.#renderer?.getContents?.();
      return contents?.[0]?.doc ?? null;
    } catch {
      return null;
    }
  }

  #paperColor(doc = null) {
    try {
      const source = doc || this.#gesture?.doc || this.#currentDoc();
      const bg = source?.defaultView?.getComputedStyle?.(source.documentElement)?.backgroundColor;
      if (bg && bg !== "rgba(0, 0, 0, 0)" && bg !== "transparent") return bg;
    } catch {
      /* ignore */
    }
    return "#f7f3ea";
  }
}
