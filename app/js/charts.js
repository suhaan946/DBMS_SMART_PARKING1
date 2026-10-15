/* ===========================================================================
   charts.js — inline SVG charts.

   Hand-drawn rather than a charting library: these three shapes are simple,
   an SVG built from tokens inherits the palette automatically, and there is no
   second styling system to reconcile.

   Every chart takes real query results and draws progressively — the line is
   plotted by stroke-dashoffset and the area wiped in beneath it, so a series
   appears to be measured rather than to pop into existence. Hovering reads
   out the value under the pointer.
   =========================================================================== */
import { esc } from './ui.js';
import { drawPath, wipeIn, growBars, prefersReducedMotion } from './motion.js';

/** Line chart with an area fill and a hover readout.
 *  points: [{label, value}]   onHover(point|null) */
export function lineChart(host, points, {
  height = 160, format = (v) => v, accessibleName = 'Trend',
  animate: doAnimate = true, onHover = null,
} = {}) {
  if (!host) return;
  if (!points || !points.length) {
    host.innerHTML = `<p style="color:var(--ink-2);font-size:var(--t-xs)">
      Nothing recorded in this period yet.</p>`;
    return;
  }

  const w = Math.max(220, host.clientWidth || 320), h = height;
  const padL = 44, padR = 10, padT = 10, padB = 22;
  const iw = Math.max(10, w - padL - padR), ih = h - padT - padB;
  const values = points.map((p) => Number(p.value) || 0);
  const max = Math.max(...values, 1);
  const step = points.length > 1 ? iw / (points.length - 1) : 0;
  const x = (i) => padL + i * step;
  const y = (v) => padT + ih - (v / max) * ih;

  const line = points.map((p, i) =>
    `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(values[i]).toFixed(1)}`).join(' ');
  const area = `${line} L${x(points.length - 1).toFixed(1)},${padT + ih} L${padL},${padT + ih} Z`;

  const ticks = 3;
  const grid = Array.from({ length: ticks + 1 }, (_, i) => {
    const v = (max / ticks) * i, gy = y(v);
    return `<line x1="${padL}" y1="${gy.toFixed(1)}" x2="${w - padR}" y2="${gy.toFixed(1)}"
              stroke="var(--rule-faint)" stroke-width="1"/>
            <text x="${padL - 7}" y="${(gy + 3.5).toFixed(1)}" text-anchor="end"
              font-size="9" fill="var(--ink-2)"
              font-family="var(--font-mono)">${esc(format(v))}</text>`;
  }).join('');

  const every = Math.max(1, Math.ceil(points.length / 4));
  const xLabels = points.map((p, i) => i % every === 0
    ? `<text x="${x(i).toFixed(1)}" y="${h - 6}" text-anchor="middle" font-size="9"
        fill="var(--ink-2)" font-family="var(--font-mono)">${esc(p.label)}</text>` : '').join('');

  host.innerHTML = `
    <svg class="chart" viewBox="0 0 ${w} ${h}" role="img"
         aria-label="${esc(accessibleName)}">
      ${grid}
      <g class="chart-area"><path d="${area}" fill="var(--accent-wash)"/></g>
      <path class="chart-line" d="${line}" fill="none" stroke="var(--accent)"
            stroke-width="1.75" stroke-linejoin="round" stroke-linecap="round"/>
      <line class="chart-hover-line" x1="0" y1="${padT}" x2="0" y2="${padT + ih}" opacity="0"/>
      <circle class="chart-dot" r="3.5" fill="var(--surface)" stroke="var(--accent)"
              stroke-width="2" opacity="0"/>
      ${xLabels}
      <rect class="chart-hit" x="${padL}" y="${padT}" width="${iw}" height="${ih}"
            fill="transparent" style="cursor:crosshair"/>
    </svg>`;

  const svg  = host.querySelector('svg');
  const dot  = host.querySelector('.chart-dot');
  const vline= host.querySelector('.chart-hover-line');
  const hit  = host.querySelector('.chart-hit');

  if (doAnimate) {
    drawPath(host.querySelector('.chart-line'), { duration: 0.8 });
    wipeIn(host.querySelector('.chart-area'), { duration: 0.85, delay: 0.05 });
  }

  // Hover readout. Pointer position is mapped through the SVG viewBox rather
  // than raw client pixels, so it stays correct at any container width.
  const toIndex = (evt) => {
    const r = svg.getBoundingClientRect();
    const sx = ((evt.clientX - r.left) / r.width) * w;
    return Math.max(0, Math.min(points.length - 1, Math.round((sx - padL) / (step || 1))));
  };
  const show = (i) => {
    const px = x(i), py = y(values[i]);
    dot.setAttribute('cx', px); dot.setAttribute('cy', py); dot.setAttribute('opacity', '1');
    vline.setAttribute('x1', px); vline.setAttribute('x2', px); vline.setAttribute('opacity', '1');
    onHover?.(points[i]);
  };
  const hide = () => {
    dot.setAttribute('opacity', '0'); vline.setAttribute('opacity', '0');
    onHover?.(null);
  };
  hit.addEventListener('pointermove', (e) => show(toIndex(e)));
  hit.addEventListener('pointerleave', hide);
  // Keyboard parity: the chart is reachable and steppable without a pointer.
  svg.setAttribute('tabindex', '0');
  let ki = -1;
  svg.addEventListener('keydown', (e) => {
    if (e.key === 'ArrowRight') { ki = Math.min(points.length - 1, ki + 1); show(ki); e.preventDefault(); }
    if (e.key === 'ArrowLeft')  { ki = Math.max(0, ki - 1); show(ki); e.preventDefault(); }
    if (e.key === 'Escape') { ki = -1; hide(); }
  });
  svg.addEventListener('blur', hide);
}

/** Vertical bars that grow from the baseline. bars: [{label, value, tone}] */
export function barChart(host, bars, {
  height = 200, format = (v) => v, accessibleName = 'Distribution',
  animate: doAnimate = true,
} = {}) {
  if (!host) return;
  if (!bars || !bars.length) {
    host.innerHTML = `<p style="color:var(--ink-2);font-size:var(--t-xs)">
      No data for this period.</p>`;
    return;
  }
  const w = Math.max(240, host.clientWidth || 620), h = height;
  const padL = 42, padR = 10, padT = 10, padB = 26;
  const iw = Math.max(10, w - padL - padR), ih = h - padT - padB;
  const max = Math.max(...bars.map((b) => Number(b.value) || 0), 1);
  const slot = iw / bars.length;
  const bw = Math.max(4, Math.min(34, slot * 0.62));

  const ticks = 3;
  const grid = Array.from({ length: ticks + 1 }, (_, i) => {
    const v = (max / ticks) * i, gy = padT + ih - (v / max) * ih;
    return `<line x1="${padL}" y1="${gy.toFixed(1)}" x2="${w - padR}" y2="${gy.toFixed(1)}"
              stroke="var(--rule-faint)"/>
            <text x="${padL - 7}" y="${(gy + 3.5).toFixed(1)}" text-anchor="end" font-size="9"
              fill="var(--ink-2)" font-family="var(--font-mono)">${esc(format(v))}</text>`;
  }).join('');

  const every = Math.max(1, Math.ceil(bars.length / 12));
  const rects = bars.map((b, i) => {
    const v = Number(b.value) || 0;
    const bh = (v / max) * ih;
    const bx = padL + i * slot + (slot - bw) / 2;
    const by = padT + ih - bh;
    const fill = b.tone ? `var(--state-${b.tone})` : 'var(--accent)';
    return `<rect class="chart-bar" x="${bx.toFixed(1)}" y="${by.toFixed(1)}"
              width="${bw.toFixed(1)}" height="${Math.max(0, bh).toFixed(1)}" rx="2" fill="${fill}"
              style="transform-origin:${(bx + bw / 2).toFixed(1)}px ${(padT + ih).toFixed(1)}px">
              <title>${esc(b.label)}: ${esc(format(v))}</title></rect>
            ${i % every === 0 ? `<text x="${(bx + bw / 2).toFixed(1)}" y="${h - 8}"
              text-anchor="middle" font-size="9" fill="var(--ink-2)"
              font-family="var(--font-mono)">${esc(b.label)}</text>` : ''}`;
  }).join('');

  host.innerHTML = `<svg class="chart" viewBox="0 0 ${w} ${h}" role="img"
      aria-label="${esc(accessibleName)}">${grid}${rects}</svg>`;
  if (doAnimate) growBars(host.querySelectorAll('.chart-bar'));
}

/** Horizontal proportion bar, e.g. occupancy by state. */
export function stackBar(host, segments, { accessibleName = 'Breakdown' } = {}) {
  if (!host) return;
  const total = segments.reduce((s, x) => s + (Number(x.value) || 0), 0);
  if (!total) { host.innerHTML = ''; return; }
  const parts = segments.filter((s) => s.value > 0).map((s) => {
    const pct = (s.value / total) * 100;
    return `<div style="width:${pct}%;background:${s.color || `var(--state-${s.tone})`};height:100%"
              title="${esc(s.label)}: ${s.value}"></div>`;
  }).join('');
  host.innerHTML = `<div role="img" aria-label="${esc(accessibleName)}"
       style="display:flex;height:8px;border-radius:2px;overflow:hidden;
              background:var(--plate-deep)">${parts}</div>`;
}
