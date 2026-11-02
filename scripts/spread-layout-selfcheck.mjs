/**
 * Assert-based check for the iPad spread layout + native curl handshake (no framework).
 * Run: node scripts/spread-layout-selfcheck.mjs
 */
import {
  COVER_RECTO_ATTRIBUTE,
  COVER_RECTO_CSS,
  NativeSpreadCurl,
  SPREAD_GUTTER,
  SPREAD_OUTER_MARGIN,
  reportedPages,
  spreadRendererAttributes,
} from "../SilveranKit/Sources/Kit/Resources/WebResources/SpreadLayout.js";
import PageTurnAnimator from "../SilveranKit/Sources/Kit/Resources/WebResources/PageTurnAnimator.js";

function assert(cond, msg) {
  if (!cond) throw new Error(msg);
}
const near = (a, b) => Math.abs(a - b) < 1e-6;

// Pinned foliate-js paginator.js #beforeRender + #top grid, horizontal paginated flow.
function paginatorLayout(w, attrs) {
  const g = parseFloat(attrs.gap) / 100;
  const maxInline = parseFloat(attrs["max-inline-size"]);
  const maxColumns = parseInt(attrs["max-column-count"], 10);
  const halfGap = (g * w) / 2;
  // grid: minmax(hg,1fr) hg minmax(0, 2*maxInline - g*w) hg minmax(hg,1fr)
  const middle = Math.max(0, Math.min(w - 4 * halfGap, 2 * maxInline - g * w));
  const container = middle + 2 * halfGap;
  const outerColumn = (w - container) / 2;
  const gap = (-g / (g - 1)) * container;
  const divisor = Math.min(maxColumns, Math.ceil(container / maxInline));
  const columnWidth = container / divisor - gap;
  return { outer: outerColumn + gap / 2, gutter: gap, columnWidth, divisor, container };
}

for (const w of [1000, 1024, 1180, 1366, 1376]) {
  const layout = paginatorLayout(w, spreadRendererAttributes(w));
  const page = (w - 2 * SPREAD_OUTER_MARGIN - SPREAD_GUTTER) / 2;
  assert(layout.divisor === 2, `two columns at ${w}`);
  assert(near(layout.outer, 48), `outer margin 48 at ${w}: ${layout.outer}`);
  assert(near(layout.gutter, 32), `gutter 32 at ${w}: ${layout.gutter}`);
  assert(near(layout.columnWidth, page), `page width at ${w}: ${layout.columnWidth} vs ${page}`);
  // A slide / turn scrolls one container: exactly one spread (two pages), never four.
  assert(near(layout.container, 2 * layout.columnWidth + 2 * layout.gutter), `one turn = one spread at ${w}`);
}

assert(COVER_RECTO_CSS.includes(`html[${COVER_RECTO_ATTRIBUTE}] body::before`), "cover recto CSS is attribute-gated");
assert(COVER_RECTO_CSS.includes("break-after: column"), "cover recto inserts a leading column");

// Reported pages: single-page keeps the viewport counter; a spread reports the left physical page.
const pages = (p, n, s) => JSON.stringify(reportedPages(p, n, s));
assert(pages(1, 7, false) === '{"pageIndex":1,"totalPages":5}', "single first page");
assert(pages(3, 7, false) === '{"pageIndex":3,"totalPages":5}', "single unchanged");
assert(pages(1, 7, true) === '{"pageIndex":1,"totalPages":10}', "spread first viewport = page 1");
assert(pages(2, 7, true) === '{"pageIndex":3,"totalPages":10}', "next spread = page 3, not 2");
assert(pages(3, 7, true) === '{"pageIndex":5,"totalPages":10}', "spreads advance by 2");
assert(pages(0, 7, true) === '{"pageIndex":1,"totalPages":10}', "leading padding clamps");
assert(pages(6, 7, true) === '{"pageIndex":9,"totalPages":10}', "trailing padding clamps to last spread");
assert(pages(null, 7, true) === '{"pageIndex":null,"totalPages":10}', "missing page");
assert(pages(1, null, true) === '{"pageIndex":null,"totalPages":null}', "scrolled / no pages");

// Native curl handshake.
const posts = [];
const curl = new NativeSpreadCurl((body) => posts.push(body));
assert(curl.available && !curl.open, "injected bridge is available");

// Swipe: capture before scroll, show on drag, commit after Foliate commits the turn.
curl.fillColor = "#f4ecd8";
const swipe = curl.capture();
curl.show(swipe, true);
curl.commit(swipe);
curl.commit(swipe);
curl.cancel(swipe);
assert(
  JSON.stringify(posts) === JSON.stringify([
    { phase: "capture", id: swipe, fillColor: "#f4ecd8" },
    { phase: "show", id: swipe, fromRight: true },
    { phase: "commit", id: swipe },
  ]),
  `swipe lifecycle posts once each: ${JSON.stringify(posts)}`,
);

// A newer capture supersedes; stale ids never post.
posts.length = 0;
const stale = curl.capture();
const fresh = curl.capture();
curl.show(stale, false);
curl.commit(stale);
curl.cancel(fresh);
curl.cancel();
assert(
  JSON.stringify(posts.map((p) => `${p.phase}:${p.id}`)) === JSON.stringify([`capture:${stale}`, `capture:${fresh}`, `cancel:${fresh}`]),
  `stale ids ignored: ${JSON.stringify(posts)}`,
);

async function checkTurns() {
  // Button turn: navigation runs only after the capture ack, exactly once, then commit.
  posts.length = 0;
  let position = 0;
  const order = [];
  const turned = curl.turn(true, async () => {
    order.push(`navigate after ${posts.map((p) => p.phase).join(",")}`);
    position += 1;
  }, () => position);
  assert(order.length === 0, "no navigation before the snapshot exists");
  curl.captured(posts[0].id, true);
  await turned;
  assert(position === 1, "navigated exactly once");
  assert(order[0] === "navigate after capture,show", `navigate after show: ${order[0]}`);
  assert(posts.at(-1).phase === "commit" && !curl.open, "committed after navigation");

  // End of book: no movement -> cancel, never animate a fake turn.
  posts.length = 0;
  const atEnd = curl.turn(true, async () => {}, () => position);
  curl.captured(posts[0].id, true);
  await atEnd;
  assert(posts.at(-1).phase === "cancel", "no-op turn cancels");

  // Snapshot failure: plain navigation still happens once; overlay never shown.
  posts.length = 0;
  let navigations = 0;
  const failed = curl.turn(false, async () => { navigations += 1; }, () => navigations);
  curl.captured(posts[0].id, false);
  await failed;
  assert(navigations === 1, "failure still turns the page once");
  assert(!posts.some((p) => p.phase === "show"), "failure never shows the overlay");
  assert(posts.at(-1).phase === "cancel", "failure cancels native state");

  // Capture timeout behaves like failure.
  posts.length = 0;
  navigations = 0;
  await curl.turn(true, async () => { navigations += 1; }, () => navigations);
  assert(navigations === 1 && posts.at(-1).phase === "cancel", "timeout falls back to one plain turn");

  // Resize / spread toggle cancels while the capture is pending: a late ok reply must not navigate.
  posts.length = 0;
  navigations = 0;
  const cancelled = curl.turn(true, async () => { navigations += 1; }, () => navigations);
  const cancelledId = posts[0].id;
  curl.cancel();
  curl.captured(cancelledId, true);
  await cancelled;
  assert(navigations === 0, "cancelled capture never navigates late");
  assert(!posts.some((p) => p.phase === "show"), "cancelled capture never shows");

  // Rapid opposite turns with out-of-order replies: only the newest intent navigates.
  posts.length = 0;
  let pos = 0;
  const forward = curl.turn(true, async () => { pos += 1; }, () => pos);
  const back = curl.turn(false, async () => { pos -= 1; }, () => pos);
  const [first, second] = posts.filter((p) => p.phase === "capture").map((p) => p.id);
  curl.captured(second, true);
  curl.captured(first, true);
  await Promise.all([forward, back]);
  assert(pos === -1, `only the newest turn navigates: ${pos}`);
  assert(!posts.some((p) => p.phase === "show" && p.id === first), "superseded turn never shows");

  // A swipe touchstart supersedes a pending button turn the same way.
  posts.length = 0;
  navigations = 0;
  const pending = curl.turn(true, async () => { navigations += 1; }, () => navigations);
  const pendingId = posts[0].id;
  const swipeId = curl.capture();
  curl.captured(pendingId, true);
  await pending;
  assert(navigations === 0, "superseded by swipe capture");
  curl.cancel(swipeId);
}

// The JS sheet curl stays off while the native spread curl owns turns, and returns after.
const animator = new PageTurnAnimator();
animator.setStyle("curl");
assert(animator.canCurl, "JS curl available outside spread");
animator.setNativeSpread(true);
assert(!animator.canCurl, "JS curl disabled in native spread");
animator.setNativeSpread(false);
assert(animator.canCurl, "JS curl restored after spread");
// Read-aloud keeps bypassing curl so narration page-follow is never blocked.
animator.setReadAloudActive(true);
assert(!animator.canCurl, "read-aloud bypasses curl");

await checkTurns();
console.log("spread-layout selfcheck ok");
