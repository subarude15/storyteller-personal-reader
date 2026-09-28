/**
 * Tiny assert-based check for PageTurnAnimator (no test framework).
 * Run: node scripts/page-turn-animator-selfcheck.mjs
 */
import PageTurnAnimator from "../SilveranKit/Sources/Kit/Resources/WebResources/PageTurnAnimator.js";

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

function makeRenderer(animated) {
  const attrs = new Set(animated ? ["animated"] : []);
  return {
    removeAttribute(name) {
      attrs.delete(name);
    },
    setAttribute(name) {
      attrs.add(name);
    },
    hasAttribute(name) {
      return attrs.has(name);
    },
  };
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
animator.setReduceMotion(false);

const startedAnimated = makeRenderer(true);
animator.setStyle("slide");
animator.applyToRenderer(startedAnimated);
assert(startedAnimated.hasAttribute("animated"), "slide keeps original animated");
animator.setStyle("instant");
animator.applyToRenderer(startedAnimated);
assert(!startedAnimated.hasAttribute("animated"), "instant removes animated");
animator.setStyle("slide");
animator.applyToRenderer(startedAnimated);
assert(
  startedAnimated.hasAttribute("animated"),
  "slide restores original animated after instant",
);

const startedUnset = makeRenderer(false);
animator.setStyle("slide");
animator.applyToRenderer(startedUnset);
assert(!startedUnset.hasAttribute("animated"), "slide keeps original unset");
animator.setStyle("instant");
animator.applyToRenderer(startedUnset);
assert(!startedUnset.hasAttribute("animated"), "instant stays unset");
animator.setStyle("slide");
animator.applyToRenderer(startedUnset);
assert(
  !startedUnset.hasAttribute("animated"),
  "slide does not force animated after instant",
);

console.log("PageTurnAnimator.selfcheck: ok");
