/**
 * iPad landscape two-page spread: Foliate paginator geometry and the native
 * UIPageViewController (.mid spine) curl handshake. Native decides when a spread
 * is shown (measured reader container, size class); this only lays it out.
 */

export const SPREAD_OUTER_MARGIN = 48;
export const SPREAD_GUTTER = 32;

/**
 * Paginator attributes giving 48px outer margins and a 32px gutter at width `w`.
 * Pinned foliate-js grid: #container = 2 * max-inline-size, the column gap is
 * g/(1-g) * container and each outer edge gets (w - container)/2 + gap/2.
 * Solving gap = 32, outer = 48 gives container = w - 64 and g = 32/(w - 32).
 */
export function spreadRendererAttributes(w) {
  const width = Math.max(w, 2 * SPREAD_OUTER_MARGIN + SPREAD_GUTTER + 2);
  return {
    "max-column-count": "2",
    gap: `${(SPREAD_GUTTER / (width - SPREAD_GUTTER)) * 100}%`,
    "max-inline-size": `${(width - 2 * SPREAD_OUTER_MARGIN + SPREAD_GUTTER) / 2}px`,
  };
}

/** Leading blank column in the first section so the cover lands on the recto. */
export const COVER_RECTO_ATTRIBUTE = "data-silveran-spread-recto";
export const COVER_RECTO_CSS = `
    html[${COVER_RECTO_ATTRIBUTE}] body::before {
        content: "";
        display: block;
        height: 0;
        -webkit-column-break-after: always;
        break-after: column;
    }`;

/**
 * Reported 1-based page / total from the paginator's raw viewport counters (which
 * include one padding viewport at each end). In a spread each viewport holds two
 * physical pages, so the page is the left page: viewport * 2 + 1.
 */
export function reportedPages(rawPage, rawPages, spread) {
  if (!(typeof rawPages === "number" && Number.isFinite(rawPages) && rawPages > 0)) {
    return { pageIndex: null, totalPages: null };
  }
  const perViewport = spread ? 2 : 1;
  const viewports = Math.max(1, Math.round(rawPages - 2));
  const pageIndex = typeof rawPage === "number" && Number.isFinite(rawPage)
    ? Math.max(0, Math.min(viewports - 1, Math.round(rawPage - 1))) * perViewport + 1
    : null;
  return { pageIndex, totalPages: viewports * perViewport };
}

const CAPTURE_TIMEOUT_MS = 400;

/**
 * Native curl lifecycle, keyed by a monotonic id so stale replies are ignored:
 *   capture -> native snapshots the current spread (before any navigation)
 *   show    -> native covers the web view with [left, right] halves
 *   commit  -> navigation has landed; native curls to the new spread, then lifts
 *   cancel  -> native lifts the overlay at once (no turn, resize, failure)
 * Foliate stays the only source of position: the turn is committed before the
 * animation, so cancel or resize never leaves a speculative location behind.
 */
export class NativeSpreadCurl {
  #post;
  #id = 0;
  #open = 0;
  #captured = new Map();
  /** Reader paper color; native paints it under transparent snapshot regions. */
  fillColor = null;

  constructor(post = defaultPost) {
    this.#post = post;
  }

  get available() {
    return this.#post !== defaultPost || !!globalThis.window?.webkit?.messageHandlers?.SpreadCurl;
  }

  /** True between capture and commit/cancel of the current turn. */
  get open() {
    return this.#open !== 0;
  }

  capture() {
    const id = ++this.#id;
    this.#settle(this.#open, "dropped");
    this.#open = id;
    this.#post({ phase: "capture", id, fillColor: this.fillColor });
    return id;
  }

  show(id, fromRight) {
    if (id === this.#open) this.#post({ phase: "show", id, fromRight: !!fromRight });
  }

  commit(id) {
    this.#close(id, "commit");
  }

  cancel(id = this.#open) {
    this.#close(id, "cancel");
  }

  #close(id, phase) {
    if (!id || id !== this.#open) return;
    this.#open = 0;
    this.#settle(id, "dropped");
    this.#post({ phase, id });
  }

  #settle(id, result) {
    const resolve = this.#captured.get(id);
    if (!resolve) return;
    this.#captured.delete(id);
    resolve(result);
  }

  /** Native reply once the pre-turn snapshot exists (ok=false on failure). */
  captured(id, ok) {
    this.#settle(id, ok ? "ok" : "failed");
  }

  /**
   * "ok" | "failed" (no snapshot / timeout: turn without curl) | "dropped"
   * (a newer turn, cancel or resize superseded this one: do not navigate).
   */
  waitForCapture(id, timeoutMs = CAPTURE_TIMEOUT_MS) {
    if (id !== this.#open) return Promise.resolve("dropped");
    return new Promise((resolve) => {
      const timer = setTimeout(() => this.#settle(id, "failed"), timeoutMs);
      this.#captured.set(id, (result) => {
        clearTimeout(timer);
        resolve(result);
      });
    });
  }

  /**
   * Button / margin-tap / keyboard turn. `navigate` performs the real Foliate
   * turn at most once: skipped when superseded, uncurled when the snapshot
   * fails. `position` tells whether it actually moved (start/end of book) so a
   * no-op never animates.
   */
  async turn(fromRight, navigate, position = () => null) {
    const id = this.capture();
    const result = await this.waitForCapture(id);
    if (result === "dropped") return;
    if (result === "failed") {
      this.cancel(id);
      return navigate();
    }
    this.show(id, fromRight);
    const before = position();
    try {
      return await navigate();
    } finally {
      if (before !== null && position() === before) this.cancel(id);
      else this.commit(id);
    }
  }
}

function defaultPost(body) {
  globalThis.window?.webkit?.messageHandlers?.SpreadCurl?.postMessage(body);
}
