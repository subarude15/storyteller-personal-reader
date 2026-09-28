/**
 * Tiny assert-based check for PageTurnAnimator (no test framework).
 * Run: node scripts/page-turn-animator-selfcheck.mjs
 */
import PageTurnAnimator from "../SilveranKit/Sources/Kit/Resources/WebResources/PageTurnAnimator.js";

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

const animator = new PageTurnAnimator();
assert(animator.style === "slide", "default style slide");
assert(animator.effectiveStyle === "slide", "default effective slide");

animator.setStyle("curl");
assert(animator.style === "curl", "stores curl");
assert(animator.effectiveStyle === "slide", "curl falls back to slide");

animator.setStyle("instant");
assert(animator.effectiveStyle === "instant", "instant effective");

animator.setStyle("nope");
assert(animator.style === "slide", "invalid falls back to slide");

animator.setStyle("slide");
animator.setReduceMotion(true);
assert(animator.effectiveStyle === "instant", "reduceMotion forces instant");

const renderer = {
  attrs: new Set(["animated"]),
  removeAttribute(name) {
    this.attrs.delete(name);
  },
  hasAttribute(name) {
    return this.attrs.has(name);
  },
};

animator.setReduceMotion(false);
animator.setStyle("slide");
animator.applyToRenderer(renderer);
assert(renderer.hasAttribute("animated"), "slide leaves animated alone");

animator.setStyle("instant");
animator.applyToRenderer(renderer);
assert(!renderer.hasAttribute("animated"), "instant removes animated");

console.log("PageTurnAnimator.selfcheck: ok");
