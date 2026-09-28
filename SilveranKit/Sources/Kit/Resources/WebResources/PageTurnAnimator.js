/**
 * Owns page-turn *appearance* only. Foliate's paginator still owns which page
 * is shown and fires PageFlipped / Relocated. Do not put navigation logic here.
 *
 * Phase 1:
 * - slide: current behavior (Foliate `animated` left unset)
 * - curl: same as slide (real curl plugs in later via begin/update/complete)
 * - instant: ensure no Foliate sliding transition (`animated` removed)
 *
 * reduceMotion: when true, effective style becomes instant (future Swift wiring).
 *
 * Instant may temporarily strip `animated`. Slide/curl restore whatever the
 * renderer had before this animator first managed it — they do not force it on.
 */

const VALID_STYLES = new Set(["slide", "curl", "instant"]);

export default class PageTurnAnimator {
  #style = "slide";
  #reduceMotion = false;
  #originalAnimated = new WeakMap();

  setStyle(style) {
    this.#style = VALID_STYLES.has(style) ? style : "slide";
  }

  setReduceMotion(enabled) {
    this.#reduceMotion = !!enabled;
  }

  get style() {
    return this.#style;
  }

  get reduceMotion() {
    return this.#reduceMotion;
  }

  /** Style used for appearance after curl→slide fallback and reduceMotion. */
  get effectiveStyle() {
    if (this.#reduceMotion) return "instant";
    if (this.#style === "curl") return "slide";
    return this.#style;
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
    if (this.effectiveStyle === "instant") {
      renderer.removeAttribute("animated");
      return;
    }
    if (this.#originalAnimated.get(renderer)) {
      renderer.setAttribute("animated", "");
    } else {
      renderer.removeAttribute("animated");
    }
  }

  // Hooks for a future interactive curl implementation. No-ops in phase 1.
  begin(_detail) {}
  update(_detail) {}
  complete(_detail) {}
  cancel(_detail) {}
}
