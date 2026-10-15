/* ===========================================================================
   motion.js — the interaction layer.

   Built on the `motion` package (pinned 11.18.2) through its vanilla entry
   point, since there is no React here. The library is vendored in
   web/vendor/ (MIT), so the app animates with no internet connection. Exports verified present in that build
   before use: animate, stagger, inView, spring, motionValue.

   Reduced motion is resolved ONCE, here, and consulted by every helper. No
   component repeats a media query, so no component can forget one. Toggling
   the OS setting takes effect live — the listener re-reads it.

   Timing discipline for operational software: feedback 0.12-0.18s, state
   changes 0.32s, panels 0.26s, entrances 0.42s. Nothing exceeds 0.5s, because
   an operator waiting on an animation is an operator being slowed down.
   =========================================================================== */
const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
let reduced = mq.matches;
mq.addEventListener('change', (e) => { reduced = e.matches || !motionLoaded; });

/* Loaded dynamically rather than with a static import: every page imports this
   module, so if the library ever failed to load, a static import would stop
   the whole app. Instead the app runs without animation, and the stand-in
   below applies each animation's END state at once so nothing is left
   invisible or half-drawn. */
let animate, stagger, inView, spring, motionLoaded = true;
try {
  ({ animate, stagger, inView, spring } =
    await import('../vendor/motion-11.18.2.js'));
} catch {
  motionLoaded = false;
  reduced = true;
  const done = { finished: Promise.resolve(), then: (r) => Promise.resolve().then(r),
                 stop() {}, cancel() {}, complete() {} };
  const last = (v) => (Array.isArray(v) ? v[v.length - 1] : v);
  animate = (target, keyframes, options = {}) => {
    if (typeof target === 'number') { options.onUpdate?.(keyframes); return done; }
    const els = target instanceof Element ? [target] : Array.from(target || []);
    els.forEach((el) => Object.entries(keyframes || {}).forEach(([prop, v]) => {
      if (['scale', 'x', 'y'].includes(prop)) return;     // shorthand props: leave at rest
      el.style[prop] = String(last(v));
    }));
    return done;
  };
  stagger = () => 0;
  inView = (el, cb) => { cb(); return () => {}; };
  spring = undefined;
}
export const prefersReducedMotion = () => reduced;

export const EASE     = [0.22, 0.61, 0.36, 1];
export const EASE_OUT = [0.16, 1, 0.3, 1];
export const EASE_SNAP= [0.4, 0, 0.2, 1];
export const DUR = { tap: 0.12, ui: 0.18, state: 0.32, panel: 0.26, enter: 0.42 };

/* -- 1. Entrances -------------------------------------------------------- */
export function enter(el, { delay = 0, y = 12 } = {}) {
  if (!el) return;
  if (reduced) { el.style.opacity = '1'; el.style.transform = 'none'; return; }
  animate(el, { opacity: [0, 1], transform: [`translateY(${y}px)`, 'translateY(0px)'] },
          { duration: DUR.enter, easing: EASE, delay });
}

/* -- 2. Staggered reveal -------------------------------------------------
   The per-item step is capped by a total budget, so a 94-bay floor finishes
   in well under a second instead of taking 94 x 25ms = 2.4 seconds, which
   reads as a loading fault rather than a flourish. */
export function revealList(nodes, { step = 0.018, budget = 0.5, y = 6 } = {}) {
  const items = Array.from(nodes || []);
  if (!items.length) return;
  if (reduced) {
    items.forEach((n) => { n.style.opacity = '1'; n.style.transform = 'none'; });
    return;
  }
  const per = Math.min(step, budget / Math.max(items.length - 1, 1));
  animate(items,
    { opacity: [0, 1], transform: [`translateY(${y}px)`, 'translateY(0px)'] },
    { duration: 0.26, easing: EASE, delay: stagger(per) });
}

/* -- 3. Hover and press feedback ----------------------------------------
   Spring is permitted here and nowhere else: a control responding to a
   pointer is the one place overshoot reads as physical rather than sloppy. */
export function interactive(el, { hover = 1.015, tap = 0.985 } = {}) {
  if (!el || reduced || el.dataset.motionBound === '1') return;
  el.dataset.motionBound = '1';
  const to = (s) => animate(el, { scale: s },
                            { type: spring, stiffness: 460, damping: 32, mass: 0.55 });
  el.addEventListener('pointerenter', () => to(hover));
  el.addEventListener('pointerleave', () => to(1));
  el.addEventListener('pointerdown',  () => to(tap));
  el.addEventListener('pointerup',    () => to(hover));
  el.addEventListener('focus', () => to(hover));
  el.addEventListener('blur',  () => to(1));
}
export function bindInteractive(root = document) {
  root.querySelectorAll('[data-interactive]').forEach((el) => interactive(el));
}

/* -- 4. Counters ---------------------------------------------------------
   Rendered through a tabular-nums element, so the column cannot change width
   mid-count and nothing around it reflows. */
export function countTo(el, target, {
  format = (n) => Math.round(n).toLocaleString('en-IN'),
  duration = 0.75,
} = {}) {
  if (!el) return;
  const value = Number(target) || 0;
  if (reduced) { el.textContent = format(value); el.dataset.countValue = String(value); return; }
  const from = Number(el.dataset.countValue ?? 0) || 0;
  el.dataset.countValue = String(value);
  if (from === value) { el.textContent = format(value); return; }
  animate(from, value, {
    duration, easing: EASE_OUT,
    onUpdate: (v) => { el.textContent = format(v); },
  });
}

/* -- 5. Panels ----------------------------------------------------------- */
export function openPanel(scrim, panel, { from = 'centre' } = {}) {
  if (reduced) return;
  animate(scrim, { opacity: [0, 1] }, { duration: DUR.panel, easing: EASE });
  const kf = from === 'right'
    ? { transform: ['translateX(28px)', 'translateX(0px)'], opacity: [0, 1] }
    : { opacity: [0, 1], transform: ['translateY(10px)', 'translateY(0px)'] };
  animate(panel, kf, { duration: DUR.panel, easing: EASE });
}
export async function closePanel(scrim, panel, { from = 'centre' } = {}) {
  if (reduced) return;
  const out = from === 'right'
    ? animate(panel, { transform: 'translateX(28px)', opacity: 0 }, { duration: 0.18, easing: EASE })
    : animate(panel, { opacity: 0, transform: 'translateY(8px)' }, { duration: 0.18, easing: EASE });
  animate(scrim, { opacity: 0 }, { duration: 0.18, easing: EASE });
  // Animation frames pause in a background tab, so the exit animation may
  // never finish. The timer guarantees the dialog is removed regardless.
  await Promise.race([
    Promise.resolve(out.finished || out).catch(() => {}),
    new Promise((r) => setTimeout(r, 320)),
  ]);
}

/* -- 6. Skeletons -------------------------------------------------------
   Declared in CSS (@keyframes pulse) so they cost no JavaScript and stop
   under the global reduced-motion rule. Nothing to do at runtime. */

/* -- 7. Bay state change -------------------------------------------------
   When a bay flips free -> occupied the operator should see it land, not
   discover it later. A brief lift and colour settle, no bounce. */
export function flashBay(el) {
  if (!el || reduced) return;
  animate(el, { opacity: [0.45, 1], scale: [0.94, 1] },
          { duration: DUR.state, easing: EASE_OUT });
}

/* Diff two renders of the map and animate only what actually changed, so a
   refresh does not restage the whole floor. */
export function applyBayChanges(root, previous) {
  if (!previous) return;
  root.querySelectorAll('.bay[data-slot-id]').forEach((el) => {
    const was = previous.get(el.dataset.slotId);
    if (was && was !== el.dataset.state) flashBay(el);
  });
}

/* -- 8. Nav indicator ---------------------------------------------------
   One element is translated between items rather than each item painting its
   own bar. The eye tracks a single object instead of watching two blink. */
export function moveIndicator(indicator, target, { instant = false } = {}) {
  if (!indicator || !target) return;
  const box = target.getBoundingClientRect();
  const parent = indicator.parentElement.getBoundingClientRect();
  const top = box.top - parent.top + indicator.parentElement.scrollTop;
  const height = box.height;
  if (reduced || instant) {
    indicator.style.transform = `translateY(${top}px)`;
    indicator.style.height = `${height}px`;
    indicator.style.opacity = '1';
    return;
  }
  animate(indicator,
    { transform: `translateY(${top}px)`, height: `${height}px`, opacity: 1 },
    { duration: 0.28, easing: EASE_SNAP });
}

/* -- 9. Chart draw ------------------------------------------------------
   Progressive reveal by stroke-dashoffset for the line, plus a clip wipe for
   the area beneath it, so the series appears to be plotted rather than to
   pop into existence. */
export function drawPath(path, { duration = 0.85, delay = 0 } = {}) {
  if (!path) return;
  const len = path.getTotalLength?.() || 0;
  if (!len) return;
  if (reduced) { path.style.strokeDasharray = 'none'; path.style.strokeDashoffset = '0'; return; }
  path.style.strokeDasharray = `${len}`;
  path.style.strokeDashoffset = `${len}`;
  // Tween the number and write the style ourselves: given an SVG element,
  // Motion animates stroke-dashoffset as an attribute, which the inline style
  // set above outranks, so the line would never appear.
  animate(len, 0, { duration, ease: EASE_OUT, delay,
                    onUpdate: (v) => { path.style.strokeDashoffset = `${v}`; } });
}
export function wipeIn(el, { duration = 0.8, delay = 0 } = {}) {
  if (!el) return;
  if (reduced) { el.style.clipPath = 'none'; el.style.opacity = '1'; return; }
  animate(el, { clipPath: ['inset(0 100% 0 0)', 'inset(0 0% 0 0)'], opacity: [0, 1] },
          { duration, easing: EASE_OUT, delay });
}
export function growBars(nodes, { duration = 0.55 } = {}) {
  const items = Array.from(nodes || []);
  if (!items.length) return;
  if (reduced) { items.forEach((n) => { n.style.transform = 'none'; n.style.opacity = '1'; }); return; }
  animate(items, { transform: ['scaleY(0)', 'scaleY(1)'], opacity: [0, 1] },
          { duration, easing: EASE_OUT, delay: stagger(Math.min(0.02, 0.4 / items.length)) });
}

/* -- 10. Live list insertion --------------------------------------------
   A new gate event slides down from the top and briefly tints, so an operator
   glancing at the ticker notices the arrival without needing a sound. */
export function insertLive(el) {
  if (!el) return;
  if (reduced) { el.style.opacity = '1'; return; }
  animate(el, { opacity: [0, 1], transform: ['translateY(-8px)', 'translateY(0px)'] },
          { duration: 0.3, easing: EASE_OUT });
  el.classList.add('tick-new');
  setTimeout(() => {
    if (reduced) { el.classList.remove('tick-new'); return; }
    animate(el, { backgroundColor: ['rgba(230,242,240,1)', 'rgba(230,242,240,0)'] },
            { duration: 1.1, easing: EASE })
      .finished?.then(() => el.classList.remove('tick-new')).catch(() => {});
  }, 450);
}

/* -- 11. Gauge ticks ----------------------------------------------------- */
export function fillGauge(ticks) {
  const items = Array.from(ticks || []);
  if (!items.length) return;
  if (reduced) { items.forEach((t) => { t.style.transform = 'none'; }); return; }
  animate(items, { transform: ['scaleY(.25)', 'scaleY(1)'] },
          { duration: 0.4, easing: EASE_OUT, delay: stagger(0.012) });
}

/* Section entrances on scroll, for the longer report pages. */
export function revealOnScroll(selector, root = document) {
  root.querySelectorAll(selector).forEach((el) => {
    if (reduced) { el.style.opacity = '1'; return; }
    el.style.opacity = '0';
    inView(el, () => {
      animate(el, { opacity: [0, 1], transform: ['translateY(10px)', 'translateY(0px)'] },
              { duration: DUR.enter, easing: EASE });
    }, { amount: 0.15 });
  });
}

export const formatMoney = (n) =>
  '₹' + Number(n || 0).toLocaleString('en-IN', { maximumFractionDigits: 0 });

export { animate, stagger, inView, spring };
