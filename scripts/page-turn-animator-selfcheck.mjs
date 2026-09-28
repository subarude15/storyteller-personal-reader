/**
 * Tiny assert-based check for PageTurnAnimator (no test framework).
 * Run: node scripts/page-turn-animator-selfcheck.mjs
 */
import PageTurnAnimator from "../SilveranKit/Sources/Kit/Resources/WebResources/PageTurnAnimator.js";

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}

// Minimal DOM stubs so curl overlay mount/cleanup can run under Node.
function installDomStubs() {
  const elements = new Map();

  class FakeStyle {
    constructor() {
      this._map = new Map();
    }
    setProperty() {}
    get opacity() {
      return this._map.get("opacity");
    }
    set opacity(v) {
      this._map.set("opacity", v);
    }
    get transform() {
      return this._map.get("transform");
    }
    set transform(v) {
      this._map.set("transform", v);
    }
    get transformOrigin() {
      return this._map.get("transformOrigin");
    }
    set transformOrigin(v) {
      this._map.set("transformOrigin", v);
    }
    get willChange() {
      return this._map.get("willChange");
    }
    set willChange(v) {
      this._map.set("willChange", v);
    }
    get backgroundImage() {
      return this._map.get("backgroundImage");
    }
    set backgroundImage(v) {
      this._map.set("backgroundImage", v);
    }
    get backgroundColor() {
      return this._map.get("backgroundColor");
    }
    set backgroundColor(v) {
      this._map.set("backgroundColor", v);
    }
    get width() {
      return this._map.get("width");
    }
    set width(v) {
      this._map.set("width", v);
    }
    get height() {
      return this._map.get("height");
    }
    set height(v) {
      this._map.set("height", v);
    }
    get left() {
      return this._map.get("left");
    }
    set left(v) {
      this._map.set("left", v);
    }
    get right() {
      return this._map.get("right");
    }
    set right(v) {
      this._map.set("right", v);
    }
    get clipPath() {
      return this._map.get("clipPath");
    }
    set clipPath(v) {
      this._map.set("clipPath", v);
    }
    get position() {
      return this._map.get("position");
    }
    set position(v) {
      this._map.set("position", v);
    }
    get background() {
      return this._map.get("background");
    }
    set background(v) {
      this._map.set("background", v);
    }
  }

  class FakeEl {
    constructor(tag) {
      this.tagName = String(tag).toUpperCase();
      this.children = [];
      this.style = new FakeStyle();
      this.id = "";
      this.className = "";
      this.textContent = "";
      this.parent = null;
      this.clientHeight = 800;
      this.clientWidth = 400;
    }
    append(...nodes) {
      for (const n of nodes) {
        n.parent = this;
        this.children.push(n);
      }
    }
    appendChild(node) {
      this.append(node);
      return node;
    }
    remove() {
      if (!this.parent) return;
      this.parent.children = this.parent.children.filter((c) => c !== this);
      this.parent = null;
      if (this.id) elements.delete(this.id);
    }
    addEventListener() {}
    removeEventListener() {}
    setAttribute() {}
    getAttribute() {
      return null;
    }
    hasAttribute() {
      return false;
    }
    removeAttribute() {}
    getBoundingClientRect() {
      return { width: 400, height: 800, left: 0, top: 0, right: 400, bottom: 800 };
    }
  }

  const head = new FakeEl("head");
  const body = new FakeEl("body");
  const host = new FakeEl("div");
  host.id = "reader-container";
  elements.set(host.id, host);
  body.appendChild(host);

  globalThis.document = {
    head,
    body,
    documentElement: new FakeEl("html"),
    getElementById(id) {
      return elements.get(id) || null;
    },
    createElement(tag) {
      const el = new FakeEl(tag);
      return new Proxy(el, {
        set(target, prop, value) {
          target[prop] = value;
          if (prop === "id" && value) elements.set(value, target);
          return true;
        },
      });
    },
  };
  globalThis.requestAnimationFrame = (cb) => setTimeout(() => cb(performance.now()), 0);
  globalThis.cancelAnimationFrame = (id) => clearTimeout(id);
  globalThis.performance = { now: () => Date.now() };
  globalThis.matchMedia = () => ({
    matches: false,
    addEventListener() {},
    removeEventListener() {},
  });
  globalThis.getComputedStyle = () => ({ position: "relative", backgroundColor: "#fff" });
  globalThis.addEventListener = () => {};
  globalThis.removeEventListener = () => {};
  globalThis.window = globalThis;

  return { host };
}

function makeRenderer(animated) {
  const attrs = new Set(animated ? ["animated"] : []);
  return {
    scrolled: false,
    size: 400,
    start: 400,
    removeAttribute(name) {
      attrs.delete(name);
    },
    setAttribute(name) {
      attrs.add(name);
    },
    hasAttribute(name) {
      return attrs.has(name);
    },
    getAttribute(name) {
      if (name === "dir") return "ltr";
      return attrs.has(name) ? "" : null;
    },
    addEventListener() {},
    removeEventListener() {},
    getContents() {
      return [];
    },
    getBoundingClientRect() {
      return { width: 400, height: 800 };
    },
  };
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

const { host } = installDomStubs();
const animator = new PageTurnAnimator();

assert(animator.style === "slide", "default style slide");
assert(animator.effectiveStyle === "slide", "default effective slide");

animator.setStyle("curl");
assert(animator.style === "curl", "stores curl");
assert(animator.effectiveStyle === "curl", "curl is a real effective style");
assert(animator.canCurl === true, "can curl when style is curl");

animator.setStyle("instant");
assert(animator.effectiveStyle === "instant", "instant effective");

animator.setStyle("nope");
assert(animator.style === "slide", "invalid falls back to slide");

animator.setStyle("slide");
animator.setReduceMotion(true);
assert(animator.effectiveStyle === "instant", "reduceMotion forces instant");
assert(animator.canCurl === false, "reduceMotion blocks curl");
animator.setReduceMotion(false);

animator.setStyle("curl");
animator.setReadAloudActive(true);
assert(animator.canCurl === false, "read-aloud blocks curl");
assert(animator.readAloudActive === true, "read-aloud flag set");
animator.setReadAloudActive(false);
assert(animator.canCurl === true, "curl allowed after read-aloud clears");

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

animator.setStyle("curl");
animator.applyToRenderer(startedAnimated);
assert(!startedAnimated.hasAttribute("animated"), "curl strips animated for overlay snap");

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

// --- Curl lifecycle -------------------------------------------------------
const renderer = makeRenderer(false);
animator.setStyle("curl");
animator.setReduceMotion(false);
animator.setReadAloudActive(false);
animator.attach(renderer, host);

const began = animator.begin({
  width: 400,
  height: 800,
  fromRight: true,
  rtl: false,
  startOffset: 400,
  paperColor: "#faf6ee",
  allowPaperFallback: true,
  sourceUrl: null,
});
assert(began === true, "curl begin during normal ebook mode");
assert(animator.phase === "curling", "phase curling after begin");
assert(document.getElementById("inkamp-page-curl-overlay"), "overlay mounted");

animator.update({ progress: -1 });
assert(animator.progress === 0, "progress clamps low");
animator.update({ progress: 2 });
assert(animator.progress === 1, "progress clamps high");
animator.update({ progress: 0.4 });
assert(animator.progress === 0.4, "progress mid");

animator.cancel({ durationMs: 0 });
assert(animator.phase === "idle", "cancellation cleans up phase");
assert(!document.getElementById("inkamp-page-curl-overlay"), "cancellation removes overlay");

assert(
  animator.begin({
    width: 400,
    height: 800,
    fromRight: false,
    allowPaperFallback: true,
  }) === true,
  "begin again after cancel",
);
animator.update({ progress: 0.7 });
animator.complete({ durationMs: 0 });
assert(animator.phase === "idle", "completion cleans up phase");
assert(!document.getElementById("inkamp-page-curl-overlay"), "completion removes overlay");

// Read-aloud bypass
animator.setReadAloudActive(true);
assert(
  animator.begin({ width: 400, height: 800, allowPaperFallback: true }) === false,
  "curl bypass during read-aloud",
);
assert(animator.phase === "idle", "no phase change on read-aloud bypass");
animator.setReadAloudActive(false);

// Scrolling mode bypass
renderer.scrolled = true;
assert(
  animator.begin({ width: 400, height: 800, allowPaperFallback: true }) === false,
  "curl bypass in scrolling mode",
);
renderer.scrolled = false;

// Reduce Motion bypass
animator.setReduceMotion(true);
assert(
  animator.begin({ width: 400, height: 800, allowPaperFallback: true }) === false,
  "Reduce Motion bypasses curl",
);
animator.setReduceMotion(false);

// Failed visual creation (no host geometry / detached host)
animator.detach();
const orphan = new PageTurnAnimator();
orphan.setStyle("curl");
assert(
  orphan.begin({ width: 0, height: 0, allowPaperFallback: true }) === false,
  "failed visual creation falls back safely",
);

// Slide / instant unaffected
const slideAnimator = new PageTurnAnimator();
slideAnimator.setStyle("slide");
assert(slideAnimator.effectiveStyle === "slide", "slide remains unaffected");
slideAnimator.setStyle("instant");
assert(slideAnimator.effectiveStyle === "instant", "instant remains unaffected");

// Read-aloud mid-curl cancels
const live = new PageTurnAnimator();
live.setStyle("curl");
live.attach(makeRenderer(false), host);
assert(live.begin({ width: 400, height: 800, allowPaperFallback: true }) === true);
live.setReadAloudActive(true);
await sleep(30);
assert(live.phase === "idle" || live.phase === "cancelling", "read-aloud cancels active curl");
await sleep(50);
assert(!document.getElementById("inkamp-page-curl-overlay"), "read-aloud cancel cleans overlay");

console.log("PageTurnAnimator.selfcheck: ok");
