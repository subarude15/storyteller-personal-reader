/**
 * Owns page-turn *appearance* only. Foliate's paginator still owns which page
 * is shown and fires PageFlipped / Relocated. Do not put navigation logic here.
 *
 * Apple Books–style page flips on both iPhone and iPad:
 * - Idle snapshot pre-caching: captures the settled page into memory ahead of
 *   time so finger drags and margin taps start in 0ms without snapshot lag.
 * - Curl mode (2.5D/3D cylindrical paper peel):
 *   - Stationary next-page reveal underneath (transparent underlay on intra-
 *     section turns while the live paginator parks at the destination page).
 *   - Diagonal curved crease with concave inner-valley shading.
 *   - Mirrored backside page bleed-through reflected across the diagonal crease.
 *   - Theme-adaptive cylindrical paper gradient (Light, Sepia, Dark).
 *   - Soft cast drop shadow projected onto the revealed next page underneath.
 *   - Works for both interactive finger swipes and margin taps / arrow keys
 *     across iPhone single-page and iPad two-page spread layouts.
 * - Slide mode (GPU-composited Apple Books sheet slide):
 *   - Outgoing sheet slides via GPU `translate3d` with a trailing drop shadow
 *     while the incoming page beneath glides in with subtle parallax.
 *   - Smoothed flick velocity + 14% swipe threshold so natural short swipes on
 *     both iPhone and iPad commit reliably without snapping back.
 *
 * Curl is bypassed when:
 * - Reduce Motion is effective
 * - scrolling mode is active
 * - read-aloud / page-follow is active
 * - native snapshot is unavailable / late / failed (falls back cleanly —
 *   never paints an opaque blank sheet)
 */

import { debugLog } from "./DebugConfig.js";

const VALID_STYLES = new Set(["slide", "curl", "instant"]);
const OVERLAY_ID = "inkamp-page-curl-overlay";
const STYLE_ID = "inkamp-page-curl-styles";
const SVG_NS = "http://www.w3.org/2000/svg";
const COMPLETE_MS = 240;
const CANCEL_MS = 200;
const TAP_CURL_MS = 320;
const TAP_SLIDE_MS = 250;
/** How long to wait for a native snapshot before giving up on curl. */
const SNAPSHOT_TIMEOUT_MS = 220;
const IDLE_CACHE_DELAY_MS = 65;
const SWIPE_COMMIT_PROGRESS = 0.14;
const SWIPE_COMMIT_VELOCITY = 0.14; // px/ms

const clamp01 = (value) => Math.max(0, Math.min(1, value));
const px = (n) => Math.round(n * 10) / 10;
const lerp = (a, b, t) => a + (b - a) * t;

/** Apple Books spring-like ease-out curve. */
function easeAppleOut(t) {
  const clamped = clamp01(t);
  return 1 - Math.pow(1 - clamped, 3.2);
}

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
 * Touch-Y band used to rotate the diagonal peel.
 * Wider than the old vertical-bulge nudge so endpoints can actually lean.
 */
function clampTouchY(touchY) {
  const raw = Number.isFinite(touchY) ? touchY : 0.5;
  return Math.max(0.28, Math.min(0.72, raw));
}

/**
 * Angled crease from (topX, 0) → (bottomX, h).
 * Control points bow slightly into the remaining page (convex paper fold).
 */
function diagonalCreasePath(topX, bottomX, bowX, midY, h, reverse = false) {
  const xT = px(topX);
  const xB = px(bottomX);
  const x1 = px(lerp(topX, bowX, 0.55));
  const x2 = px(lerp(bottomX, bowX, 0.55));
  const y1 = px(midY * 0.42);
  const y2 = px(midY * 0.82);
  const y3 = px(midY + (h - midY) * 0.22);
  const y4 = px(midY + (h - midY) * 0.58);
  const yH = px(h);
  if (reverse) {
    return (
      `${xB} ${yH} `
      + `C ${x2} ${y4}, ${x2} ${y3}, ${px(bowX)} ${px(midY)} `
      + `C ${x1} ${y2}, ${x1} ${y1}, ${xT} 0`
    );
  }
  return (
    `${xT} 0 `
    + `C ${x1} ${y1}, ${x1} ${y2}, ${px(bowX)} ${px(midY)} `
    + `C ${x2} ${y3}, ${x2} ${y4}, ${xB} ${yH}`
  );
}

/**
 * Outer edge of the backside flap: pinches near the top crease endpoint and
 * swings wide toward the bottom (triangular / peeled-sheet silhouette).
 */
function diagonalFlapOuterPath(topOuter, bottomOuter, tipX, tipY, h, reverse = false) {
  const xT = px(topOuter);
  const xB = px(bottomOuter);
  const xTip = px(tipX);
  const yTip = px(tipY);
  const y1 = px(tipY * 0.35);
  const y2 = px(tipY * 0.75);
  const y3 = px(tipY + (h - tipY) * 0.28);
  const y4 = px(tipY + (h - tipY) * 0.62);
  const yH = px(h);
  // Soft approach into the tip, then out to the wide bottom.
  if (reverse) {
    return (
      `${xB} ${yH} `
      + `C ${px(lerp(bottomOuter, tipX, 0.35))} ${y4}, ${xTip} ${y3}, ${xTip} ${yTip} `
      + `C ${xTip} ${y2}, ${px(lerp(topOuter, tipX, 0.4))} ${y1}, ${xT} 0`
    );
  }
  return (
    `${xT} 0 `
    + `C ${px(lerp(topOuter, tipX, 0.4))} ${y1}, ${xTip} ${y2}, ${xTip} ${yTip} `
    + `C ${xTip} ${y3}, ${px(lerp(bottomOuter, tipX, 0.35))} ${y4}, ${xB} ${yH}`
  );
}

/**
 * Diagonal page-peel geometry — continuous in progress, locked touch-Y per gesture.
 * Snapshot sheet stays flat; only the clip crease and SVG flap change.
 *
 * Model (forward / fromRight):
 * - top crease stays nearer the free (right) edge
 * - bottom crease travels farther left
 * - backside flap is narrow at top, broad at bottom
 * - touchY rotates that lean (upper / middle / lower drag)
 *
 * @param {number} progress 0..1
 * @param {number} width CSS px
 * @param {number} [height=0] CSS px (defaults to a tall phone-like ratio)
 * @param {boolean} [fromRight=true]
 * @param {number} [touchY=0.5] normalized vertical grab (0=top … 1=bottom)
 */
export function peelVisualState(progress, width, height = 0, fromRight = true, touchY = 0.5) {
  // Back-compat: peelVisualState(p, w, fromRightBoolean)
  if (typeof height === "boolean") {
    fromRight = height;
    height = 0;
  }

  const p = clamp01(progress);
  const w = Math.max(1, width || 1);
  const h = Math.max(1, height || w * 1.9);
  const ty = clampTouchY(touchY);
  const touch = ty - 0.5; // −0.22 … +0.22
  const remain = 1 - p;

  // Progress envelope: tiny early, fullest mid, taper near end.
  const peelEnvelope = Math.sin(p * Math.PI);

  // How far top vs bottom advance from the free edge (as a fraction of width).
  // bottomRate > topRate ⇒ diagonal lean (Apple Books–like peel).
  // Upper touch raises topRate / lowers bottomRate; lower touch does the opposite.
  const topRate = 0.36 - touch * 0.55; // ~0.24–0.48
  const bottomRate = 1.12 + touch * 0.5; // ~1.01–1.23

  const topAdvance = Math.min(0.92, p * topRate * (0.85 + 0.15 * peelEnvelope));
  const bottomAdvance = Math.min(0.98, p * bottomRate * (0.9 + 0.1 * peelEnvelope));

  let topX;
  let bottomX;
  if (fromRight) {
    topX = w * (1 - topAdvance);
    bottomX = w * (1 - bottomAdvance);
    // Keep a readable diagonal: bottom must sit left of top.
    bottomX = Math.min(bottomX, topX - w * 0.04 * peelEnvelope);
    bottomX = Math.max(0, bottomX);
    topX = Math.min(w, Math.max(bottomX + 1, topX));
  } else {
    topX = w * topAdvance;
    bottomX = w * bottomAdvance;
    bottomX = Math.max(bottomX, topX + w * 0.04 * peelEnvelope);
    bottomX = Math.min(w, bottomX);
    topX = Math.max(0, Math.min(bottomX - 1, topX));
  }

  // Average front used by gradients / legacy edgeX consumers.
  const edgeX = (topX + bottomX) * 0.5;

  // Crease bows into the remaining page; peak follows touch Y slightly.
  const midY = h * (0.48 + touch * 0.22);
  const lean = Math.abs(topX - bottomX);
  const curveAmp = foldVisibleAmp(p, w, peelEnvelope, lean);
  const bowX = fromRight
    ? edgeX - curveAmp
    : edgeX + curveAmp;

  // Flap: narrow at top, broad at bottom — triangular peeled sheet.
  const foldVisible = p > 0.008 && p < 0.992;
  const flapTop = foldVisible ? w * (0.014 + 0.04 * peelEnvelope) : 0;
  const flapBottom = foldVisible
    ? w * (0.075 + 0.145 * peelEnvelope) + lean * 0.28
    : 0;
  const foldWidth = flapBottom; // max flap depth (for asserts / gradients)
  const tipY = h * (0.62 + touch * 0.12);
  const tipExtra = foldVisible ? w * (0.02 + 0.06 * peelEnvelope) + lean * 0.12 : 0;

  let topOuter;
  let bottomOuter;
  let tipX;
  if (fromRight) {
    topOuter = Math.min(w, topX + flapTop);
    bottomOuter = Math.min(w, bottomX + flapBottom);
    tipX = Math.min(w, lerp(topOuter, bottomOuter, tipY / h) + tipExtra);
  } else {
    topOuter = Math.max(0, topX - flapTop);
    bottomOuter = Math.max(0, bottomX - flapBottom);
    tipX = Math.max(0, lerp(topOuter, bottomOuter, tipY / h) - tipExtra);
  }
  const outerMid = tipX;

  let flatPath;
  let foldPath = "";
  let shadowPath = "";
  let highlightPath = "";
  let castShadowPath = "";
  let creaseShadowPath = "";

  // Reflection transform across the diagonal crease line (topX, 0) → (bottomX, h)
  // so the backside of the curled flap shows the optically mirrored page texture.
  const creaseAngleRad = -Math.atan2(bottomX - topX, h);
  const creaseAngleDeg = px((creaseAngleRad * 180) / Math.PI);
  const bleedTransform =
    `translate(${px(topX)}px, 0px) `
    + `rotate(${creaseAngleDeg}deg) `
    + `scaleX(-1) `
    + `rotate(${px(-creaseAngleDeg)}deg) `
    + `translate(${px(-topX)}px, 0px)`;

  if (p <= 0) {
    flatPath = `M 0 0 L ${px(w)} 0 L ${px(w)} ${px(h)} L 0 ${px(h)} Z`;
  } else if (p >= 1) {
    flatPath = fromRight
      ? `M 0 0 L 0 0 L 0 ${px(h)} L 0 ${px(h)} Z`
      : `M ${px(w)} 0 L ${px(w)} 0 L ${px(w)} ${px(h)} L ${px(w)} ${px(h)} Z`;
  } else {
    const crease = diagonalCreasePath(topX, bottomX, bowX, midY, h, false);
    const creaseRev = diagonalCreasePath(topX, bottomX, bowX, midY, h, true);
    if (fromRight) {
      flatPath = `M 0 0 L ${crease} L 0 ${px(h)} Z`;
    } else {
      flatPath = `M ${px(w)} 0 L ${crease} L ${px(w)} ${px(h)} Z`;
    }

    const outer = diagonalFlapOuterPath(topOuter, bottomOuter, tipX, tipY, h, true);
    foldPath = `M ${crease} L ${outer} Z`;

    // Inner flap self-shadow band: same diagonal, shallower flap depth.
    const shadowTop = fromRight
      ? Math.min(w, topX + flapTop * 0.48)
      : Math.max(0, topX - flapTop * 0.48);
    const shadowBottom = fromRight
      ? Math.min(w, bottomX + flapBottom * 0.48)
      : Math.max(0, bottomX - flapBottom * 0.48);
    const shadowTip = fromRight
      ? Math.min(w, lerp(shadowTop, shadowBottom, tipY / h) + tipExtra * 0.35)
      : Math.max(0, lerp(shadowTop, shadowBottom, tipY / h) - tipExtra * 0.35);
    shadowPath = `M ${crease} L ${diagonalFlapOuterPath(shadowTop, shadowBottom, shadowTip, tipY, h, true)} Z`;

    // Cast drop shadow projected onto the revealed next page underneath the flap.
    const castExtraTop = flapTop * 1.45 + w * 0.028 * peelEnvelope;
    const castExtraBottom = flapBottom * 1.32 + w * 0.055 * peelEnvelope;
    const castTop = fromRight
      ? Math.min(w, topX + castExtraTop)
      : Math.max(0, topX - castExtraTop);
    const castBottom = fromRight
      ? Math.min(w, bottomX + castExtraBottom)
      : Math.max(0, bottomX - castExtraBottom);
    const castTip = fromRight
      ? Math.min(w, lerp(castTop, castBottom, tipY / h) + tipExtra * 1.25)
      : Math.max(0, lerp(castTop, castBottom, tipY / h) - tipExtra * 1.25);
    castShadowPath = `M ${crease} L ${diagonalFlapOuterPath(castTop, castBottom, castTip, tipY, h, true)} Z`;

    // Soft highlight on the readable side of the crease (cylindrical crest).
    const hi = Math.min(curveAmp * 0.48, w * 0.022);
    const hiTop = fromRight ? Math.max(0, topX - hi) : Math.min(w, topX + hi);
    const hiBottom = fromRight ? Math.max(0, bottomX - hi) : Math.min(w, bottomX + hi);
    const hiBow = fromRight ? bowX - hi * 0.6 : bowX + hi * 0.6;
    const hiCrease = diagonalCreasePath(hiTop, hiBottom, hiBow, midY, h, false);
    highlightPath = `M ${hiCrease} L ${creaseRev} Z`;

    // Subtle concave valley shading just inside the readable page before the fold.
    const valley = Math.min(curveAmp * 1.15, w * 0.045);
    const valTop = fromRight ? Math.max(0, topX - valley) : Math.min(w, topX + valley);
    const valBottom = fromRight ? Math.max(0, bottomX - valley) : Math.min(w, bottomX + valley);
    const valBow = fromRight ? bowX - valley * 0.75 : bowX + valley * 0.75;
    const valCrease = diagonalCreasePath(valTop, valBottom, valBow, midY, h, false);
    creaseShadowPath = `M ${valCrease} L ${creaseRev} Z`;
  }

  const foldOpacity = foldVisible ? Math.min(0.98, 0.62 + p * 0.34) : 0;
  const shadowOpacity = foldVisible ? Math.min(0.24, 0.08 + peelEnvelope * 0.15) : 0;
  const highlightOpacity = foldVisible ? Math.min(0.36, 0.12 + peelEnvelope * 0.20) : 0;
  const castShadowOpacity = foldVisible ? Math.min(0.32, 0.10 + peelEnvelope * 0.22) : 0;
  const creaseShadowOpacity = foldVisible ? Math.min(0.14, 0.04 + peelEnvelope * 0.10) : 0;

  return {
    progress: p,
    remain,
    edgeX,
    topX,
    bottomX,
    height: h,
    width: w,
    /** @deprecated alias kept for gesture field / older asserts — touch-Y bias */
    bulgeY: ty,
    touchY: ty,
    foldWidth,
    curveAmp,
    outerMid,
    topOuter,
    bottomOuter,
    tipX,
    tipY,
    midY,
    bowX,
    flatPath,
    foldPath,
    shadowPath,
    highlightPath,
    castShadowPath,
    creaseShadowPath,
    creaseAngleDeg,
    bleedTransform,
    /** CSS clip-path value for the flat snapshot layer. */
    clipPath: `path("${flatPath}")`,
    foldOpacity,
    shadowOpacity,
    highlightOpacity,
    castShadowOpacity,
    creaseShadowOpacity,
    foldVisible,
    // Contract: the flat sheet must stay undistorted.
    sheetTranslateX: 0,
    sheetRotateY: 0,
    sheetSkewY: 0,
    sheetScaleX: 1,
  };
}

function foldVisibleAmp(p, w, peelEnvelope, lean) {
  if (p <= 0.008 || p >= 0.992) return 0;
  // Modest bow so the crease reads as paper, not a hard diagonal line.
  return w * (0.012 + 0.055 * peelEnvelope) + lean * 0.08;
}

/** Parse CSS hex or rgb() color into {r, g, b} 0..255. */
function parsePaperRGB(css) {
  if (typeof css !== "string") return { r: 247, g: 243, b: 234 };
  const s = css.trim().toLowerCase();
  if (s.startsWith("#")) {
    const hex = s.slice(1).replace(/[^0-9a-f]/g, "");
    if (hex.length === 3) {
      return {
        r: parseInt(hex[0] + hex[0], 16),
        g: parseInt(hex[1] + hex[1], 16),
        b: parseInt(hex[2] + hex[2], 16),
      };
    }
    if (hex.length >= 6) {
      return {
        r: parseInt(hex.slice(0, 2), 16),
        g: parseInt(hex.slice(2, 4), 16),
        b: parseInt(hex.slice(4, 6), 16),
      };
    }
  }
  if (s.startsWith("rgb")) {
    const parts = s.match(/\d+(\.\d+)?/g);
    if (parts && parts.length >= 3) {
      return {
        r: Math.min(255, Math.max(0, Math.round(Number(parts[0])))),
        g: Math.min(255, Math.max(0, Math.round(Number(parts[1])))),
        b: Math.min(255, Math.max(0, Math.round(Number(parts[2])))),
      };
    }
  }
  return { r: 247, g: 243, b: 234 };
}

function computeThemePaperStops(paperColor) {
  const { r, g, b } = parsePaperRGB(paperColor);
  const lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  const clampByte = (v) => Math.min(255, Math.max(0, Math.round(v)));
  const rgbStr = (dr, dg, db) =>
    `rgb(${clampByte(r + dr)}, ${clampByte(g + dg)}, ${clampByte(b + db)})`;

  if (lum < 0.35) {
    return {
      isDark: true,
      stopA: rgbStr(26, 26, 28),
      stopB: rgbStr(12, 12, 14),
      stopC: rgbStr(-8, -8, -8),
      bleedOpacity: 0.09,
      highlightFill: "rgba(255, 255, 255, 0.11)",
    };
  }
  return {
    isDark: false,
    stopA: rgbStr(6, 5, 3),
    stopB: rgbStr(-13, -15, -18),
    stopC: rgbStr(-30, -33, -38),
    bleedOpacity: 0.14,
    highlightFill: "rgba(255, 255, 255, 0.32)",
  };
}

export default class PageTurnAnimator {
  #style = "slide";
  #reduceMotion = false;
  #readAloudActive = false;
  #nativeSpread = false;
  #originalAnimated = new WeakMap();
  #renderer = null;
  #host = null;

  #phase = "idle"; // idle | pending | curling | completing | cancelling
  #visualMode = "curl"; // curl | slide
  #gesture = null;
  #overlay = null;
  #underlay = null;
  #sheet = null;
  #bleedWrap = null;
  #bleedImg = null;
  #shapesSvg = null;
  #castShadowPath = null;
  #creaseShadowPath = null;
  #backPath = null;
  #shadowPath = null;
  #highlightPath = null;
  #backGrad = null;
  #shadowGrad = null;
  #castGrad = null;
  #creaseGrad = null;
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

  /** Idle pre-cached snapshot for 0ms turn start on finger drag or margin tap. */
  #idleSnapshotRequestId = 0;
  #idleSnapshotTimer = 0;
  #cachedSnapshotUrl = null;
  #cachedSnapshotKey = null;
  #snapshotWaiters = new Map();

  /** Wrapped paginator methods so destination page stays stationary under curl/slide. */
  #origScrollBy = null;
  #origSnap = null;
  #targetPageParked = false;
  #parkedDelta = 0;

  /** True while native chrome should stay hidden for an in-flight curl. */
  #chromeSuppressed = false;

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
      this.cancel({ reason: "style-change", durationMs: 0 });
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

  /** iPad spread: the native .mid-spine UIPageViewController owns curl when active. */
  setNativeSpread(enabled) {
    this.#nativeSpread = !!enabled;
    if (this.#nativeSpread && this.#phase !== "idle") {
      this.cancel({ reason: "native-spread", durationMs: 0 });
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

  /** Cached snapshot data URL from idle pre-capture, if available. */
  get cachedSnapshotUrl() {
    return this.#cachedSnapshotUrl;
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
    if (this.#nativeSpread) return false;
    if (this.#renderer?.scrolled) return false;
    return true;
  }

  /** Whether a GPU sheet slide or curl animation can run right now. */
  get canAnimateTurn() {
    const eff = this.effectiveStyle;
    if (eff !== "curl" && eff !== "slide") return false;
    if (this.#readAloudActive) return false;
    if (eff === "curl" && this.#nativeSpread) return false;
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

    this.#installRendererHooks(renderer);

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
    this.#restoreRendererHooks();
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
    this.#clearIdleSnapshotTimer();
    this.#cachedSnapshotUrl = null;
    this.#cachedSnapshotKey = null;
    this.#cleanupOverlay();
    this.#invalidateSnapshot("detach");
    this.#setChromeSuppressed(false);
    this.#phase = "idle";
    this.#gesture = null;
    this.#renderer = null;
    this.#bound = false;
  }

  // --- Idle Snapshot Pre-Caching & Programmatic Turns -----------------------

  /**
   * Called by FoliateManager when a page finishes relocating / rendering so we
   * pre-cache the current viewport image in the background (0ms turn start).
   */
  notifyPageSettled() {
    if (!this.#bound || !this.#renderer || this.#renderer.scrolled) return;
    if (this.#readAloudActive || this.effectiveStyle === "instant") return;
    this.#scheduleIdleSnapshot(IDLE_CACHE_DELAY_MS);
  }

  /** Invalidate cached page image on style/theme/font/spread change. */
  invalidateCachedSnapshot() {
    this.#clearIdleSnapshotTimer();
    this.#idleSnapshotRequestId = 0;
    this.#cachedSnapshotUrl = null;
    this.#cachedSnapshotKey = null;
  }

  #currentSnapshotKey() {
    const r = this.#renderer;
    const w = this.#host?.clientWidth || r?.size || 0;
    const h = this.#host?.clientHeight || 0;
    const start = Math.round(r?.start ?? 0);
    const page = r?.page ?? 0;
    const paper = this.#paperColor();
    return `${start}:${page}:${w}x${h}:${paper}`;
  }

  #scheduleIdleSnapshot(delayMs = IDLE_CACHE_DELAY_MS) {
    this.#clearIdleSnapshotTimer();
    if (!this.#bound || !this.#renderer) return;
    if (!globalThis.window?.webkit?.messageHandlers?.RequestPageSnapshot?.postMessage) {
      return;
    }
    this.#idleSnapshotTimer = setTimeout(() => {
      this.#idleSnapshotTimer = 0;
      if (this.#phase !== "idle" || this.#overlay) return;
      if (!this.#renderer || this.#renderer.scrolled || this.#readAloudActive) return;
      if (this.effectiveStyle === "instant") return;
      const key = this.#currentSnapshotKey();
      if (this.#cachedSnapshotUrl && this.#cachedSnapshotKey === key) return;
      this.#requestIdleSnapshot(key);
    }, delayMs);
  }

  #clearIdleSnapshotTimer() {
    if (this.#idleSnapshotTimer) {
      clearTimeout(this.#idleSnapshotTimer);
      this.#idleSnapshotTimer = 0;
    }
  }

  #requestIdleSnapshot(key) {
    const handler = globalThis.window?.webkit?.messageHandlers?.RequestPageSnapshot;
    if (!handler?.postMessage) return 0;
    const id = ++this.#snapshotRequestId;
    this.#idleSnapshotRequestId = id;
    this.#cachedSnapshotKey = key;
    try {
      handler.postMessage({
        requestId: id,
        fillColor: this.#paperColor(),
      });
    } catch {
      this.#idleSnapshotRequestId = 0;
    }
    return id;
  }

  /**
   * Animate a programmatic page turn (margin tap, keyboard arrow, button) using
   * either Apple Books Curl or Apple Books GPU Slide.
   *
   * @param {object} options
   * @param {"left"|"right"} options.direction Visual screen direction ("right" = forward in LTR)
   * @param {() => (Promise<any>|any)} options.navigate Callback that advances Foliate
   * @param {() => (string|number|null)} [options.position] Optional position token to detect no-op at book ends
   */
  async performTurn({ direction = "right", navigate, position = null } = {}) {
    if (typeof navigate !== "function") return;

    // If a previous completion/cancel animation is still finishing, wrap it up
    // immediately so rapid margin taps never get dropped.
    if (this.#phase === "completing" || this.#phase === "cancelling") {
      this.#cleanupOverlay();
      this.#resetGesture();
    }

    if (!this.canAnimateTurn || this.#phase !== "idle") {
      return navigate();
    }

    const renderer = this.#renderer;
    const rtl = renderer?.getAttribute?.("dir") === "rtl";
    const fromRight = direction !== "left";
    const goingForward = rtl ? !fromRight : fromRight;

    // Never animate a fake turn past the start/end of the book.
    if ((goingForward && renderer?.atEnd) || (!goingForward && renderer?.atStart)) {
      return navigate();
    }

    const width = this.#host?.clientWidth || renderer?.size || 0;
    const height = this.#host?.clientHeight || 0;
    if (!width || !height) {
      return navigate();
    }

    let sourceUrl = this.#consumeFreshSnapshotUrl();
    if (!sourceUrl && globalThis.window?.webkit?.messageHandlers?.RequestPageSnapshot?.postMessage) {
      sourceUrl = await this.#awaitQuickSnapshot(120);
    }
    if (!sourceUrl) {
      return navigate();
    }

    const mode = this.effectiveStyle === "curl" ? "curl" : "slide";
    const paperColor = this.#paperColor();
    const isBoundary = this.#isAtSectionBoundary(goingForward);

    try {
      this.#mountOverlay({
        width,
        height,
        fromRight,
        sourceUrl,
        paperColor,
        mode,
        transparentUnderlay: !isBoundary,
      });
    } catch {
      this.#cleanupOverlay();
      return navigate();
    }

    this.#phase = "curling";
    this.#progress = 0;
    this.#gesture = {
      fromRight,
      goingForward,
      rtl,
      width,
      height,
      bulgeY: 0.54, // Natural lower-middle Apple Books corner lift on tap
      fingerProgress: 0,
      directionLocked: true,
      moved: true,
      isProgrammatic: true,
    };
    this.#setChromeSuppressed(true);
    this.#applyVisual(0);

    const beforePos = typeof position === "function" ? position() : null;
    const hadAnimated = renderer?.hasAttribute?.("animated");
    renderer?.removeAttribute?.("animated");

    try {
      await navigate();
    } finally {
      if (hadAnimated) this.applyToRenderer(renderer);
    }

    const afterPos = typeof position === "function" ? position() : null;
    if (beforePos !== null && afterPos !== null && afterPos === beforePos) {
      // Navigation was a no-op (e.g. book boundary); drop overlay without animating.
      this.#cleanupOverlay();
      this.#resetGesture();
      return;
    }

    // Reveal the newly loaded page underneath even if it crossed a section boundary.
    if (this.#underlay) {
      this.#underlay.style.backgroundColor = "transparent";
    }

    const durationMs = mode === "curl" ? TAP_CURL_MS : TAP_SLIDE_MS;
    this.#phase = "completing";
    await new Promise((resolve) => {
      this.#animateProgress(0, 1, durationMs, () => {
        this.#cleanupOverlay();
        this.#resetGesture();
        this.notifyPageSettled();
        resolve();
      });
    });
  }

  #consumeFreshSnapshotUrl() {
    if (this.#cachedSnapshotUrl) {
      const url = this.#cachedSnapshotUrl;
      this.#cachedSnapshotUrl = null;
      return url;
    }
    if (this.#pendingSnapshotUrl) {
      const url = this.#pendingSnapshotUrl;
      this.#pendingSnapshotUrl = null;
      return url;
    }
    return null;
  }

  #awaitQuickSnapshot(timeoutMs = 120) {
    const reqId = this.#requestNativeSnapshot();
    if (this.#snapshotFailed || !reqId) return Promise.resolve(null);
    return new Promise((resolve) => {
      const timer = setTimeout(() => {
        this.#snapshotWaiters.delete(reqId);
        resolve(null);
      }, timeoutMs);
      this.#snapshotWaiters.set(reqId, (url) => {
        clearTimeout(timer);
        resolve(url);
      });
    });
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
    const validImage = typeof dataUrl === "string" && dataUrl.startsWith("data:image/");

    const waiter = this.#snapshotWaiters.get(requestId);
    if (waiter) {
      this.#snapshotWaiters.delete(requestId);
      waiter(validImage ? dataUrl : null);
    }

    // Background idle pre-cache reply.
    if (requestId === this.#idleSnapshotRequestId && requestId !== 0) {
      this.#idleSnapshotRequestId = 0;
      if (validImage && this.#phase === "idle" && !this.#overlay) {
        this.#cachedSnapshotUrl = dataUrl;
        debugLog("PageTurnAnimator", "idle snapshot cached", {
          requestId,
          bytes: dataUrl.length,
        });
      }
      if (requestId !== this.#pendingSnapshotRequestId) {
        return;
      }
    }

    // Accept only the currently outstanding request. Phase may still be idle for
    // a beat while touchstart arms the gesture, so do not require pending here.
    if (requestId !== this.#pendingSnapshotRequestId || requestId === 0) {
      debugLog("PageTurnAnimator", "reject stale snapshot", {
        requestId,
        expected: this.#pendingSnapshotRequestId,
      });
      return;
    }

    if (!validImage) {
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
    this.#cachedSnapshotUrl = dataUrl;
    this.#cachedSnapshotKey = this.#currentSnapshotKey();
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
    const requestedMode = context.mode === "slide" ? "slide" : "curl";
    if (requestedMode === "curl" ? !this.canCurl : !this.canAnimateTurn) {
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

    const width = context.width
      ?? this.#host?.clientWidth
      ?? this.#renderer?.size
      ?? 0;
    const height = context.height ?? this.#host?.clientHeight ?? 0;
    if (!width || !height) {
      debugLog("PageTurnAnimator", "curl fallback: missing viewport geometry");
      this.#fallbackThisGesture = true;
      return false;
    }

    const fromRight = context.fromRight !== false;
    const rtl = !!context.rtl;
    const goingForward = context.goingForward ?? (rtl ? !fromRight : fromRight);
    // Prefer an explicit sourceUrl (tests / late injection); else the pending
    // native snapshot. Never invent a JS page clone or paint a blank sheet.
    const sourceUrl = context.sourceUrl ?? this.#pendingSnapshotUrl ?? null;
    if (!sourceUrl) {
      debugLog("PageTurnAnimator", "curl fallback: no native snapshot image");
      this.#fallbackThisGesture = true;
      return false;
    }

    const transparentUnderlay =
      context.transparentUnderlay !== undefined
        ? !!context.transparentUnderlay
        : !this.#isAtSectionBoundary(goingForward);

    try {
      this.#mountOverlay({
        width,
        height,
        fromRight,
        sourceUrl,
        paperColor: context.paperColor ?? "#f7f3ea",
        mode: requestedMode,
        transparentUnderlay,
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
      goingForward,
      rtl,
      width,
      height,
      startOffset: context.startOffset ?? prior?.startOffset ?? this.#renderer?.start ?? 0,
      startX: context.startX ?? prior?.startX,
      startY: context.startY ?? prior?.startY,
      lastX: context.lastX ?? prior?.lastX,
      lastMoveTime: prior?.lastMoveTime ?? 0,
      velocityPxPerMs: prior?.velocityPxPerMs ?? 0,
      bulgeY: context.bulgeY ?? prior?.bulgeY ?? 0.5,
      fingerProgress: initialProgress,
      directionLocked: true,
      moved: true,
      doc: context.doc ?? prior?.doc,
      isTouchGesture: !!prior?.isTouchGesture,
    };
    this.#setChromeSuppressed(true);
    if (this.#gesture.isTouchGesture && transparentUnderlay) {
      this.#parkRendererAtTargetPage();
    }
    this.#applyVisual(initialProgress);
    debugLog("PageTurnAnimator", "curl begin", {
      mode: requestedMode,
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
    const scaledDuration = Math.round(130 + (1 - from) * (COMPLETE_MS - 60));
    const durationMs = context.durationMs ?? scaledDuration;
    this.#animateProgress(from, 1, durationMs, () => {
      this.#cleanupOverlay();
      this.#resetGesture();
      this.notifyPageSettled();
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
    const scaledDuration = Math.round(110 + from * (CANCEL_MS - 60));
    const durationMs = context.durationMs ?? scaledDuration;
    this.#animateProgress(from, 0, durationMs, () => {
      this.#unparkRendererToStart();
      this.#cleanupOverlay();
      this.#resetGesture();
    });
  }

  // --- Renderer hooks for stationary target page & velocity-assisted snap ---

  #installRendererHooks(renderer) {
    if (typeof renderer?.scrollBy === "function" && !this.#origScrollBy) {
      this.#origScrollBy = renderer.scrollBy.bind(renderer);
      renderer.scrollBy = (dx, dy) => {
        // While an interactive overlay has parked the live paginator at the
        // destination page, suppress intermediate scrollLeft thrashing.
        if (this.#targetPageParked && this.#overlay && this.#phase === "curling") {
          return;
        }
        return this.#origScrollBy(dx, dy);
      };
    }

    if (typeof renderer?.snap === "function" && !this.#origSnap) {
      this.#origSnap = renderer.snap.bind(renderer);
      renderer.snap = (vx, vy) => {
        const gesture = this.#gesture;
        if (!gesture || !gesture.moved) {
          return this.#origSnap(vx, vy);
        }

        const shouldCommit = this.#shouldCommitGesture(gesture);
        const rtl = renderer.getAttribute?.("dir") === "rtl" || !!gesture.rtl;
        const size = Math.max(1, renderer.size || gesture.width || 1);

        // When our GPU overlay is handling the visual completion/cancel,
        // settle Foliate's underlying scrollLeft instantaneously (0ms).
        const hadAnimated = this.#overlay && renderer.hasAttribute?.("animated");
        if (hadAnimated) renderer.removeAttribute("animated");

        try {
          if (shouldCommit) {
            const forwardSign = rtl ? -1 : 1;
            const dirSign = gesture.goingForward ? forwardSign : -forwardSign;
            this.#targetPageParked = false;
            this.#origScrollBy?.(dirSign * size, 0);
            const commitVx = gesture.goingForward ? forwardSign * 0.85 : -forwardSign * 0.85;
            return this.#origSnap(commitVx, vy);
          } else {
            this.#unparkRendererToStart();
            return this.#origSnap(0, vy);
          }
        } finally {
          if (hadAnimated) {
            this.applyToRenderer(renderer);
          }
        }
      };
    }
  }

  #restoreRendererHooks() {
    if (this.#renderer) {
      if (this.#origScrollBy) {
        this.#renderer.scrollBy = this.#origScrollBy;
      }
      if (this.#origSnap) {
        this.#renderer.snap = this.#origSnap;
      }
      if (this.#renderer.style) {
        this.#renderer.style.transform = "";
      }
    }
    this.#origScrollBy = null;
    this.#origSnap = null;
    this.#targetPageParked = false;
    this.#parkedDelta = 0;
  }

  #isAtSectionBoundary(goingForward) {
    const r = this.#renderer;
    if (!r || typeof r.page !== "number" || typeof r.pages !== "number") return false;
    const targetPage = goingForward ? r.page + 1 : r.page - 1;
    return targetPage <= 0 || targetPage >= r.pages - 1;
  }

  #parkRendererAtTargetPage() {
    const r = this.#renderer;
    const gesture = this.#gesture;
    if (!r || !gesture || !this.#origScrollBy || this.#targetPageParked) return;
    if (this.#isAtSectionBoundary(gesture.goingForward)) return;

    const size = Math.max(1, r.size || gesture.width || 1);
    const rtl = r.getAttribute?.("dir") === "rtl" || !!gesture.rtl;
    const currentDelta = (r.start ?? 0) - (gesture.startOffset ?? 0);
    const desiredAbsDelta = gesture.goingForward ? size : -size;
    const needed = (rtl ? -1 : 1) * (desiredAbsDelta - currentDelta);
    this.#origScrollBy(needed, 0);
    this.#parkedDelta = (rtl ? -1 : 1) * desiredAbsDelta;
    this.#targetPageParked = true;
  }

  #unparkRendererToStart() {
    if (!this.#targetPageParked || !this.#origScrollBy || !this.#renderer) {
      this.#targetPageParked = false;
      this.#parkedDelta = 0;
      return;
    }
    const deltaBack = -this.#parkedDelta;
    this.#targetPageParked = false;
    this.#parkedDelta = 0;
    this.#origScrollBy(deltaBack, 0);
  }

  #shouldCommitGesture(gesture) {
    if (!gesture || !gesture.moved) return false;
    const r = this.#renderer;
    if ((gesture.goingForward && r?.atEnd) || (!gesture.goingForward && r?.atStart)) {
      return false;
    }
    const progress = gesture.fingerProgress ?? this.#progress ?? 0;
    const vel = gesture.velocityPxPerMs ?? 0; // positive = in turn direction
    if (vel < -0.22) return false; // User flicked back toward origin
    if (progress >= SWIPE_COMMIT_PROGRESS) return true;
    if (vel >= SWIPE_COMMIT_VELOCITY && progress >= 0.025) return true;
    return false;
  }

  // --- Gesture observation (paginator remains source of truth) -------------

  #handleTouchStart(event) {
    if (!this.canAnimateTurn) return;
    if (this.#phase === "completing" || this.#phase === "cancelling") {
      this.#cleanupOverlay();
      this.#resetGesture();
    }
    if (this.#phase !== "idle") return;
    const touch = event.changedTouches?.[0];
    if (!touch) return;

    const renderer = this.#renderer;
    if (!renderer || renderer.scrolled) return;

    this.#clearIdleSnapshotTimer();
    this.#fallbackThisGesture = false;
    this.#pageFlipSeen = false;
    this.#awaitingSnap = false;
    this.#progress = 0;
    // Arm the gesture before requesting so a fast native reply is not rejected.
    this.#phase = "pending";
    const startX = touch.screenX ?? touch.clientX;
    const startY = touch.screenY ?? touch.clientY;
    const hostHeight =
      this.#host?.clientHeight || renderer.getBoundingClientRect?.().height || 0;
    // Prefer host width so the sheet matches the WKWebView snapshot bounds.
    const hostWidth = this.#host?.clientWidth || renderer.size || 0;
    this.#gesture = {
      startX,
      startY,
      lastX: startX,
      lastMoveTime: performance.now(),
      velocityPxPerMs: 0,
      startOffset: renderer.start, // paginator scroll — fallback progress only
      fromRight: true,
      goingForward: true,
      rtl: renderer.getAttribute?.("dir") === "rtl",
      width: hostWidth || renderer.size,
      height: hostHeight,
      // Lock fold peak to touch Y at gesture start (no live wobble).
      bulgeY: this.#bulgeYFromClientY(touch.clientY, hostHeight),
      moved: false,
      directionLocked: false,
      fingerProgress: 0,
      isTouchGesture: true,
      // Touched section doc kept for paperColor under the snapshot only.
      doc: docFromTouchEvent(event) || this.#currentDoc(),
    };

    // Use the idle pre-cached snapshot immediately (0ms latency) when available!
    if (this.#cachedSnapshotUrl) {
      this.#pendingSnapshotUrl = this.#cachedSnapshotUrl;
      this.#snapshotFailed = false;
    } else if (this.effectiveStyle === "curl" || this.effectiveStyle === "slide") {
      // Fallback: capture the current rendered page before the paginator scrolls.
      this.#requestNativeSnapshot();
    }
  }

  /**
   * Finger-driven visual progress. Foliate still owns snap / page selection;
   * this only updates the peel/slide geometry so the sheet tracks the finger.
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
    const now = performance.now();
    const prevX = gesture.lastX ?? gesture.startX ?? x;
    const dt = Math.max(1, now - (gesture.lastMoveTime || now - 8));
    const stepDx = x - prevX;

    gesture.lastX = x;
    gesture.lastMoveTime = now;
    // Keep visual size synced to the host (snapshot viewport); do not retarget bulgeY.
    gesture.width = this.#host?.clientWidth || renderer.size || gesture.width;
    gesture.height = this.#host?.clientHeight || gesture.height;

    const dx = x - gesture.startX;
    if (!gesture.moved) {
      if (Math.abs(dx) < 2) return;
      this.#lockDirectionFromDelta(dx > 0 ? 1 : -1, /* fromFinger */ true);
      if (!gesture.moved) return;

      // Consume the cached snapshot now that a real drag has begun.
      this.#cachedSnapshotUrl = null;

      // Real drag started — hide floating chrome for the curl lifetime.
      this.#setChromeSuppressed(true);

      if (this.#snapshotFailed && this.effectiveStyle === "curl") {
        debugLog("PageTurnAnimator", "curl fallback: snapshot unavailable at drag start");
        this.#resetGesture();
        this.#fallbackThisGesture = true;
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

    // Smoothed velocity in the locked turn direction (positive = advancing turn).
    if (Math.abs(stepDx) > 0.2 || dt > 24) {
      const signedStep = gesture.fromRight !== false ? -stepDx : stepDx;
      const instVel = signedStep / dt;
      gesture.velocityPxPerMs = gesture.velocityPxPerMs * 0.45 + instVel * 0.55;
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
      gesture.width = this.#host?.clientWidth || renderer.size || gesture.width;
      gesture.height = this.#host?.clientHeight || gesture.height;

      this.#cachedSnapshotUrl = null;

      // Real drag started — hide floating chrome for the curl lifetime.
      this.#setChromeSuppressed(true);

      if (this.#snapshotFailed && this.effectiveStyle === "curl") {
        debugLog("PageTurnAnimator", "curl fallback: snapshot unavailable at drag start");
        this.#resetGesture();
        this.#fallbackThisGesture = true;
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
    gesture.goingForward = goingForward;
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

  /**
   * Map clientY within the reader host to a diagonal-peel touch bias.
   * Locked per gesture; rotates top/bottom crease endpoints (not a vertical bulge slide).
   */
  #bulgeYFromClientY(clientY, hostHeight) {
    const h = Math.max(1, hostHeight || this.#host?.clientHeight || 1);
    let norm = 0.5;
    if (Number.isFinite(clientY) && this.#host?.getBoundingClientRect) {
      try {
        const top = this.#host.getBoundingClientRect().top;
        norm = clamp01((clientY - top) / h);
      } catch {
        norm = 0.5;
      }
    } else if (Number.isFinite(clientY) && h > 1) {
      norm = clamp01(clientY / h);
    }
    // Keep full-page Y influence, but clamp into the diagonal-safe band.
    return clampTouchY(0.5 + (norm - 0.5) * 0.7);
  }

  #handleTouchEnd() {
    if (this.#phase === "pending" && !this.#gesture?.moved) {
      // Tap / no drag — nothing to curl. Preserve cached snapshot for tap turns!
      const savedCache = this.#cachedSnapshotUrl;
      this.#resetGesture();
      this.#cachedSnapshotUrl = savedCache;
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
          if (this.#pageFlipSeen || this.#shouldCommitGesture(this.#gesture)) {
            this.complete();
          } else {
            this.cancel({ reason: "snap-timeout" });
          }
        }
      }, 450);
    }
  }

  #handlePageFlip() {
    if (this.#phase !== "curling" && this.#phase !== "pending") return;
    if (this.#gesture?.isProgrammatic) return;
    this.#pageFlipSeen = true;
    if (this.#phase === "pending" && !this.#overlay) {
      // Flip happened before we could mount a curl sheet — let Foliate win.
      this.#resetGesture();
      return;
    }
    // Foliate has accepted the turn; finish the visual curl.
    if (this.#underlay) {
      this.#underlay.style.backgroundColor = "transparent";
    }
    this.complete();
  }

  #handleRelocate(event) {
    const reason = event?.detail?.reason;
    if (reason !== "snap") return;
    if (this.#gesture?.isProgrammatic) return;
    if (this.#phase !== "curling" && !(this.#phase === "pending" && this.#awaitingSnap)) {
      return;
    }
    if (this.#pageFlipSeen) return; // complete() already running
    // Snap without page change ⇒ cancelled turn.
    this.cancel({ reason: "snap-cancel" });
  }

  #handleOrientationChange() {
    this.invalidateCachedSnapshot();
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

    // Drop in-webview selection chrome so it cannot appear in the JPEG sheet.
    try {
      globalThis.window?.foliateManager?.hideSelectionToolbarForSnapshot?.();
    } catch {
      /* ignore */
    }

    const handler = globalThis.window?.webkit?.messageHandlers?.RequestPageSnapshot;
    if (!handler?.postMessage) {
      this.#snapshotFailed = true;
      debugLog("PageTurnAnimator", "curl fallback: no RequestPageSnapshot bridge");
      return id;
    }

    try {
      // fillColor lets native composite transparent gutters onto paper before JPEG
      // (JPEG has no alpha — clear pixels otherwise become black bars).
      handler.postMessage({
        requestId: id,
        fillColor: this.#paperColor(this.#gesture?.doc),
      });
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
    const mode = this.effectiveStyle === "curl" ? "curl" : "slide";
    const started = this.begin({
      mode,
      fromRight: gesture.fromRight,
      goingForward: gesture.goingForward,
      rtl: gesture.rtl,
      width: gesture.width,
      height: gesture.height,
      startOffset: gesture.startOffset,
      startX: gesture.startX,
      startY: gesture.startY,
      lastX: gesture.lastX,
      bulgeY: gesture.bulgeY,
      progress,
      sourceUrl,
      paperColor: this.#paperColor(gesture.doc),
      doc: gesture.doc,
    });
    if (!started) {
      this.#resetGesture();
      this.#fallbackThisGesture = true;
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
    for (const resolve of this.#snapshotWaiters.values()) {
      resolve(null);
    }
    this.#snapshotWaiters.clear();
    if (reason) debugLog("PageTurnAnimator", "snapshot invalidated", reason);
  }

  #clearSnapshotTimer() {
    if (this.#snapshotTimer) {
      clearTimeout(this.#snapshotTimer);
      this.#snapshotTimer = 0;
    }
  }

  // --- Visual layer (Apple Books curl & GPU slide) -------------------------

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
        background: transparent;
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
        will-change: clip-path, transform;
        background-size: 100% 100%;
        background-repeat: no-repeat;
        background-position: left top;
        background-color: transparent;
        transform: none;
      }
      #${OVERLAY_ID} .inkamp-curl-back-bleed {
        position: absolute;
        inset: 0;
        z-index: 2;
        width: 100%;
        height: 100%;
        overflow: hidden;
        pointer-events: none;
        will-change: clip-path;
      }
      #${OVERLAY_ID} .inkamp-curl-back-bleed-img {
        position: absolute;
        inset: 0;
        width: 100%;
        height: 100%;
        background-size: 100% 100%;
        background-repeat: no-repeat;
        background-position: left top;
        transform-origin: 0 0;
        will-change: transform;
      }
      #${OVERLAY_ID} .inkamp-curl-shapes {
        position: absolute;
        inset: 0;
        z-index: 3;
        width: 100%;
        height: 100%;
        overflow: hidden;
        pointer-events: none;
        background: transparent;
      }
      #${OVERLAY_ID} .inkamp-curl-cast-shadow,
      #${OVERLAY_ID} .inkamp-curl-crease-shadow,
      #${OVERLAY_ID} .inkamp-curl-back,
      #${OVERLAY_ID} .inkamp-curl-shadow,
      #${OVERLAY_ID} .inkamp-curl-highlight {
        opacity: 0;
      }
    `;
    document.head.appendChild(style);
  }

  #mountOverlay({
    width,
    height,
    fromRight,
    sourceUrl,
    paperColor,
    mode = "curl",
    transparentUnderlay = false,
  }) {
    this.#cleanupOverlay();
    const host = this.#host;
    if (!host) throw new Error("no host");
    if (!sourceUrl) throw new Error("no snapshot");

    this.#visualMode = mode === "slide" ? "slide" : "curl";
    this.#mountedPaperColor = paperColor || "#f3eee4";
    const paperStops = computeThemePaperStops(this.#mountedPaperColor);

    const overlay = document.createElement("div");
    overlay.id = OVERLAY_ID;

    // On intra-section turns, keep the underlay transparent so the stationary
    // destination page in Foliate shows directly beneath the curling/sliding sheet.
    const underlay = document.createElement("div");
    underlay.className = "inkamp-curl-underlay";
    underlay.style.backgroundColor = transparentUnderlay
      ? "transparent"
      : this.#mountedPaperColor;

    // Flat current-page snapshot.
    const sheet = document.createElement("div");
    sheet.className = "inkamp-curl-sheet";
    sheet.style.width = `${width}px`;
    sheet.style.height = `${height}px`;
    sheet.style.backgroundColor = "transparent";
    sheet.style.backgroundImage = `url("${sourceUrl}")`;
    sheet.style.transform = "none";

    if (this.#visualMode === "slide") {
      const edgeSign = fromRight ? 1 : -1;
      sheet.style.boxShadow =
        `${edgeSign * 14}px 0 32px rgba(0, 0, 0, 0.22), `
        + `${edgeSign}px 0 0 rgba(0, 0, 0, 0.10)`;
      overlay.append(underlay, sheet);

      const hostStyle = globalThis.getComputedStyle?.(host);
      if (hostStyle && hostStyle.position === "static") {
        host.style.position = "relative";
      }
      host.appendChild(overlay);

      this.#overlay = overlay;
      this.#underlay = underlay;
      this.#sheet = sheet;
      return;
    }

    // Mirrored backside page bleed-through layer (clipped to the flap polygon).
    const bleedWrap = document.createElement("div");
    bleedWrap.className = "inkamp-curl-back-bleed";
    bleedWrap.style.width = `${width}px`;
    bleedWrap.style.height = `${height}px`;

    const bleedImg = document.createElement("div");
    bleedImg.className = "inkamp-curl-back-bleed-img";
    bleedImg.style.width = `${width}px`;
    bleedImg.style.height = `${height}px`;
    bleedImg.style.backgroundImage = `url("${sourceUrl}")`;
    bleedImg.style.opacity = String(paperStops.bleedOpacity);
    bleedWrap.appendChild(bleedImg);

    const svg = this.#svgEl("svg");
    svg.setAttribute("class", "inkamp-curl-shapes");
    svg.setAttribute("width", String(width));
    svg.setAttribute("height", String(height));
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    // Explicitly avoid the UA default black/canvas backdrop on some WebKits.
    svg.style.background = "transparent";
    svg.setAttribute("style", "background:transparent");

    const defs = this.#svgEl("defs");

    // Theme-adaptive cylindrical paper gradient across the backside flap.
    const grad = this.#svgEl("linearGradient");
    grad.setAttribute("id", "inkamp-curl-back-grad");
    grad.setAttribute("gradientUnits", "userSpaceOnUse");
    const stopA = this.#svgEl("stop");
    stopA.setAttribute("offset", "0%");
    stopA.setAttribute("stop-color", paperStops.stopA);
    const stopB = this.#svgEl("stop");
    stopB.setAttribute("offset", "55%");
    stopB.setAttribute("stop-color", paperStops.stopB);
    const stopC = this.#svgEl("stop");
    stopC.setAttribute("offset", "100%");
    stopC.setAttribute("stop-color", paperStops.stopC);
    grad.append(stopA, stopB, stopC);

    // Soft fold shadow via gradient (no feGaussianBlur).
    const shadowGrad = this.#svgEl("linearGradient");
    shadowGrad.setAttribute("id", "inkamp-curl-shadow-grad");
    shadowGrad.setAttribute("gradientUnits", "userSpaceOnUse");
    const s0 = this.#svgEl("stop");
    s0.setAttribute("offset", "0%");
    s0.setAttribute("stop-color", "rgb(35, 30, 24)");
    s0.setAttribute("stop-opacity", "0.28");
    const s1 = this.#svgEl("stop");
    s1.setAttribute("offset", "55%");
    s1.setAttribute("stop-color", "rgb(35, 30, 24)");
    s1.setAttribute("stop-opacity", "0.10");
    const s2 = this.#svgEl("stop");
    s2.setAttribute("offset", "100%");
    s2.setAttribute("stop-color", "rgb(35, 30, 24)");
    s2.setAttribute("stop-opacity", "0");
    shadowGrad.append(s0, s1, s2);

    // Cast shadow gradient falling from the curled flap onto the revealed next page.
    const castGrad = this.#svgEl("linearGradient");
    castGrad.setAttribute("id", "inkamp-curl-cast-grad");
    castGrad.setAttribute("gradientUnits", "userSpaceOnUse");
    const c0 = this.#svgEl("stop");
    c0.setAttribute("offset", "0%");
    c0.setAttribute("stop-color", "rgb(18, 15, 12)");
    c0.setAttribute("stop-opacity", "0.34");
    const c1 = this.#svgEl("stop");
    c1.setAttribute("offset", "52%");
    c1.setAttribute("stop-color", "rgb(18, 15, 12)");
    c1.setAttribute("stop-opacity", "0.14");
    const c2 = this.#svgEl("stop");
    c2.setAttribute("offset", "100%");
    c2.setAttribute("stop-color", "rgb(18, 15, 12)");
    c2.setAttribute("stop-opacity", "0");
    castGrad.append(c0, c1, c2);

    // Concave valley shadow gradient just inside the readable page crease.
    const creaseGrad = this.#svgEl("linearGradient");
    creaseGrad.setAttribute("id", "inkamp-curl-crease-grad");
    creaseGrad.setAttribute("gradientUnits", "userSpaceOnUse");
    const v0 = this.#svgEl("stop");
    v0.setAttribute("offset", "0%");
    v0.setAttribute("stop-color", "rgb(25, 20, 15)");
    v0.setAttribute("stop-opacity", "0");
    const v1 = this.#svgEl("stop");
    v1.setAttribute("offset", "100%");
    v1.setAttribute("stop-color", "rgb(25, 20, 15)");
    v1.setAttribute("stop-opacity", "0.22");
    creaseGrad.append(v0, v1);

    defs.append(grad, shadowGrad, castGrad, creaseGrad);

    const castShadowPath = this.#svgEl("path");
    castShadowPath.setAttribute("class", "inkamp-curl-cast-shadow");
    castShadowPath.setAttribute("fill", "url(#inkamp-curl-cast-grad)");

    const creaseShadowPath = this.#svgEl("path");
    creaseShadowPath.setAttribute("class", "inkamp-curl-crease-shadow");
    creaseShadowPath.setAttribute("fill", "url(#inkamp-curl-crease-grad)");

    const backPath = this.#svgEl("path");
    backPath.setAttribute("class", "inkamp-curl-back");
    backPath.setAttribute("fill", "url(#inkamp-curl-back-grad)");

    const shadowPath = this.#svgEl("path");
    shadowPath.setAttribute("class", "inkamp-curl-shadow");
    shadowPath.setAttribute("fill", "url(#inkamp-curl-shadow-grad)");

    const highlightPath = this.#svgEl("path");
    highlightPath.setAttribute("class", "inkamp-curl-highlight");
    highlightPath.setAttribute("fill", paperStops.highlightFill);

    svg.append(defs, castShadowPath, creaseShadowPath, backPath, shadowPath, highlightPath);
    overlay.append(underlay, sheet, bleedWrap, svg);

    const hostStyle = globalThis.getComputedStyle?.(host);
    if (hostStyle && hostStyle.position === "static") {
      host.style.position = "relative";
    }
    host.appendChild(overlay);

    this.#overlay = overlay;
    this.#underlay = underlay;
    this.#sheet = sheet;
    this.#bleedWrap = bleedWrap;
    this.#bleedImg = bleedImg;
    this.#shapesSvg = svg;
    this.#castShadowPath = castShadowPath;
    this.#creaseShadowPath = creaseShadowPath;
    this.#backPath = backPath;
    this.#shadowPath = shadowPath;
    this.#highlightPath = highlightPath;
    this.#backGrad = grad;
    this.#shadowGrad = shadowGrad;
    this.#castGrad = castGrad;
    this.#creaseGrad = creaseGrad;
  }

  #applyVisual(progress) {
    const sheet = this.#sheet;
    const gesture = this.#gesture;
    if (!sheet || !gesture) return;

    const width = gesture.width || sheet.clientWidth || 1;
    const height = gesture.height || sheet.clientHeight || width * 1.9;
    const fromRight = gesture.fromRight !== false;

    if (this.#visualMode === "slide") {
      const p = clamp01(progress);
      const dir = fromRight ? -1 : 1;
      const tx = px(dir * p * width);
      sheet.style.clipPath = "";
      sheet.style.transform = `translate3d(${tx}px, 0, 0)`;
      if (this.#renderer?.style) {
        const parallaxX = px(-dir * (1 - p) * width * 0.22);
        this.#renderer.style.transform =
          p > 0 && p < 1 ? `translate3d(${parallaxX}px, 0, 0)` : "";
      }
      return;
    }

    const bulgeY = gesture.bulgeY ?? 0.5;
    const state = peelVisualState(progress, width, height, fromRight, bulgeY);

    // Flat readable page — curved clip only.
    sheet.style.transform = "none";
    sheet.style.transformOrigin = "left top";
    sheet.style.clipPath = state.clipPath;
    if (sheet.style.webkitClipPath !== undefined) {
      sheet.style.webkitClipPath = state.clipPath;
    }

    // Mirrored backside page bleed-through clipped to the flap polygon.
    if (this.#bleedWrap && this.#bleedImg) {
      if (state.foldVisible && state.foldPath) {
        const foldClip = `path("${state.foldPath}")`;
        this.#bleedWrap.style.clipPath = foldClip;
        if (this.#bleedWrap.style.webkitClipPath !== undefined) {
          this.#bleedWrap.style.webkitClipPath = foldClip;
        }
        this.#bleedImg.style.transform = state.bleedTransform;
        this.#bleedWrap.style.opacity = "1";
      } else {
        this.#bleedWrap.style.opacity = "0";
      }
    }

    if (this.#shapesSvg) {
      this.#shapesSvg.setAttribute("width", String(width));
      this.#shapesSvg.setAttribute("height", String(height));
      this.#shapesSvg.setAttribute("viewBox", `0 0 ${width} ${height}`);
    }

    if (this.#backGrad) {
      // Gradient across the flap, following the diagonal crease → free tip.
      const x1 = state.edgeX;
      const y1 = state.midY ?? height * 0.5;
      const x2 = state.tipX ?? state.outerMid ?? (
        fromRight
          ? state.edgeX + state.foldWidth
          : state.edgeX - state.foldWidth
      );
      const y2 = state.tipY ?? height * 0.62;
      this.#backGrad.setAttribute("x1", String(px(x1)));
      this.#backGrad.setAttribute("y1", String(px(y1)));
      this.#backGrad.setAttribute("x2", String(px(x2)));
      this.#backGrad.setAttribute("y2", String(px(y2)));
    }
    if (this.#shadowGrad) {
      const x1 = state.edgeX;
      const y1 = state.midY ?? height * 0.5;
      const x2 = fromRight
        ? state.edgeX + state.foldWidth * 0.48
        : state.edgeX - state.foldWidth * 0.48;
      const y2 = state.tipY ?? height * 0.62;
      this.#shadowGrad.setAttribute("x1", String(px(x1)));
      this.#shadowGrad.setAttribute("y1", String(px(y1)));
      this.#shadowGrad.setAttribute("x2", String(px(x2)));
      this.#shadowGrad.setAttribute("y2", String(px(y2)));
    }
    if (this.#castGrad) {
      const x1 = state.edgeX;
      const y1 = state.midY ?? height * 0.5;
      const x2 = fromRight
        ? state.edgeX + state.foldWidth * 1.45
        : state.edgeX - state.foldWidth * 1.45;
      const y2 = state.tipY ?? height * 0.62;
      this.#castGrad.setAttribute("x1", String(px(x1)));
      this.#castGrad.setAttribute("y1", String(px(y1)));
      this.#castGrad.setAttribute("x2", String(px(x2)));
      this.#castGrad.setAttribute("y2", String(px(y2)));
    }
    if (this.#creaseGrad) {
      const valley = Math.min(state.curveAmp * 1.15, width * 0.045);
      const x1 = fromRight ? state.edgeX - valley : state.edgeX + valley;
      const x2 = state.edgeX;
      const yMid = state.midY ?? height * 0.5;
      this.#creaseGrad.setAttribute("x1", String(px(x1)));
      this.#creaseGrad.setAttribute("y1", String(px(yMid)));
      this.#creaseGrad.setAttribute("x2", String(px(x2)));
      this.#creaseGrad.setAttribute("y2", String(px(yMid)));
    }

    if (this.#castShadowPath) {
      this.#castShadowPath.setAttribute("d", state.castShadowPath || "M0 0");
      this.#castShadowPath.style.opacity = String(state.castShadowOpacity);
    }
    if (this.#creaseShadowPath) {
      this.#creaseShadowPath.setAttribute("d", state.creaseShadowPath || "M0 0");
      this.#creaseShadowPath.style.opacity = String(state.creaseShadowOpacity);
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
      const eased = easeAppleOut(t);
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
    if (this.#renderer?.style) {
      this.#renderer.style.transform = "";
    }
    const hadOverlay = !!this.#overlay;
    if (this.#sheet) {
      this.#sheet.style.willChange = "auto";
      // Release background image bitmap (native JPEG data-URL).
      this.#sheet.style.backgroundImage = "";
      this.#sheet.style.clipPath = "";
      this.#sheet.style.transform = "";
      if (this.#sheet.style.webkitClipPath !== undefined) {
        this.#sheet.style.webkitClipPath = "";
      }
    }
    if (this.#bleedImg) {
      this.#bleedImg.style.backgroundImage = "";
    }
    this.#overlay?.remove();
    this.#overlay = null;
    this.#underlay = null;
    this.#sheet = null;
    this.#bleedWrap = null;
    this.#bleedImg = null;
    this.#shapesSvg = null;
    this.#castShadowPath = null;
    this.#creaseShadowPath = null;
    this.#backPath = null;
    this.#shadowPath = null;
    this.#highlightPath = null;
    this.#backGrad = null;
    this.#shadowGrad = null;
    this.#castGrad = null;
    this.#creaseGrad = null;
    if (hadOverlay) debugLog("PageTurnAnimator", "visual-layer cleanup");
  }

  #resetGesture() {
    this.#clearSnapshotTimer();
    // Invalidate in-flight native replies tied to this gesture.
    this.#snapshotRequestId += 1;
    this.#pendingSnapshotRequestId = 0;
    this.#pendingSnapshotUrl = null;
    this.#snapshotFailed = false;
    this.#targetPageParked = false;
    this.#parkedDelta = 0;
    this.#phase = "idle";
    this.#gesture = null;
    this.#progress = 0;
    this.#pageFlipSeen = false;
    this.#awaitingSnap = false;
    this.#fallbackThisGesture = false;
    this.#setChromeSuppressed(false);
  }

  /**
   * Ask Swift to hide/restore floating reader chrome for the curl lifetime.
   * Does not permanently change overlay preferences — only gates visibility.
   */
  #setChromeSuppressed(active) {
    const next = !!active;
    if (next === this.#chromeSuppressed) return;
    this.#chromeSuppressed = next;
    try {
      globalThis.window?.webkit?.messageHandlers?.PageCurlChrome?.postMessage({
        active: next,
      });
    } catch {
      /* bridge optional in tests / non-iOS */
    }
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
