/* ===========================================================================
   dashboard.js — the live operations view.

   Composition, deliberately not five equal cards plus three equal panels:
     - a COMMAND STRIP across the top: one instrument bar, hairline-segmented,
       reading left to right as a sentence about the building
     - the FLOOR PLATE as the dominant workspace, recessed into the page
     - a narrow right rail carrying revenue and the live gate ticker

   Every figure is a query result. There is no constant, estimate or
   placeholder anywhere in this file.
   =========================================================================== */
import { api, ApiError } from './api.js';
import {
  mountShell, icon, esc, money, moneyShort, duration, dateTime, timeOnly, titleCase,
  skeleton, errorState, empty, facility, toast, bayHTML, zoneHTML, groupByZone, methodLabel,
} from './ui.js';
import {
  enter, revealList, countTo, bindInteractive, fillGauge, insertLive,
  applyBayChanges, flashBay, prefersReducedMotion,
} from './motion.js';
import { lineChart } from './charts.js';
import { openBaySheet } from './bay-sheet.js';

const REFRESH_MS = 30000;

const ctx = mountShell('dashboard.html', {
  title: 'Operations',
  subtitle: 'Live floor state and today’s takings',
  metrics: true,
  actions: `
    <span class="live" id="live" title="Last updated">
      <span class="live-dot" aria-hidden="true"></span>
      <span class="live-label">System online</span>
      <span class="live-sep" aria-hidden="true">·</span>
      <span id="live-text">Live</span>
    </span>
    <button class="btn btn-icon" id="refresh" data-interactive
            aria-label="Refresh now">${icon('refresh')}</button>`,
});
if (ctx) init(ctx);

async function init({ content, metrics, user }) {
  content.innerHTML = `
    <div class="ops">
      <section class="plate" id="plate" aria-label="Live floor map">
        <div class="plate-head">
          <label class="sr-only" for="facility">Facility</label>
          <select class="select" id="facility" style="max-width:200px;min-height:32px"></select>
          <div class="levels" id="levels" role="group" aria-label="Floor"></div>
          <div class="search" style="min-width:150px">
            ${icon('search')}
            <label class="sr-only" for="bay-search">Find a bay or registration</label>
            <input class="input code" id="bay-search" placeholder="Find bay / plate"
                   autocomplete="off" style="min-height:32px">
          </div>
          <div class="seg" id="state-filter" role="group" aria-label="Filter by state">
            <button type="button" data-state="all" aria-pressed="true">All</button>
            <button type="button" data-state="free" aria-pressed="false">Free</button>
            <button type="button" data-state="reserved" aria-pressed="false">Held</button>
            <button type="button" data-state="occupied" aria-pressed="false">In use</button>
          </div>
          <div class="spacer" style="flex:1"></div>
          <a class="btn btn-sm" href="slots.html" data-interactive>
            Open full map ${icon('arrow-right')}</a>
        </div>
        <div class="plate-body">
          <div class="legend" style="margin-bottom:var(--s5)" id="legend">
            <span class="legend-item"><span class="sw sw-free"></span>Free</span>
            <span class="legend-item"><span class="sw sw-held"></span>Reserved</span>
            <span class="legend-item"><span class="sw sw-full"></span>Occupied</span>
            <span class="legend-item"><span class="sw sw-off"></span>Out of service</span>
            <span class="legend-item" style="margin-left:auto">
              <span style="color:var(--ink-2)">An occupied bay is filled solid,
              as a car would be on a plan.</span></span>
          </div>
          <div id="map"></div>
        </div>
      </section>

      <div class="ops-rail">
        <section class="panel" aria-label="Revenue">
          <div class="panel-head">
            <h2>Revenue</h2>
            <span class="hint">14 days</span>
            <div class="spacer"></div>
          </div>
          <div class="panel-body">
            <div class="chart-readout" id="rev-readout"></div>
            <div id="rev-chart" style="margin-top:var(--s2)"></div>
          </div>
        </section>

        <section class="panel" aria-label="Live activity">
          <div class="panel-head">
            <h2>Live activity</h2>
            <div class="spacer"></div>
            <span class="label" id="tick-count"></span>
          </div>
          <div class="panel-body flush">
            <div class="ticker" id="ticker" role="log" aria-live="polite"
                 aria-label="Entries, exits, payments, bookings and violations"></div>
          </div>
        </section>
      </div>
    </div>
    <div class="stat-row ops-summary" id="summary" aria-label="Operational summary"></div>`;

  const selF   = content.querySelector('#facility');
  const levels = content.querySelector('#levels');
  const search = content.querySelector('#bay-search');
  const segs   = content.querySelector('#state-filter');

  let facilities = [];
  try { facilities = await api.facilities(); }
  catch (err) { errorState(content, err, () => location.reload()); return; }
  if (!facilities.length) {
    empty(content, { title: 'No facility configured',
                     body: 'Add a facility in Settings before the map can show anything.',
                     iconName: 'grid' });
    return;
  }

  // An operator is posted to one site and should not be choosing between them.
  const scoped = user.facility_id
    ? facilities.filter((f) => f.facility_id === user.facility_id) : facilities;
  selF.innerHTML = scoped.map((f) =>
    `<option value="${f.facility_id}">${esc(f.name)}</option>`).join('');
  if (scoped.length === 1) selF.disabled = true;
  const remembered = facility.get();
  if (remembered && scoped.some((f) => f.facility_id === remembered)) selF.value = String(remembered);
  else facility.set(Number(selF.value));

  let floorFilter = 'all', stateFilter = 'all', term = '';
  let allSlots = [], prevStates = null, lastTickIds = new Set(), timer = null;
  let customerCount = null;
  const isStaff = user.role === 'admin' || user.role === 'operator';

  selF.addEventListener('change', () => {
    facility.set(Number(selF.value)); floorFilter = 'all'; load({ full: true });
  });
  segs.addEventListener('click', (e) => {
    const b = e.target.closest('button[data-state]'); if (!b) return;
    stateFilter = b.dataset.state;
    segs.querySelectorAll('button').forEach((x) =>
      x.setAttribute('aria-pressed', String(x === b)));
    renderMap();
  });
  let st; search.addEventListener('input', () => {
    clearTimeout(st);
    st = setTimeout(() => { term = search.value.trim().toUpperCase(); renderMap(); }, 160);
  });
  content.querySelector('#refresh')?.addEventListener('click', () => load({ announce: true }));
  document.getElementById('refresh')?.addEventListener('click', () => load({ announce: true }));

  enter(content.querySelector('#plate'));
  enter(content.querySelector('.ops-rail'), { delay: 0.07 });
  load({ full: true });

  // Poll, so the floor stays live without the operator pressing anything.
  // Paused while the tab is hidden — nobody is watching, and a background tab
  // hammering the database is just noise.
  const startTimer = () => { clearInterval(timer); timer = setInterval(() => load(), REFRESH_MS); };
  startTimer();
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) clearInterval(timer);
    else { load(); startTimer(); }
  });

  async function load({ full = false, announce = false } = {}) {
    if (full) {
      metrics.innerHTML = Array.from({ length: 5 }, () =>
        `<div class="metric"><div class="skeleton skeleton-metric"></div></div>`).join('');
      skeleton(content.querySelector('#map'), { rows: 8, kind: 'bay' });
    }
    const fid = Number(selF.value);
    let d, slotData;
    let feed = null;
    try {
      // The feed is a nice-to-have: if it fails, the map and figures still load.
      [d, slotData, feed] = await Promise.all([api.dashboard(fid), api.slots(fid),
        api.activity(fid, 10).catch(() => null)]);
    }
    catch (err) {
      setLive(false, err.message);
      if (full) { metrics.innerHTML = ''; errorState(content.querySelector('#map'), err, () => load({ full: true })); }
      else toast('Could not refresh', err.message, 'error');
      return;
    }

    setLive(true);
    renderMetrics(d, full);
    allSlots = slotData.slots || [];
    renderLevels();
    renderMap({ animateChanges: !full });
    renderRevenue(d.trend, full);
    renderTicker(feed, full);

    // The active-customer count is fetched only on a full load (it changes
    // rarely) and only for staff — a customer sees only their own row under
    // RLS, so the figure would be meaningless for them. Kept from the last
    // load on polls, so the summary never blanks out mid-session.
    if (full && isStaff) {
      try { customerCount = (await api.customers()).length; } catch { /* keep last */ }
    }
    renderSummary(d, full);
    if (announce) toast('Refreshed', 'Floor state and takings are current.', 'success');
  }

  /* --- operational summary: real figures the five headline KPIs don't carry */
  function renderSummary(d, full) {
    const host = content.querySelector('#summary');
    if (!host) return;
    const s = d.slots;
    const stay = d.stays_7d || {};
    const cards = [
      ['clock', 'Average stay', stay.avg_stay_minutes == null ? null : duration(stay.avg_stay_minutes),
        `${Number(stay.completed_stays || 0).toLocaleString('en-IN')} exits in the last 7 days`],
      ['calendar', 'Held bays', s.reserved, 'reserved, awaiting arrival'],
      ['ban', 'Out of service', s.out_of_service, 'not available to allocate'],
      ['alert', 'Open violations', d.violations.open_violations, 'awaiting resolution'],
      isStaff
        ? ['users', 'Active customers', customerCount, 'on record']
        : ['car', 'In use now', s.occupied, 'vehicles parked'],
    ];
    host.innerHTML = cards.map(([ic, label, val, foot]) => `
      <div class="stat">
        <div class="stat-label">${icon(ic)} ${esc(label)}</div>
        <div class="stat-value">${val == null ? '—' : typeof val === 'string' ? esc(val)
          : Number(val).toLocaleString('en-IN')}</div>
        <div class="stat-foot">${esc(foot)}</div>
      </div>`).join('');
    if (full) revealList(host.querySelectorAll('.stat'), { step: 0.04 });
  }

  function setLive(ok, why = '') {
    const el = document.getElementById('live');
    const txt = document.getElementById('live-text');
    const lbl = el?.querySelector('.live-label');
    if (!el) return;
    el.dataset.stale = String(!ok);
    if (lbl) lbl.textContent = ok ? 'System online' : 'Connection lost';
    txt.textContent = ok
      ? new Date().toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', hour12: false })
      : 'Stale';
    el.title = ok ? `Updated ${new Date().toLocaleTimeString()}` : why;
  }

  /* --- the command strip ------------------------------------------------ */
  function renderMetrics(d, full) {
    const s = d.slots;
    const pct = s.total_slots ? Math.round((s.occupied / s.total_slots) * 100) : 0;
    const TICKS = 20;
    const on = Math.round((pct / 100) * TICKS);
    const gauge = Array.from({ length: TICKS }, (_, i) => {
      const lit = i < on;
      const level = pct >= 90 ? 'full' : pct >= 70 ? 'warn' : 'on';
      return `<span class="gauge-tick" ${lit ? `data-${level}="true"` : ''}></span>`;
    }).join('');

    metrics.innerHTML = `
      <div class="metric metric-lead" data-accent="occupancy">
        <div class="metric-top">
          <span class="metric-chip">${icon('car')}</span>
          <span class="metric-label">Occupancy</span>
        </div>
        <div class="metric-value"><span data-count="${pct}" data-suffix="%">0%</span></div>
        <div class="metric-foot">${s.occupied} of ${s.total_slots} bays in use</div>
        <div class="gauge" id="gauge" role="img"
             aria-label="Occupancy ${pct} percent">${gauge}</div>
      </div>
      <div class="metric" data-accent="free">
        <div class="metric-top">
          <span class="metric-chip">${icon('check')}</span>
          <span class="metric-label">Free now</span>
        </div>
        <div class="metric-value"><span data-count="${s.free}">0</span></div>
        <div class="metric-foot">${s.reserved} held · ${s.out_of_service} offline</div>
      </div>
      <div class="metric" data-accent="entries">
        <div class="metric-top">
          <span class="metric-chip">${icon('gate')}</span>
          <span class="metric-label">Entries today</span>
        </div>
        <div class="metric-value"><span data-count="${d.entries.entries_today}">0</span></div>
        <div class="metric-foot">${d.money.bills_today} bills raised</div>
      </div>
      <div class="metric" data-accent="collected" data-priority="low">
        <div class="metric-top">
          <span class="metric-chip">${icon('receipt')}</span>
          <span class="metric-label">Collected</span>
        </div>
        <div class="metric-value"><span data-count="${d.money.collected_today}" data-money="1">₹0</span></div>
        <div class="metric-foot">${moneyShort(d.money.billed_today)} billed today</div>
      </div>
      <div class="metric ${Number(d.outstanding.outstanding) > 0 ? 'metric-alert' : ''}" data-accent="outstanding">
        <div class="metric-top">
          <span class="metric-chip">${icon('alert')}</span>
          <span class="metric-label">Outstanding</span>
        </div>
        <div class="metric-value"><span data-count="${d.outstanding.outstanding}" data-money="1">₹0</span></div>
        <div class="metric-foot">${d.violations.open_violations} open violations</div>
      </div>`;

    metrics.querySelectorAll('[data-count]').forEach((el) => {
      const suffix = el.dataset.suffix || '';
      countTo(el, Number(el.dataset.count) || 0, {
        format: el.dataset.money ? moneyShort
          : (v) => Math.round(v).toLocaleString('en-IN') + suffix,
      });
    });
    // On a full load the cards stagger in and then the numbers count up; on a
    // poll they stay put and only the figures animate, so a refresh is calm.
    if (full) {
      revealList(metrics.querySelectorAll('.metric'), { step: 0.05, budget: 0.4, y: 10 });
      fillGauge(metrics.querySelectorAll('.gauge-tick'));
    }
  }

  /* --- floor selector, drawn as level markers --------------------------- */
  function renderLevels() {
    const floors = [...new Map(allSlots.map((s) => [s.level_number, s.floor_name])).entries()]
      .sort((a, b) => a[0] - b[0]);
    levels.innerHTML =
      `<button type="button" class="level" data-level="all"
         aria-pressed="${floorFilter === 'all'}"><span class="n">All</span></button>` +
      floors.map(([lvl, name]) => {
        const bays = allSlots.filter((s) => s.level_number === lvl);
        const free = bays.filter((s) => s.slot_state === 'free').length;
        return `<button type="button" class="level" data-level="${lvl}"
                  aria-pressed="${String(floorFilter) === String(lvl)}"
                  title="${esc(name)} — ${free} of ${bays.length} free">
                  <span class="n">${esc(shortFloor(name, lvl))}</span></button>`;
      }).join('');
    levels.querySelectorAll('.level').forEach((b) => b.addEventListener('click', () => {
      floorFilter = b.dataset.level;
      levels.querySelectorAll('.level').forEach((x) =>
        x.setAttribute('aria-pressed', String(x === b)));
      renderMap();
    }));
  }

  const shortFloor = (name, lvl) =>
    lvl < 0 ? `B${Math.abs(lvl)}` : lvl === 0 ? 'G' : `L${lvl}`;

  /* --- the floor plate --------------------------------------------------- */
  function renderMap({ animateChanges = false } = {}) {
    const host = content.querySelector('#map');
    let shown = allSlots;
    if (floorFilter !== 'all') shown = shown.filter((s) => String(s.level_number) === String(floorFilter));
    if (stateFilter !== 'all') shown = shown.filter((s) => s.slot_state === stateFilter);
    if (term) shown = shown.filter((s) =>
      (s.slot_code || '').toUpperCase().includes(term) ||
      (s.plate_number || '').toUpperCase().includes(term));

    if (!shown.length) {
      empty(host, {
        title: term ? `Nothing matches “${term}”`
             : stateFilter !== 'all' ? `No ${stateFilter.replace('_', ' ')} bays here`
             : 'No bays on this floor',
        body: term ? 'Check the bay code or registration, or clear the search.'
            : stateFilter !== 'all' ? 'Switch the filter to All to see the rest of the floor.'
            : 'Add zones and slots for this floor in Settings.',
        iconName: 'grid',
      });
      return;
    }

    const before = prevStates;
    host.innerHTML = groupByZone(shown).map((z) => zoneHTML(z)).join('');
    prevStates = new Map(shown.map((s) => [String(s.slot_id), s.slot_state]));

    if (animateChanges && before) applyBayChanges(host, before);
    else revealList(host.querySelectorAll('.bay'));
    bindInteractive(host);
    wireBays(host, shown);
  }

  /* --- hover reveals detail, click opens the side panel ----------------- */
  function wireBays(host, shown) {
    const byId = new Map(shown.map((s) => [String(s.slot_id), s]));
    let pop = null;

    const hide = () => { pop?.remove(); pop = null; };

    host.querySelectorAll('.bay').forEach((el) => {
      const s = byId.get(el.dataset.slotId);
      if (!s) return;

      el.addEventListener('pointerenter', () => {
        if (window.matchMedia('(hover: none)').matches) return;
        hide();
        pop = document.createElement('div');
        pop.className = 'bay-pop';
        pop.setAttribute('role', 'tooltip');
        pop.innerHTML = popHTML(s);
        document.body.appendChild(pop);
        place(pop, el);
        if (!prefersReducedMotion()) {
          pop.animate([{ opacity: 0, transform: 'translateY(4px)' },
                       { opacity: 1, transform: 'translateY(0)' }],
                      { duration: 140, easing: 'cubic-bezier(.16,1,.3,1)', fill: 'forwards' });
        } else { pop.style.opacity = '1'; }
      });
      el.addEventListener('pointerleave', hide);
      el.addEventListener('click', () => { hide(); openBaySheet(s, () => load()); });
    });
    window.addEventListener('scroll', hide, { passive: true, once: true });
  }

  function popHTML(s) {
    const rows = [];
    rows.push(['Fits', s.vehicle_type_name]);
    if (s.slot_state === 'occupied') {
      rows.push(['Vehicle', s.plate_number], ['Customer', s.customer_name],
                ['Since', timeOnly(s.entry_time)],
                ['Charge', money(s.running_charge)]);
    } else if (s.slot_state === 'reserved') {
      rows.push(['Status', 'Held for an arrival']);
    } else if (s.slot_state === 'out_of_service') {
      rows.push(['Status', 'Not in service']);
    } else {
      rows.push(['Status', 'Available now']);
    }
    return `<div class="pop-title"><span>${esc(s.slot_code)}</span>
              <span style="font-size:var(--t-2xs);opacity:.75">${esc(s.floor_name)}</span></div>
            <dl>${rows.filter(([, v]) => v != null && v !== '')
              .map(([k, v]) => `<dt>${esc(k)}</dt><dd>${esc(v)}</dd>`).join('')}</dl>`;
  }

  /* Keep the hover card on screen at the edges of the viewport. */
  function place(pop, el) {
    const b = el.getBoundingClientRect();
    const p = pop.getBoundingClientRect();
    let left = b.left + b.width / 2 - p.width / 2;
    let top = b.top - p.height - 8;
    if (top < 8) top = b.bottom + 8;
    left = Math.max(8, Math.min(left, window.innerWidth - p.width - 8));
    pop.style.left = `${left}px`;
    pop.style.top = `${top}px`;
  }

  /* --- revenue ----------------------------------------------------------- */
  function renderRevenue(trend, full) {
    const pts = (trend || []).map((r) => ({
      label: new Date(r.d).toLocaleDateString('en-IN', { day: '2-digit', month: 'short' }),
      value: Number(r.revenue) || 0,
    }));
    const readout = content.querySelector('#rev-readout');
    const total = pts.reduce((a, p) => a + p.value, 0);
    const base = () => { readout.innerHTML =
      `<b>${moneyShort(total)}</b><span>billed over ${pts.length} days</span>`; };
    base();
    lineChart(content.querySelector('#rev-chart'), pts, {
      height: 132, animate: full,
      format: (v) => '₹' + Math.round(v).toLocaleString('en-IN'),
      accessibleName: 'Revenue billed per day over the last 14 days',
      onHover: (p) => {
        readout.innerHTML = p
          ? `<b>${moneyShort(p.value)}</b><span>on ${esc(p.label)}</span>`
          : null;
        if (!p) base();
      },
    });
  }

  /* --- activity feed: v_recent_activity (UNION ALL of five event sources) */
  function renderTicker(rows, full) {
    const host = content.querySelector('#ticker');
    const count = content.querySelector('#tick-count');
    if (rows === null) {
      host.innerHTML = '<p class="muted small" style="padding:var(--s4)">Activity is unavailable right now.</p>';
      count.textContent = '';
      return;
    }
    if (!rows.length) {
      host.innerHTML = '';
      empty(host, { title: 'Nothing has happened yet',
                    body: 'Arrivals, departures, payments and bookings appear here as they happen.',
                    iconName: 'gate' });
      count.textContent = '';
      return;
    }
    count.textContent = `latest ${rows.length}`;
    const KIND = {
      entry:       { cls: 'tick-in',   ic: 'arrow-down', word: 'In' },
      exit:        { cls: 'tick-out',  ic: 'arrow-up',   word: 'Out' },
      payment:     { cls: 'tick-pay',  ic: 'receipt',    word: 'Paid' },
      reservation: { cls: 'tick-res',  ic: 'calendar',   word: 'Booked' },
      violation:   { cls: 'tick-viol', ic: 'alert',      word: 'Violation' },
    };
    const detail = (r) => r.kind === 'payment' ? `${moneyShort(r.amount)} · ${methodLabel(r.detail)}`
      : r.kind === 'violation' ? titleCase(r.detail) : r.slot_code || '';
    const ids = new Set(rows.map((r) => `${r.kind}-${r.ref_id}`));
    host.innerHTML = rows.map((r) => {
      const k = KIND[r.kind] || KIND.entry;
      return `<div class="tick" data-id="${esc(r.kind)}-${esc(r.ref_id)}">
        <span class="tick-time">${esc(timeOnly(r.occurred_at))}</span>
        <span><span class="tick-plate">${esc(r.plate_number)}</span>
          <span class="tick-bay"> · ${esc(detail(r))}</span></span>
        <span class="tick-dir ${k.cls}">${icon(k.ic)}${k.word}</span>
      </div>`;
    }).join('');

    if (full) {
      revealList(host.querySelectorAll('.tick'), { step: 0.03 });
    } else {
      // Only genuinely new events animate; the rest simply stay put.
      host.querySelectorAll('.tick').forEach((el) => {
        if (!lastTickIds.has(el.dataset.id)) insertLive(el);
      });
    }
    lastTickIds = ids;
  }
}
