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
 */

const VALID_STYLES = new Set(["slide", "curl", "instant"]);

export default class PageTurnAnimator {
  #style = "slide";
  #reduceMotion = false;

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

  /**
   * Toggle Foliate paginator's built-in `animated` attribute.
   * Current app never sets `animated`; slide/curl preserve that. Instant
   * removes it so any future slide animation stays off for this mode.
   */
  applyToRenderer(renderer) {
    if (!renderer?.removeAttribute) return;
    if (this.effectiveStyle === "instant") {
      renderer.removeAttribute("animated");
    }
  }

  // Hooks for a future interactive curl implementation. No-ops in phase 1.
  begin(_detail) {}
  update(_detail) {}
  complete(_detail) {}
  cancel(_detail) {}
}
