/**
 * Owns page-turn *appearance* only. Foliate's paginator still owns which page
 * is shown and fires PageFlipped / Relocated. Do not put navigation logic here.
 *
 * Phase 2:
 * - slide: current behavior (Foliate `animated` left unset / restored)
 * - curl: interactive visual curl for *manual* paginated swipes only
 * - instant: ensure no Foliate sliding transition (`animated` removed)
 *
 * Curl is bypassed when:
 * - Reduce Motion is effective
 * - scrolling mode is active
 * - read-aloud / page-follow is active
 * - visual-layer creation fails (falls back to slide for that gesture)
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

const clamp01 = (value) => Math.max(0, Math.min(1, value));

/** Ease-in so the curl stays subtle near the edge, then deepens. */
const mapProgress = (t) => {
  const p = clamp01(t);
  return p * p * (3 - 2 * p);
};

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

  #onTouchStart = (event) => this.#handleTouchStart(event);
  #onTouchEnd = (event) => this.#handleTouchEnd(event);
  #onScroll = () => this.#handleScroll();
  #onPageFlip = () => this.#handlePageFlip();
  #onRelocate = (event) => this.#handleRelocate(event);
  #onOrientation = () => this.#handleOrientationChange();
  #onReduceMotionChange = (event) => {
    if (event?.matches) this.setReduceMotion(true);
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
      if (motionQuery.matches) this.#reduceMotion = true;
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
    this.#phase = "idle";
    this.#gesture = null;
    this.#renderer = null;
    this.#bound = false;
  }

  // --- Public lifecycle (also used by self-check) ---------------------------

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
    let sourceUrl = context.sourceUrl ?? null;

    if (!sourceUrl && context.doc) {
      sourceUrl = this.#captureVisiblePage(context.doc, width, height, context.startOffset ?? 0);
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
    this.#phase = "pending";
    this.#gesture = {
      startX: touch.screenX ?? touch.clientX,
      startY: touch.screenY ?? touch.clientY,
      startOffset: renderer.start,
      fromRight: true,
      rtl: renderer.getAttribute?.("dir") === "rtl",
      width: renderer.size,
      height: this.#host?.clientHeight || renderer.getBoundingClientRect?.().height || 0,
      moved: false,
      doc: this.#currentDoc(),
    };
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

      const started = this.begin({
        fromRight: gesture.fromRight,
        rtl: gesture.rtl,
        width: gesture.width,
        height: gesture.height,
        startOffset: gesture.startOffset,
        doc: gesture.doc || this.#currentDoc(),
        paperColor: this.#paperColor(),
        allowPaperFallback: true,
      });
      if (!started) {
        this.#fallbackThisGesture = true;
        this.#phase = "idle";
        this.#gesture = null;
        return;
      }
    }

    const progress = clamp01(Math.abs(delta) / Math.max(1, renderer.size));
    this.update({ progress });
  }

  #handleTouchEnd() {
    if (this.#phase === "pending" && !this.#gesture?.moved) {
      // Tap / no drag — nothing to curl.
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

  // --- Visual layer --------------------------------------------------------

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
      #${OVERLAY_ID} .inkamp-curl-sheet {
        position: absolute;
        top: 0;
        bottom: 0;
        width: 100%;
        height: 100%;
        transform-style: preserve-3d;
        will-change: transform;
        background-size: cover;
        background-repeat: no-repeat;
        background-position: center;
        box-shadow: 0 0 0 rgba(0,0,0,0);
      }
      #${OVERLAY_ID} .inkamp-curl-fold {
        position: absolute;
        top: 0;
        bottom: 0;
        width: 28%;
        pointer-events: none;
        opacity: 0;
      }
      #${OVERLAY_ID} .inkamp-curl-back {
        position: absolute;
        inset: 0;
        pointer-events: none;
        opacity: 0;
        background: linear-gradient(90deg, rgba(0,0,0,0.12), rgba(0,0,0,0.03) 45%, rgba(255,255,255,0.04));
      }
      #${OVERLAY_ID} .inkamp-curl-shadow {
        position: absolute;
        top: 0;
        bottom: 0;
        width: 18%;
        pointer-events: none;
        opacity: 0;
        filter: blur(6px);
      }
    `;
    document.head.appendChild(style);
  }

  #mountOverlay({ width, height, fromRight, sourceUrl, paperColor }) {
    this.#cleanupOverlay();
    const host = this.#host;
    if (!host) throw new Error("no host");

    const overlay = document.createElement("div");
    overlay.id = OVERLAY_ID;

    const sheet = document.createElement("div");
    sheet.className = "inkamp-curl-sheet";
    sheet.style.width = `${width}px`;
    sheet.style.height = `${height}px`;
    sheet.style.left = fromRight ? "auto" : "0";
    sheet.style.right = fromRight ? "0" : "auto";
    sheet.style.backgroundColor = paperColor;
    if (sourceUrl) {
      sheet.style.backgroundImage = `url("${sourceUrl}")`;
    }

    const fold = document.createElement("div");
    fold.className = "inkamp-curl-fold";
    // Highlight sits on the free (dragged) edge.
    fold.style[fromRight ? "right" : "left"] = "0";
    fold.style.background = fromRight
      ? "linear-gradient(270deg, rgba(255,255,255,0.0), rgba(255,255,255,0.22) 40%, rgba(0,0,0,0.08))"
      : "linear-gradient(90deg, rgba(255,255,255,0.0), rgba(255,255,255,0.22) 40%, rgba(0,0,0,0.08))";

    const back = document.createElement("div");
    back.className = "inkamp-curl-back";

    const shadow = document.createElement("div");
    shadow.className = "inkamp-curl-shadow";
    shadow.style[fromRight ? "right" : "left"] = "0";
    shadow.style.background = fromRight
      ? "linear-gradient(270deg, rgba(0,0,0,0.22), rgba(0,0,0,0))"
      : "linear-gradient(90deg, rgba(0,0,0,0.22), rgba(0,0,0,0))";

    sheet.append(fold, back, shadow);
    overlay.appendChild(sheet);

    const hostStyle = globalThis.getComputedStyle?.(host);
    if (hostStyle && hostStyle.position === "static") {
      host.style.position = "relative";
    }
    host.appendChild(overlay);

    this.#overlay = overlay;
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

    const p = mapProgress(progress);
    const width = gesture.width || sheet.clientWidth || 1;
    const fromRight = gesture.fromRight !== false;

    // Keep the free edge near the finger: translate roughly with drag distance,
    // deepen rotateY / skew so it reads as a peel rather than a flat card spin.
    const pull = p * width * 0.92;
    const translateX = fromRight ? -pull : pull;
    const rotateY = (fromRight ? -1 : 1) * (p * 78);
    const skewY = (fromRight ? 1 : -1) * p * 5;
    const scaleX = 1 - p * 0.06;

    // Spine on the side opposite the free edge so the dragged edge tracks the finger.
    sheet.style.transformOrigin = fromRight ? "left center" : "right center";
    sheet.style.transform =
      `perspective(2200px) translate3d(${translateX}px, 0, 0) `
      + `rotateY(${rotateY}deg) skewY(${skewY}deg) scaleX(${scaleX})`;

    if (this.#fold) this.#fold.style.opacity = String(Math.min(0.85, 0.15 + p * 0.7));
    if (this.#back) this.#back.style.opacity = String(Math.min(0.55, p * 0.55));
    if (this.#shadow) {
      this.#shadow.style.opacity = String(Math.min(0.5, 0.08 + p * 0.42));
      // Keep the drop shadow near the moving free edge.
      this.#shadow.style.transform = `translateX(${fromRight ? -pull * 0.15 : pull * 0.15}px)`;
      this.#shadow.style[fromRight ? "right" : "left"] = "0";
      this.#shadow.style[fromRight ? "left" : "right"] = "auto";
    }

    // Soft clip so the peeled edge looks slightly curved.
    const inset = Math.round(p * 4);
    if (fromRight) {
      sheet.style.clipPath = `polygon(0% 0%, 100% ${inset}%, 100% ${100 - inset}%, 0% 100%)`;
    } else {
      sheet.style.clipPath = `polygon(0% ${inset}%, 100% 0%, 100% 100%, 0% ${100 - inset}%)`;
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
      // Release background image bitmap.
      this.#sheet.style.backgroundImage = "";
    }
    this.#overlay?.remove();
    this.#overlay = null;
    this.#sheet = null;
    this.#fold = null;
    this.#back = null;
    this.#shadow = null;
    if (hadOverlay) debugLog("PageTurnAnimator", "visual-layer cleanup");
  }

  #resetGesture() {
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

  #paperColor() {
    try {
      const doc = this.#currentDoc();
      const bg = doc?.defaultView?.getComputedStyle?.(doc.documentElement)?.backgroundColor;
      if (bg && bg !== "rgba(0, 0, 0, 0)" && bg !== "transparent") return bg;
    } catch {
      /* ignore */
    }
    return "#f7f3ea";
  }

  /**
   * Capture the currently visible page into a data-URL for the curl sheet.
   * Uses SVG foreignObject of the section document, clipped to the visible
   * column window. Returns null on failure (caller falls back).
   */
  #captureVisiblePage(doc, width, height, startOffset) {
    try {
      if (!doc?.documentElement || typeof XMLSerializer === "undefined") return null;
      const win = doc.defaultView;
      const iframe = win?.frameElement;
      const iframeWidth = Math.max(
        width,
        Math.ceil(iframe?.offsetWidth || doc.documentElement.scrollWidth || width),
      );
      const iframeHeight = Math.max(
        height,
        Math.ceil(iframe?.offsetHeight || height),
      );

      const clone = doc.documentElement.cloneNode(true);
      clone.querySelectorAll("script").forEach((node) => node.remove());
      clone.setAttribute("xmlns", "http://www.w3.org/1999/xhtml");
      // Hide interactive chrome that shouldn't appear on the sheet.
      clone.querySelectorAll("canvas").forEach((node) => {
        node.setAttribute("style", `${node.getAttribute("style") || ""};opacity:0`);
      });

      const serialized = new XMLSerializer().serializeToString(clone);
      const srcX = Math.max(0, Math.round(startOffset || 0));
      const svg =
        `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}">`
        + `<foreignObject width="${iframeWidth}" height="${iframeHeight}" x="${-srcX}" y="0">`
        + serialized
        + `</foreignObject></svg>`;

      // Synchronous data-URL path keeps begin() simple; foreignObject paint is
      // async when used via Image, so we store the SVG data URL directly as the
      // sheet background. Safari paints SVG foreignObject backgrounds for many
      // same-origin documents; if it fails visually we still have paperColor.
      return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
    } catch (error) {
      debugLog("PageTurnAnimator", "curl fallback: snapshot failed", error);
      return null;
    }
  }
}
