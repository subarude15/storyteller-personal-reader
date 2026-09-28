/**
 * Owns page-turn *appearance* only. Foliate's paginator still owns which page
 * is shown and fires PageFlipped / Relocated. Do not put navigation logic here.
 *
 * Curl visual model (curved paper peel):
 * - native WKWebView snapshot stays flat and readable (no full-page 3D)
 * - cubic curved clip boundary (not a straight vertical wipe)
 * - narrow backside fold wedge + soft curved shadow/highlight
 * - solid underlay hides Foliate's intermediate scroll during the drag
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
const SVG_NS = "http://www.w3.org/2000/svg";
const COMPLETE_MS = 180;
const CANCEL_MS = 200;
/** How long to wait for a native snapshot before giving up on curl. */
const SNAPSHOT_TIMEOUT_MS = 220;
const clamp01 = (value) => Math.max(0, Math.min(1, value));
const px = (n) => Math.round(n * 10) / 10;

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
 * Cubic C-curve for a page-fold silhouette.
 * Midpoint bows into the remaining page (classic peel outline).
 * Top/bottom terminate at `edge` so the crease meets the viewport cleanly.
 */
function foldBoundaryPath(edge, amp, h, fromRight) {
  const xTB = px(edge);
  const xMid = px(fromRight ? edge - amp : edge + amp);
  const y1 = px(h * 0.22);
  const y2 = px(h * 0.38);
  const yMid = px(h * 0.5);
  const y3 = px(h * 0.62);
  const y4 = px(h * 0.78);
  const yH = px(h);
  return (
    `${xTB} 0 `
    + `C ${xTB} ${y1}, ${xMid} ${y2}, ${xMid} ${yMid} `
    + `C ${xMid} ${y3}, ${xTB} ${y4}, ${xTB} ${yH}`
  );
}

function reverseFoldBoundaryPath(edge, amp, h, fromRight) {
  const xTB = px(edge);
  const xMid = px(fromRight ? edge - amp : edge + amp);
  const y1 = px(h * 0.22);
  const y2 = px(h * 0.38);
  const yMid = px(h * 0.5);
  const y3 = px(h * 0.62);
  const y4 = px(h * 0.78);
  const yH = px(h);
  return (
    `${xTB} ${yH} `
    + `C ${xTB} ${y4}, ${xMid} ${y3}, ${xMid} ${yMid} `
    + `C ${xMid} ${y2}, ${xTB} ${y1}, ${xTB} 0`
  );
}

/**
 * Outer flap edge that pinches to `edge` at top/bottom (zero-width caps)
 * and reaches `outerMid` only at mid-height. Prevents rectangular end bars.
 */
function taperedFlapOuterPath(edge, outerMid, h) {
  const xTB = px(edge);
  const xMid = px(outerMid);
  const y1 = px(h * 0.16);
  const y2 = px(h * 0.34);
  const yMid = px(h * 0.5);
  const y3 = px(h * 0.66);
  const y4 = px(h * 0.84);
  const yH = px(h);
  return (
    `${xTB} 0 `
    + `C ${xTB} ${y1}, ${xMid} ${y2}, ${xMid} ${yMid} `
    + `C ${xMid} ${y3}, ${xTB} ${y4}, ${xTB} ${yH}`
  );
}

function reverseTaperedFlapOuterPath(edge, outerMid, h) {
  const xTB = px(edge);
  const xMid = px(outerMid);
  const y1 = px(h * 0.16);
  const y2 = px(h * 0.34);
  const yMid = px(h * 0.5);
  const y3 = px(h * 0.66);
  const y4 = px(h * 0.84);
  const yH = px(h);
  return (
    `${xTB} ${yH} `
    + `C ${xTB} ${y4}, ${xMid} ${y3}, ${xMid} ${yMid} `
    + `C ${xMid} ${y2}, ${xTB} ${y1}, ${xTB} 0`
  );
}

/**
 * Curved page-peel geometry — one continuous function of progress.
 * The snapshot sheet itself is never rotated/skewed — only clipped by a curve.
 * Fold backside / shadow / highlight are tapered wedges attached to that curve.
 *
 * @param {number} progress 0..1
 * @param {number} width CSS px
 * @param {number} [height=0] CSS px (defaults to a tall phone-like ratio)
 * @param {boolean} [fromRight=true]
 */
export function peelVisualState(progress, width, height = 0, fromRight = true) {
  // Back-compat: peelVisualState(p, w, fromRightBoolean)
  if (typeof height === "boolean") {
    fromRight = height;
    height = 0;
  }

  const p = clamp01(progress);
  const w = Math.max(1, width || 1);
  const h = Math.max(1, height || w * 1.9);
  const remain = 1 - p;
  const edgeX = fromRight ? w * remain : w * p;

  // Progress-responsive fold: tiny early, pronounced mid, taper near end.
  // sin(πp) peaks at p=0.5 so slow/fast swipes share one continuous curve.
  const peelEnvelope = Math.sin(p * Math.PI);
  const foldWidth = w * (0.055 + 0.11 * peelEnvelope); // ~5.5–16.5% mid
  const curveAmp = w * (0.018 + 0.1 * peelEnvelope); // ~1.8–11.8%

  // Fold appears as soon as there is meaningful peel — no delayed takeover.
  const foldVisible = p > 0.008 && p < 0.992;
  const amp = foldVisible ? curveAmp : 0;
  const flap = foldVisible ? foldWidth : 0;

  // Mid-height outer tip of the backside flap (into the revealed zone).
  // Top/bottom pinch to edgeX — no parallel rectangular caps.
  const outerMid = fromRight
    ? Math.min(w, edgeX + flap)
    : Math.max(0, edgeX - flap);

  let flatPath;
  let foldPath = "";
  let shadowPath = "";
  let highlightPath = "";

  if (p <= 0) {
    flatPath = `M 0 0 L ${px(w)} 0 L ${px(w)} ${px(h)} L 0 ${px(h)} Z`;
  } else if (p >= 1) {
    flatPath = fromRight
      ? `M 0 0 L 0 0 L 0 ${px(h)} L 0 ${px(h)} Z`
      : `M ${px(w)} 0 L ${px(w)} 0 L ${px(w)} ${px(h)} L ${px(w)} ${px(h)} Z`;
  } else if (fromRight) {
    const boundary = foldBoundaryPath(edgeX, amp, h, true);
    flatPath = `M 0 0 L ${boundary} L 0 ${px(h)} Z`;
    const inner = foldBoundaryPath(edgeX, amp, h, true);
    const outer = reverseTaperedFlapOuterPath(edgeX, outerMid, h);
    foldPath = `M ${inner} L ${outer} Z`;
    // Shadow hugs the crease — narrower tapered band into the flap.
    const shadowMid = Math.min(w, edgeX + flap * 0.45);
    shadowPath = `M ${inner} L ${reverseTaperedFlapOuterPath(edgeX, shadowMid, h)} Z`;
    // Soft highlight on the readable-page side of the crease.
    const hiInset = Math.min(amp * 0.4, w * 0.018);
    const hiInner = foldBoundaryPath(Math.max(0, edgeX - hiInset), amp * 0.85, h, true);
    highlightPath = `M ${hiInner} L ${reverseFoldBoundaryPath(edgeX, amp, h, true)} Z`;
  } else {
    const boundary = foldBoundaryPath(edgeX, amp, h, false);
    flatPath = `M ${px(w)} 0 L ${boundary} L ${px(w)} ${px(h)} Z`;
    const inner = foldBoundaryPath(edgeX, amp, h, false);
    const outer = reverseTaperedFlapOuterPath(edgeX, outerMid, h);
    foldPath = `M ${inner} L ${outer} Z`;
    const shadowMid = Math.max(0, edgeX - flap * 0.45);
    shadowPath = `M ${inner} L ${reverseTaperedFlapOuterPath(edgeX, shadowMid, h)} Z`;
    const hiInset = Math.min(amp * 0.4, w * 0.018);
    const hiInner = foldBoundaryPath(Math.min(w, edgeX + hiInset), amp * 0.85, h, false);
    highlightPath = `M ${hiInner} L ${reverseFoldBoundaryPath(edgeX, amp, h, false)} Z`;
  }

  const foldOpacity = foldVisible ? Math.min(0.96, 0.5 + p * 0.4) : 0;
  const shadowOpacity = foldVisible ? Math.min(0.22, 0.08 + peelEnvelope * 0.14) : 0;
  const highlightOpacity = foldVisible ? Math.min(0.32, 0.1 + peelEnvelope * 0.18) : 0;

  return {
    progress: p,
    remain,
    edgeX,
    height: h,
    width: w,
    foldWidth: flap,
    curveAmp: amp,
    outerMid,
    flatPath,
    foldPath,
    shadowPath,
    highlightPath,
    /** CSS clip-path value for the flat snapshot layer. */
    clipPath: `path("${flatPath}")`,
    foldOpacity,
    shadowOpacity,
    highlightOpacity,
    foldVisible,
    // Contract: the flat sheet must stay undistorted.
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
  #shapesSvg = null;
  #backPath = null;
  #shadowPath = null;
  #highlightPath = null;
  #backGrad = null;
  #shadowGrad = null;
  #mountedPaperColor = "#f3eee4";
  #progress = 0;
  #raf = 0;
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
  #onTouchMove = (event) => this.#handleTouchMove(event);
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
    renderer.addEventListener("touchmove", this.#onTouchMove, { passive: true });
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
    doc.addEventListener("touchmove", this.#onTouchMove, { passive: true });
    doc.addEventListener("touchend", this.#onTouchEnd, { passive: true });
    doc.addEventListener("touchcancel", this.#onTouchEnd, { passive: true });
  }

  detach() {
    if (this.#renderer && this.#bound) {
      this.#renderer.removeEventListener("scroll", this.#onScroll);
      this.#renderer.removeEventListener("page-flip", this.#onPageFlip);
      this.#renderer.removeEventListener("relocate", this.#onRelocate);
      this.#renderer.removeEventListener("touchstart", this.#onTouchStart);
      this.#renderer.removeEventListener("touchmove", this.#onTouchMove);
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

    // Mount at the caller's current gesture progress — never flash progress 0
    // when the finger is already mid-drag (late snapshot arrival).
    const initialProgress = clamp01(context.progress ?? 0);
    const prior = this.#gesture;
    this.#phase = "curling";
    this.#progress = initialProgress;
    this.#pageFlipSeen = false;
    this.#awaitingSnap = false;
    this.#fallbackThisGesture = false;
    this.#gesture = {
      fromRight,
      rtl,
      width,
      height,
      startOffset: context.startOffset ?? prior?.startOffset ?? this.#renderer?.start ?? 0,
      startX: context.startX ?? prior?.startX,
      startY: context.startY ?? prior?.startY,
      lastX: context.lastX ?? prior?.lastX,
      fingerProgress: initialProgress,
      directionLocked: true,
      moved: true,
      doc: context.doc ?? prior?.doc,
    };
    this.#applyVisual(initialProgress);
    debugLog("PageTurnAnimator", "curl begin", {
      fromRight,
      rtl,
      width,
      height,
      progress: initialProgress,
    });
    return true;
  }

  update(context = {}) {
    if (this.#phase !== "curling") return;
    const progress = clamp01(
      context.progress ?? this.#progressFromOffset(context.offset),
    );
    this.#progress = progress;
    if (this.#gesture) this.#gesture.fingerProgress = progress;
    // Interactive drag is synchronous so the fold stays on the finger.
    // Completion / cancel keep using #animateProgress (time-based) after release.
    this.#applyVisual(progress);
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
    this.#progress = 0;
    // Arm the gesture before requesting so a fast native reply is not rejected.
    this.#phase = "pending";
    const startX = touch.screenX ?? touch.clientX;
    const startY = touch.screenY ?? touch.clientY;
    this.#gesture = {
      startX,
      startY,
      lastX: startX,
      startOffset: renderer.start, // paginator scroll — fallback progress only
      fromRight: true,
      rtl: renderer.getAttribute?.("dir") === "rtl",
      width: renderer.size,
      height: this.#host?.clientHeight || renderer.getBoundingClientRect?.().height || 0,
      moved: false,
      directionLocked: false,
      fingerProgress: 0,
      // Touched section doc kept for paperColor under the snapshot only.
      doc: docFromTouchEvent(event) || this.#currentDoc(),
    };
    // Capture the current rendered page before the paginator scrolls.
    this.#requestNativeSnapshot();
  }

  /**
   * Finger-driven visual progress. Foliate still owns snap / page selection;
   * this only updates the peel geometry so the fold tracks the finger.
   */
  #handleTouchMove(event) {
    if (this.#phase !== "pending" && this.#phase !== "curling") return;
    if (this.#fallbackThisGesture) return;
    const gesture = this.#gesture;
    const renderer = this.#renderer;
    if (!gesture || !renderer || renderer.scrolled) return;

    const touch = event.touches?.[0] ?? event.changedTouches?.[0];
    if (!touch) return;

    const x = touch.screenX ?? touch.clientX;
    gesture.lastX = x;
    gesture.width = renderer.size || gesture.width;
    gesture.height = this.#host?.clientHeight || gesture.height;

    const dx = x - gesture.startX;
    if (!gesture.moved) {
      if (Math.abs(dx) < 2) return;
      this.#lockDirectionFromDelta(dx > 0 ? 1 : -1, /* fromFinger */ true);
      if (!gesture.moved) return;

      if (this.#snapshotFailed) {
        debugLog("PageTurnAnimator", "curl fallback: snapshot unavailable at drag start");
        this.#fallbackThisGesture = true;
        this.#phase = "idle";
        this.#gesture = null;
        return;
      }

      const firstProgress = this.#progressFromFinger(x);
      gesture.fingerProgress = firstProgress;
      this.#progress = firstProgress;

      if (!this.#pendingSnapshotUrl) {
        // Keep tracking finger progress; mount when the snapshot arrives.
        debugLog("PageTurnAnimator", "curl waiting for native snapshot");
        return;
      }

      this.#beginFromPendingGesture();
      if (this.#phase !== "curling") return;
    } else if (!gesture.directionLocked) {
      this.#lockDirectionFromDelta(dx > 0 ? 1 : -1, /* fromFinger */ true);
    }

    const progress = this.#progressFromFinger(x);
    gesture.fingerProgress = progress;
    this.#progress = progress;

    if (this.#phase === "pending" && !this.#overlay) {
      // Snapshot still pending — progress is tracked for late mount.
      return;
    }
    if (this.#phase === "curling") {
      this.update({ progress });
    }
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
      // Prefer Foliate scroll for direction when touchmove has not locked yet.
      this.#lockDirectionFromDelta(delta, /* fromFinger */ false);
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
        // Track scroll-based progress until the native snapshot arrives.
        const progress = clamp01(Math.abs(delta) / Math.max(1, renderer.size));
        gesture.fingerProgress = progress;
        this.#progress = progress;
        debugLog("PageTurnAnimator", "curl waiting for native snapshot");
        return;
      }

      this.#beginFromPendingGesture();
      if (this.#phase !== "curling") return;
    }

    // Finger position is authoritative while curling; scroll only fills gaps
    // when touchmove has not yet reported (e.g. synthetic scroll tests).
    if (this.#phase === "curling" && gesture.lastX == null) {
      const progress = clamp01(Math.abs(delta) / Math.max(1, renderer.size));
      this.update({ progress });
    } else if (this.#phase === "pending" && !this.#overlay) {
      const progress = clamp01(Math.abs(delta) / Math.max(1, renderer.size));
      // Keep the later of finger vs scroll so a late snapshot mounts correctly.
      if (progress > (gesture.fingerProgress ?? 0)) {
        gesture.fingerProgress = progress;
        this.#progress = progress;
      }
    }
  }

  /**
   * Lock peel direction once per gesture.
   * @param {number} signedDelta positive ⇒ increasing page index / finger right
   * @param {boolean} fromFinger when true, delta is finger dx (right positive)
   */
  #lockDirectionFromDelta(signedDelta, fromFinger) {
    const gesture = this.#gesture;
    const renderer = this.#renderer;
    if (!gesture || gesture.directionLocked) {
      if (gesture && !gesture.moved && Math.abs(signedDelta) >= 1) gesture.moved = true;
      return;
    }
    const rtl = renderer?.getAttribute?.("dir") === "rtl" || !!gesture.rtl;
    // Foliate: higher start ⇒ forward in reading order.
    // Finger: LTR forward is drag left (dx < 0); RTL forward is drag right.
    const goingForward = fromFinger
      ? (rtl ? signedDelta > 0 : signedDelta < 0)
      : signedDelta > 0;
    gesture.fromRight = rtl ? !goingForward : goingForward;
    gesture.rtl = rtl;
    gesture.directionLocked = true;
    gesture.moved = true;
  }

  #progressFromFinger(fingerX) {
    const gesture = this.#gesture;
    if (!gesture || gesture.startX == null) return this.#progress;
    const width = Math.max(1, gesture.width || this.#renderer?.size || 1);
    const dx = fingerX - gesture.startX;
    // fromRight peel: drag left increases progress; fromLeft: drag right.
    const raw = gesture.fromRight !== false ? -dx / width : dx / width;
    return clamp01(raw);
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

    // Always mount at the live gesture progress — never restart at 0 mid-drag.
    const progress = this.#currentGestureProgress();
    const started = this.begin({
      fromRight: gesture.fromRight,
      rtl: gesture.rtl,
      width: gesture.width,
      height: gesture.height,
      startOffset: gesture.startOffset,
      startX: gesture.startX,
      startY: gesture.startY,
      lastX: gesture.lastX,
      progress,
      sourceUrl,
      paperColor: this.#paperColor(gesture.doc),
      doc: gesture.doc,
    });
    if (!started) {
      this.#fallbackThisGesture = true;
      this.#phase = "idle";
      this.#gesture = null;
      return;
    }
  }

  /** Best-known progress for the active gesture (finger preferred, else scroll). */
  #currentGestureProgress() {
    const gesture = this.#gesture;
    if (!gesture) return 0;
    if (gesture.fingerProgress != null && gesture.moved) {
      return clamp01(gesture.fingerProgress);
    }
    if (gesture.lastX != null && gesture.startX != null && gesture.directionLocked) {
      return this.#progressFromFinger(gesture.lastX);
    }
    const renderer = this.#renderer;
    if (renderer && gesture.startOffset != null) {
      return clamp01(
        Math.abs(renderer.start - gesture.startOffset) / Math.max(1, renderer.size || 1),
      );
    }
    return clamp01(this.#progress);
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

  // --- Visual layer (curved paper peel) ------------------------------------

  #svgEl(tag) {
    if (typeof document.createElementNS === "function") {
      return document.createElementNS(SVG_NS, tag);
    }
    return document.createElement(tag);
  }

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
      #${OVERLAY_ID} .inkamp-curl-shapes {
        position: absolute;
        inset: 0;
        z-index: 2;
        width: 100%;
        height: 100%;
        overflow: hidden;
        pointer-events: none;
      }
      #${OVERLAY_ID} .inkamp-curl-back {
        opacity: 0;
      }
      #${OVERLAY_ID} .inkamp-curl-shadow {
        opacity: 0;
      }
      #${OVERLAY_ID} .inkamp-curl-highlight {
        opacity: 0;
      }
    `;
    document.head.appendChild(style);
  }

  #mountOverlay({ width, height, fromRight, sourceUrl, paperColor }) {
    this.#cleanupOverlay();
    const host = this.#host;
    if (!host) throw new Error("no host");
    if (!sourceUrl) throw new Error("no snapshot");

    this.#mountedPaperColor = paperColor || "#f3eee4";

    const overlay = document.createElement("div");
    overlay.id = OVERLAY_ID;

    // Temporary cover so Foliate's intermediate scroll never shows through.
    const underlay = document.createElement("div");
    underlay.className = "inkamp-curl-underlay";
    underlay.style.backgroundColor = this.#mountedPaperColor;

    // Flat current-page snapshot — curved clip only; never full-page 3D.
    const sheet = document.createElement("div");
    sheet.className = "inkamp-curl-sheet";
    sheet.style.width = `${width}px`;
    sheet.style.height = `${height}px`;
    sheet.style.backgroundColor = this.#mountedPaperColor;
    sheet.style.backgroundImage = `url("${sourceUrl}")`;
    sheet.style.transform = "none";

    const svg = this.#svgEl("svg");
    svg.setAttribute("class", "inkamp-curl-shapes");
    svg.setAttribute("width", String(width));
    svg.setAttribute("height", String(height));
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);

    const defs = this.#svgEl("defs");

    const grad = this.#svgEl("linearGradient");
    grad.setAttribute("id", "inkamp-curl-back-grad");
    grad.setAttribute("gradientUnits", "userSpaceOnUse");
    // Updated each frame in #applyVisual for direction/position.
    const stopA = this.#svgEl("stop");
    stopA.setAttribute("offset", "0%");
    stopA.setAttribute("stop-color", "#f7f2e8");
    const stopB = this.#svgEl("stop");
    stopB.setAttribute("offset", "55%");
    stopB.setAttribute("stop-color", "#e8e1d5");
    const stopC = this.#svgEl("stop");
    stopC.setAttribute("offset", "100%");
    stopC.setAttribute("stop-color", "#d5cec2");
    grad.append(stopA, stopB, stopC);

    // Soft fold shadow via gradient (no feGaussianBlur — blur filter bounds
    // were painting black rectangular bars at the overlay top/bottom).
    const shadowGrad = this.#svgEl("linearGradient");
    shadowGrad.setAttribute("id", "inkamp-curl-shadow-grad");
    shadowGrad.setAttribute("gradientUnits", "userSpaceOnUse");
    const s0 = this.#svgEl("stop");
    s0.setAttribute("offset", "0%");
    s0.setAttribute("stop-color", "rgb(55, 48, 40)");
    s0.setAttribute("stop-opacity", "0.28");
    const s1 = this.#svgEl("stop");
    s1.setAttribute("offset", "55%");
    s1.setAttribute("stop-color", "rgb(55, 48, 40)");
    s1.setAttribute("stop-opacity", "0.1");
    const s2 = this.#svgEl("stop");
    s2.setAttribute("offset", "100%");
    s2.setAttribute("stop-color", "rgb(55, 48, 40)");
    s2.setAttribute("stop-opacity", "0");
    shadowGrad.append(s0, s1, s2);
    defs.append(grad, shadowGrad);

    const backPath = this.#svgEl("path");
    backPath.setAttribute("class", "inkamp-curl-back");
    backPath.setAttribute("fill", "url(#inkamp-curl-back-grad)");

    const shadowPath = this.#svgEl("path");
    shadowPath.setAttribute("class", "inkamp-curl-shadow");
    shadowPath.setAttribute("fill", "url(#inkamp-curl-shadow-grad)");

    const highlightPath = this.#svgEl("path");
    highlightPath.setAttribute("class", "inkamp-curl-highlight");
    highlightPath.setAttribute("fill", "rgba(255, 255, 255, 0.28)");

    svg.append(defs, backPath, shadowPath, highlightPath);
    overlay.append(underlay, sheet, svg);

    const hostStyle = globalThis.getComputedStyle?.(host);
    if (hostStyle && hostStyle.position === "static") {
      host.style.position = "relative";
    }
    host.appendChild(overlay);

    this.#overlay = overlay;
    this.#underlay = underlay;
    this.#sheet = sheet;
    this.#shapesSvg = svg;
    this.#backPath = backPath;
    this.#shadowPath = shadowPath;
    this.#highlightPath = highlightPath;
    this.#backGrad = grad;
    this.#shadowGrad = shadowGrad;
  }

  #applyVisual(progress) {
    const sheet = this.#sheet;
    const gesture = this.#gesture;
    if (!sheet || !gesture) return;

    const width = gesture.width || sheet.clientWidth || 1;
    const height = gesture.height || sheet.clientHeight || width * 1.9;
    const fromRight = gesture.fromRight !== false;
    const state = peelVisualState(progress, width, height, fromRight);

    // Flat readable page — curved clip only.
    sheet.style.transform = "none";
    sheet.style.transformOrigin = "left top";
    sheet.style.clipPath = state.clipPath;
    if (sheet.style.webkitClipPath !== undefined) {
      sheet.style.webkitClipPath = state.clipPath;
    }

    if (this.#shapesSvg) {
      this.#shapesSvg.setAttribute("width", String(width));
      this.#shapesSvg.setAttribute("height", String(height));
      this.#shapesSvg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    }

    if (this.#backGrad) {
      // Gradient across the fold flap, crease → free edge.
      const x1 = state.edgeX;
      const x2 = fromRight
        ? state.outerMid ?? (state.edgeX + state.foldWidth)
        : state.outerMid ?? (state.edgeX - state.foldWidth);
      this.#backGrad.setAttribute("x1", String(px(x1)));
      this.#backGrad.setAttribute("y1", "0");
      this.#backGrad.setAttribute("x2", String(px(x2)));
      this.#backGrad.setAttribute("y2", "0");
    }
    if (this.#shadowGrad) {
      const x1 = state.edgeX;
      const x2 = fromRight
        ? state.edgeX + state.foldWidth * 0.45
        : state.edgeX - state.foldWidth * 0.45;
      this.#shadowGrad.setAttribute("x1", String(px(x1)));
      this.#shadowGrad.setAttribute("y1", "0");
      this.#shadowGrad.setAttribute("x2", String(px(x2)));
      this.#shadowGrad.setAttribute("y2", "0");
    }

    if (this.#backPath) {
      this.#backPath.setAttribute("d", state.foldPath || "M0 0");
      this.#backPath.style.opacity = String(state.foldOpacity);
    }
    if (this.#shadowPath) {
      this.#shadowPath.setAttribute("d", state.shadowPath || "M0 0");
      this.#shadowPath.style.opacity = String(state.shadowOpacity);
    }
    if (this.#highlightPath) {
      this.#highlightPath.setAttribute("d", state.highlightPath || "M0 0");
      this.#highlightPath.style.opacity = String(state.highlightOpacity);
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
    const hadOverlay = !!this.#overlay;
    if (this.#sheet) {
      this.#sheet.style.willChange = "auto";
      // Release background image bitmap (native JPEG data-URL).
      this.#sheet.style.backgroundImage = "";
      this.#sheet.style.clipPath = "";
      if (this.#sheet.style.webkitClipPath !== undefined) {
        this.#sheet.style.webkitClipPath = "";
      }
    }
    this.#overlay?.remove();
    this.#overlay = null;
    this.#underlay = null;
    this.#sheet = null;
    this.#shapesSvg = null;
    this.#backPath = null;
    this.#shadowPath = null;
    this.#highlightPath = null;
    this.#backGrad = null;
    this.#shadowGrad = null;
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
