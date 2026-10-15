/* reports.js — one tab per report named in the project statement.
   Each tab is a thin renderer over one database view. */
import { api } from './api.js';
import {
  mountShell, icon, esc, money, moneyShort, duration, dateOnly, dateTime, titleCase,
  skeleton, empty, errorState, facility, dataTable, tableToCSV, toast, errorToast, methodLabel,
} from './ui.js';
import { enter, revealList, countTo, bindInteractive } from './motion.js';
import { lineChart, barChart, stackBar } from './charts.js';

const TABS = [
  { id: 'occupancy',  label: 'Occupancy',  view: 'v_current_occupancy' },
  { id: 'peak',       label: 'Peak hours', view: 'v_peak_hours' },
  { id: 'revenue',    label: 'Revenue',    view: 'v_revenue_daily' },
  { id: 'duration',   label: 'Duration',   view: 'v_session_duration' },
  { id: 'passes',     label: 'Pass usage', view: 'v_pass_usage' },
  { id: 'violations', label: 'Violations', view: 'v_violations' },
  { id: 'free',       label: 'Free slots', view: 'v_free_slots' },
  { id: 'vehicle',    label: 'Vehicle history', view: 'v_session_duration' },
];

const ctx = mountShell('reports.html', {
  title: 'Reports',
  subtitle: 'Occupancy, revenue, usage and violations',
});
if (ctx) init(ctx);

async function init({ content, user }) {
  content.innerHTML = `
    <div class="toolbar">
      <label class="sr-only" for="facility">Facility</label>
      <select class="select" id="facility" style="max-width:260px"></select>
      <span class="spacer"></span>
      <button class="btn btn-sm" type="button" id="export" disabled>${icon('download')} Export CSV</button>
    </div>
    <div class="tabs" id="tabs" role="tablist" aria-label="Reports"></div>
    <div id="panel"></div>`;

  const selF = content.querySelector('#facility');
  let facilities;
  try { facilities = await api.facilities(); }
  catch (err) { errorState(content, err, () => location.reload()); return; }

  const scoped = user.facility_id
    ? facilities.filter((f) => f.facility_id === user.facility_id) : facilities;
  selF.innerHTML = scoped.map((f) =>
    `<option value="${f.facility_id}">${esc(f.name)}</option>`).join('');
  if (scoped.length === 1) selF.disabled = true;
  const remembered = facility.get();
  if (remembered && scoped.some((f) => f.facility_id === remembered)) selF.value = String(remembered);
  selF.addEventListener('change', () => { facility.set(Number(selF.value)); show(active); });

  const tabsHost = content.querySelector('#tabs');
  let active = location.hash.slice(1) || 'occupancy';
  if (!TABS.some((t) => t.id === active)) active = 'occupancy';

  tabsHost.innerHTML = TABS.map((t) => `<button class="tab" role="tab" id="tab-${t.id}"
      aria-selected="${t.id === active}" aria-controls="panel"
      data-tab="${t.id}">${esc(t.label)}</button>`).join('');
  tabsHost.querySelectorAll('.tab').forEach((b) =>
    b.addEventListener('click', () => { location.hash = b.dataset.tab; show(b.dataset.tab); }));
  // Arrow-key navigation between tabs, as a tablist should have.
  tabsHost.addEventListener('keydown', (e) => {
    if (!['ArrowLeft', 'ArrowRight'].includes(e.key)) return;
    const i = TABS.findIndex((t) => t.id === active);
    const next = TABS[(i + (e.key === 'ArrowRight' ? 1 : TABS.length - 1)) % TABS.length];
    location.hash = next.id; show(next.id);
    tabsHost.querySelector(`#tab-${next.id}`)?.focus();
  });

  show(active);

  // A hash change is a same-document navigation: the module does not re-run, so
  // without this the Back button would move the URL but leave the panel behind.
  window.addEventListener('hashchange', () => {
    const id = location.hash.slice(1);
    if (TABS.some((t) => t.id === id) && id !== active) show(id);
  });

  content.querySelector('#export').addEventListener('click', () => {
    const tables = content.querySelectorAll('#panel table');
    const table = tables[tables.length - 1];
    if (!table) return;
    const n = tableToCSV(table, `smartpark-${active}-${selF.selectedOptions[0]?.textContent
      .trim().toLowerCase().replace(/\s+/g, '-') || 'all'}.csv`);
    toast('Export ready', `${n} rows from the ${TABS.find((t) => t.id === active).label} report.`, 'success');
  });

  async function show(id) {
    active = id;
    tabsHost.querySelectorAll('.tab').forEach((b) => {
      const on = b.dataset.tab === id;
      b.setAttribute('aria-selected', String(on));
      b.tabIndex = on ? 0 : -1;            // roving tabindex: Tab enters the list once
    });
    content.querySelector('#export').disabled = true;
    selF.disabled = id === 'vehicle' || selF.options.length < 2;
    const host = content.querySelector('#panel');
    host.setAttribute('role', 'tabpanel');
    host.setAttribute('aria-labelledby', `tab-${id}`);
    skeleton(host, { rows: 4 });
    const fid = Number(selF.value);
    try {
      await ({ occupancy, peak, revenue, duration: dur, passes, violations, free,
               vehicle: vehicleHistory }[id])(host, fid);
      enter(host);
      content.querySelector('#export').disabled = !host.querySelector('table');
    } catch (err) { errorState(host, err, () => show(id)); }
  }
}

const viewNote = (view, text) => `
  <p class="section-note">${text}
  <span style="color:var(--ink-2)">Source: <code class="mono">${view}</code>.</span></p>`;

/* --- Occupancy ---------------------------------------------------------- */
async function occupancy(host, fid) {
  const d = await api.report.occupancy(fid);
  if (!d.by_zone.length) {
    empty(host, { title: 'No bays configured for this facility',
                  body: 'Add floors, zones and slots before this report can say anything.',
                  iconName: 'grid' });
    return;
  }
  const tot = d.by_zone.reduce((a, z) => ({
    total: a.total + Number(z.total), occupied: a.occupied + Number(z.occupied),
    free: a.free + Number(z.free), reserved: a.reserved + Number(z.reserved),
    out: a.out + Number(z.out_of_service),
  }), { total: 0, occupied: 0, free: 0, reserved: 0, out: 0 });

  host.innerHTML = viewNote('v_current_occupancy',
    'Live state of every bay, derived from open parking sessions rather than a stored flag.') + `
    <div class="stat-row">
      <div class="stat stat-accent"><div class="stat-label">Occupancy</div>
        <div class="stat-value" data-count="${Math.round(tot.occupied / tot.total * 100)}"
             data-suffix="%">0%</div>
        <div class="stat-foot">${tot.occupied} of ${tot.total} bays</div></div>
      <div class="stat"><div class="stat-label">Free</div>
        <div class="stat-value" data-count="${tot.free}">0</div></div>
      <div class="stat"><div class="stat-label">Reserved</div>
        <div class="stat-value" data-count="${tot.reserved}">0</div></div>
      <div class="stat"><div class="stat-label">Out of service</div>
        <div class="stat-value" data-count="${tot.out}">0</div></div>
    </div>
    <section class="card" style="margin-bottom:var(--s5)">
      <div class="card-head"><h2>Across the building</h2></div>
      <div id="stack"></div>
      <div class="legend" style="margin-top:var(--s3)">
        <span class="legend-item"><span class="sw sw-free"></span>Free ${tot.free}</span>
        <span class="legend-item"><span class="sw sw-held"></span>Reserved ${tot.reserved}</span>
        <span class="legend-item"><span class="sw sw-full"></span>Occupied ${tot.occupied}</span>
        <span class="legend-item"><span class="sw sw-off"></span>Out of service ${tot.out}</span>
      </div>
    </section>
    <section class="card" style="margin-bottom:var(--s5)">
      <div class="card-head"><h2>By floor and zone</h2></div>
      <div class="table-wrap"><table>
        <thead><tr><th scope="col">Floor</th><th scope="col">Zone</th>
          <th scope="col" class="num">Bays</th><th scope="col" class="num">Occupied</th>
          <th scope="col" class="num">Free</th><th scope="col" class="num">Reserved</th>
          <th scope="col" class="num">Occupancy</th></tr></thead>
        <tbody>${d.by_zone.map((z) => `<tr>
          <td>${esc(z.floor_name)}</td><td>Zone ${esc(z.zone_code)}</td>
          <td class="num mono">${z.total}</td><td class="num mono">${z.occupied}</td>
          <td class="num mono">${z.free}</td><td class="num mono">${z.reserved}</td>
          <td class="num mono">${z.occupancy_pct}%</td></tr>`).join('')}</tbody>
      </table></div>
    </section>
    <section class="card">
      <div class="card-head"><h2>Bays by vehicle type</h2></div>
      <div id="types"></div>
    </section>`;

  stackBar(host.querySelector('#stack'), [
    { label: 'Free', value: tot.free, tone: 'free' },
    { label: 'Reserved', value: tot.reserved, tone: 'held' },
    { label: 'Occupied', value: tot.occupied, tone: 'full' },
    { label: 'Out of service', value: tot.out, tone: 'off' },
  ], { accessibleName: `Occupancy: ${tot.occupied} occupied of ${tot.total} bays` });

  barChart(host.querySelector('#types'),
    d.by_type.map((t) => ({ label: t.vehicle_type_name.split(' ')[0], value: Number(t.total) })),
    { accessibleName: 'Bays by vehicle type' });
  animateCounts(host);
}

/* --- Peak hours --------------------------------------------------------- */
async function peak(host, fid) {
  const rows = await api.report.peak(fid);
  if (!rows.length) {
    empty(host, { title: 'No arrivals recorded yet',
                  body: 'Record gate entries and this curve fills in by hour of day.',
                  iconName: 'chart' });
    return;
  }
  const byHour = new Map(rows.map((r) => [Number(r.hour_of_day), r]));
  const busiest = rows.reduce((a, b) => Number(a.entries) >= Number(b.entries) ? a : b);
  const total = rows.reduce((a, r) => a + Number(r.entries), 0);

  host.innerHTML = viewNote('v_peak_hours',
    'Arrivals grouped by hour of day, with a RANK() window over the aggregate to mark the peak.') + `
    <div class="stat-row">
      <div class="stat stat-accent"><div class="stat-label">Busiest hour</div>
        <div class="stat-value mono">${String(busiest.hour_of_day).padStart(2, '0')}:00</div>
        <div class="stat-foot">${busiest.entries} arrivals</div></div>
      <div class="stat"><div class="stat-label">Arrivals recorded</div>
        <div class="stat-value" data-count="${total}">0</div>
        <div class="stat-foot">across all hours</div></div>
      <div class="stat"><div class="stat-label">Average stay at peak</div>
        <div class="stat-value mono">${duration(busiest.avg_stay_minutes)}</div></div>
    </div>
    <section class="card" style="margin-bottom:var(--s5)">
      <div class="card-head"><h2>Arrivals by hour of day</h2>
        <span class="hint">Bars in clay mark the peak hours</span></div>
      <div id="chart"></div>
    </section>
    <section class="card">
      <div class="table-wrap"><table>
        <thead><tr><th scope="col">Hour</th><th scope="col" class="num">Arrivals</th>
          <th scope="col" class="num">Still parked</th>
          <th scope="col" class="num">Average stay</th><th scope="col">Rank</th></tr></thead>
        <tbody>${rows.map((r) => `<tr>
          <td class="mono">${String(r.hour_of_day).padStart(2, '0')}:00</td>
          <td class="num mono">${r.entries}</td>
          <td class="num mono">${r.still_parked}</td>
          <td class="num mono">${esc(duration(r.avg_stay_minutes))}</td>
          <td>${Number(r.busyness_rank) <= 3
            ? `<span class="badge badge-occupied">Peak #${r.busyness_rank}</span>`
            : `<span style="color:var(--ink-2)">#${r.busyness_rank}</span>`}</td>
        </tr>`).join('')}</tbody></table></div>
    </section>`;

  // Every hour 0-23, so quiet hours read as genuinely quiet rather than absent.
  barChart(host.querySelector('#chart'),
    Array.from({ length: 24 }, (_, h) => {
      const r = byHour.get(h);
      return { label: String(h).padStart(2, '0'),
               value: r ? Number(r.entries) : 0,
               tone: r && Number(r.busyness_rank) <= 3 ? 'full' : null };
    }), { accessibleName: `Arrivals by hour; busiest is ${busiest.hour_of_day}:00` });
  animateCounts(host);
}

/* --- Revenue ------------------------------------------------------------ */
async function revenue(host, fid) {
  const d = await api.report.revenue(fid);
  if (!d.daily.length) {
    empty(host, { title: 'No revenue in this period',
                  body: 'Bills appear here once vehicles exit the gate.', iconName: 'receipt' });
    return;
  }
  const billed = d.daily.reduce((a, r) => a + Number(r.billed_total), 0);
  const collected = d.daily.reduce((a, r) => a + Number(r.collected_total), 0);
  const outstanding = billed - collected;

  host.innerHTML = viewNote('v_revenue_daily',
    'Billed and collected are separate figures; the gap between them is the receivable.') + `
    <div class="stat-row">
      <div class="stat stat-accent"><div class="stat-label">Collected</div>
        <div class="stat-value" data-count="${collected}" data-money="1">₹0</div>
        <div class="stat-foot">over ${d.daily.length} days</div></div>
      <div class="stat"><div class="stat-label">Billed</div>
        <div class="stat-value" data-count="${billed}" data-money="1">₹0</div>
        <div class="stat-foot">${d.daily.reduce((a, r) => a + Number(r.bills_raised), 0)} bills</div></div>
      <div class="stat"><div class="stat-label">Outstanding</div>
        <div class="stat-value" data-count="${outstanding}" data-money="1">₹0</div>
        <div class="stat-foot">${(outstanding / billed * 100).toFixed(1)}% of billed</div></div>
      <div class="stat"><div class="stat-label">Average bill</div>
        <div class="stat-value" data-count="${billed / Math.max(1, d.daily.reduce(
          (a, r) => a + Number(r.bills_raised), 0))}" data-money="1">₹0</div></div>
    </div>
    <section class="card" style="margin-bottom:var(--s5)">
      <div class="card-head"><h2>Billed per day</h2></div>
      <div id="chart"></div>
    </section>
    <section class="card" style="margin-bottom:var(--s5)">
      <div class="card-head"><h2>How customers paid</h2></div>
      <div class="table-wrap"><table>
        <thead><tr><th scope="col">Method</th><th scope="col" class="num">Payments</th>
          <th scope="col" class="num">Amount</th><th scope="col" class="num">Share</th></tr></thead>
        <tbody>${d.by_method.map((m) => {
          const totalPaid = d.by_method.reduce((a, x) => a + Number(x.amount), 0);
          return `<tr><td>${esc(methodLabel(m.method))}</td>
            <td class="num mono">${m.n}</td>
            <td class="num money">${esc(money(m.amount))}</td>
            <td class="num mono">${(Number(m.amount) / totalPaid * 100).toFixed(1)}%</td></tr>`;
        }).join('')}</tbody></table></div>
    </section>
    <section class="card">
      <div class="card-head"><h2>Day by day</h2></div>
      <div class="table-wrap"><table>
        <thead><tr><th scope="col">Date</th><th scope="col" class="num">Bills</th>
          <th scope="col" class="num">Base</th><th scope="col" class="num">Tax</th>
          <th scope="col" class="num">Billed</th><th scope="col" class="num">Collected</th>
          <th scope="col" class="num">Outstanding</th></tr></thead>
        <tbody>${[...d.daily].reverse().map((r) => `<tr>
          <td class="mono">${esc(dateOnly(r.revenue_date))}</td>
          <td class="num mono">${r.bills_raised}</td>
          <td class="num money">${esc(money(r.base_revenue))}</td>
          <td class="num money">${esc(money(r.tax_collected))}</td>
          <td class="num money">${esc(money(r.billed_total))}</td>
          <td class="num money">${esc(money(r.collected_total))}</td>
          <td class="num money" style="${Number(r.outstanding_total) > 0
            ? 'color:var(--alert-ink)' : ''}">${esc(money(r.outstanding_total))}</td>
        </tr>`).join('')}</tbody></table></div>
    </section>`;

  lineChart(host.querySelector('#chart'), d.daily.map((r) => ({
    label: new Date(r.revenue_date).toLocaleDateString('en-IN', { day: '2-digit', month: 'short' }),
    value: Number(r.billed_total),
  })), { format: (v) => '₹' + Math.round(v).toLocaleString('en-IN'), height: 220,
         accessibleName: 'Amount billed per day' });
  animateCounts(host);
}

/* --- Duration ----------------------------------------------------------- */
async function dur(host, fid) {
  const rows = await api.report.duration(fid);
  if (!rows.length) {
    empty(host, { title: 'No completed sessions yet',
                  body: 'Durations appear once vehicles have entered and exited.',
                  iconName: 'clock' });
    return;
  }
  const LABEL = { under_30m: 'Under 30 min', '30m_2h': '30 min – 2 h', '2h_8h': '2 – 8 h',
                  '8h_24h': '8 – 24 h', over_24h: 'Over 24 h' };
  const total = rows.reduce((a, r) => a + Number(r.sessions), 0);
  const revenueAll = rows.reduce((a, r) => a + Number(r.revenue), 0);

  host.innerHTML = viewNote('v_session_duration',
    'Stays bucketed with a CASE expression, joined out to the bill each one produced.') + `
    <div class="stat-row">
      <div class="stat"><div class="stat-label">Completed sessions</div>
        <div class="stat-value" data-count="${total}">0</div></div>
      <div class="stat stat-accent"><div class="stat-label">Revenue from them</div>
        <div class="stat-value" data-count="${revenueAll}" data-money="1">₹0</div></div>
      <div class="stat"><div class="stat-label">Most common stay</div>
        <div class="stat-value" style="font-size:var(--t-md);font-family:var(--font-ui)">${
          esc(LABEL[rows.reduce((a, b) => Number(a.sessions) >= Number(b.sessions)
            ? a : b).duration_bucket])}</div></div>
    </div>
    <section class="card" style="margin-bottom:var(--s5)">
      <div class="card-head"><h2>How long vehicles stay</h2></div>
      <div id="chart"></div>
    </section>
    <section class="card">
      <div class="table-wrap"><table>
        <thead><tr><th scope="col">Length of stay</th><th scope="col" class="num">Sessions</th>
          <th scope="col" class="num">Share</th><th scope="col" class="num">Average</th>
          <th scope="col" class="num">Revenue</th></tr></thead>
        <tbody>${rows.map((r) => `<tr>
          <td>${esc(LABEL[r.duration_bucket] || r.duration_bucket)}</td>
          <td class="num mono">${r.sessions}</td>
          <td class="num mono">${(Number(r.sessions) / total * 100).toFixed(1)}%</td>
          <td class="num mono">${esc(duration(r.avg_minutes))}</td>
          <td class="num money">${esc(money(r.revenue))}</td></tr>`).join('')}</tbody>
      </table></div>
    </section>`;
  barChart(host.querySelector('#chart'),
    rows.map((r) => ({ label: LABEL[r.duration_bucket] || r.duration_bucket,
                       value: Number(r.sessions) })),
    { accessibleName: 'Sessions by length of stay' });
  animateCounts(host);
}

/* --- Pass usage --------------------------------------------------------- */
async function passes(host, fid) {
  const rows = await api.report.passUsage();
  if (!rows.length) {
    empty(host, { title: 'No passes sold yet',
                  body: 'Sell a pass from the Passes screen and its usage appears here.',
                  iconName: 'ticket' });
    return;
  }
  const active = rows.filter((r) => r.pass_state === 'active');
  const revenueAll = rows.filter((r) => r.pass_state !== 'cancelled')
                         .reduce((a, r) => a + Number(r.price_paid), 0);
  host.innerHTML = viewNote('v_pass_usage',
    'A LATERAL subquery counts the sessions each pass actually covered.') + `
    <div class="stat-row">
      <div class="stat stat-accent"><div class="stat-label">Active passes</div>
        <div class="stat-value" data-count="${active.length}">0</div>
        <div class="stat-foot">of ${rows.length} sold</div></div>
      <div class="stat"><div class="stat-label">Pass revenue</div>
        <div class="stat-value" data-count="${revenueAll}" data-money="1">₹0</div></div>
      <div class="stat"><div class="stat-label">Stays covered</div>
        <div class="stat-value" data-count="${rows.reduce(
          (a, r) => a + Number(r.sessions_used), 0)}">0</div>
        <div class="stat-foot">billed at zero</div></div>
    </div>
    <section class="card">
      <div class="table-wrap"><table>
        <thead><tr><th scope="col">Customer</th><th scope="col">Vehicle</th>
          <th scope="col">Product</th><th scope="col">Valid</th>
          <th scope="col" class="num">Paid</th><th scope="col" class="num">Stays</th>
          <th scope="col" class="num">Time used</th><th scope="col">State</th></tr></thead>
        <tbody>${rows.map((r) => `<tr>
          <td>${esc(r.customer_name)}</td><td class="reg">${esc(r.plate_number)}</td>
          <td>${esc(r.pass_type_name)}</td>
          <td class="mono" style="white-space:nowrap">${esc(dateOnly(r.valid_from))} →
            ${esc(dateOnly(r.valid_to))}</td>
          <td class="num money">${esc(money(r.price_paid))}</td>
          <td class="num mono">${r.sessions_used}</td>
          <td class="num mono">${esc(duration(r.minutes_used))}</td>
          <td><span class="badge badge-${esc(r.pass_state)}">${
            esc(titleCase(r.pass_state))}</span></td></tr>`).join('')}</tbody>
      </table></div>
    </section>`;
  animateCounts(host);
}

/* --- Violations --------------------------------------------------------- */
async function violations(host, fid) {
  const d = await api.report.violations();
  if (!d.violations.length) {
    empty(host, { title: 'No violations logged',
                  body: 'Overstays are logged automatically at gate exit.', iconName: 'check' });
    return;
  }
  const open = d.violations.filter((v) => !v.is_resolved).length;
  const penalties = d.summary.reduce((a, s) => a + Number(s.penalties), 0);
  host.innerHTML = viewNote('v_violations',
    'Infringements joined out to vehicle, customer, bay and session.') + `
    <div class="stat-row">
      <div class="stat"><div class="stat-label">Open</div>
        <div class="stat-value" data-count="${open}">0</div>
        <div class="stat-foot">${d.violations.length - open} resolved</div></div>
      <div class="stat"><div class="stat-label">Penalties levied</div>
        <div class="stat-value" data-count="${penalties}" data-money="1">₹0</div></div>
      ${d.summary.slice(0, 2).map((s) => `<div class="stat">
        <div class="stat-label">${esc(titleCase(s.kind))}</div>
        <div class="stat-value" data-count="${s.n}">0</div>
        <div class="stat-foot">${s.resolved} resolved</div></div>`).join('')}
    </div>
    <section class="card" style="margin-bottom:var(--s5)">
      <div class="card-head"><h2>By kind</h2></div>
      <div id="chart"></div>
    </section>
    <section class="card">
      <div class="card-head"><h2>Log</h2></div>
      <div class="table-wrap"><table>
        <thead><tr><th scope="col">Detected</th><th scope="col">Kind</th>
          <th scope="col">Vehicle</th><th scope="col">Customer</th><th scope="col">Bay</th>
          <th scope="col" class="num">Penalty</th><th scope="col">State</th></tr></thead>
        <tbody>${d.violations.map((v) => `<tr>
          <td class="mono" style="white-space:nowrap">${esc(dateTime(v.detected_at))}</td>
          <td><span class="badge badge-${v.is_resolved ? 'paid' : 'unpaid'}">${
            esc(titleCase(v.kind))}</span></td>
          <td class="reg">${esc(v.plate_number)}</td>
          <td>${esc(v.customer_name)}</td>
          <td class="mono">${esc(v.slot_code || '—')}</td>
          <td class="num money">${esc(money(v.penalty_amount))}</td>
          <td>${v.is_resolved
            ? '<span class="badge badge-paid">Resolved</span>'
            : '<span class="badge badge-unpaid">Open</span>'}</td></tr>`).join('')}</tbody>
      </table></div>
    </section>`;
  barChart(host.querySelector('#chart'),
    d.summary.map((s) => ({ label: titleCase(s.kind).replace(' ', ' '), value: Number(s.n) })),
    { accessibleName: 'Violations by kind' });
  animateCounts(host);
}

/* --- Free slots --------------------------------------------------------- */
async function free(host, fid) {
  const rows = await api.report.freeSlots(fid);
  if (!rows.length) {
    empty(host, { title: 'The facility is full',
                  body: 'Every bay is occupied, reserved or out of service right now.',
                  iconName: 'car' });
    return;
  }
  const total = rows.reduce((a, r) => a + Number(r.free_count), 0);
  host.innerHTML = viewNote('v_free_slots',
    'What an operator can allocate right now, grouped by where it is and what it fits.') + `
    <div class="stat-row">
      <div class="stat stat-accent"><div class="stat-label">Free right now</div>
        <div class="stat-value" data-count="${total}">0</div>
        <div class="stat-foot">across ${new Set(rows.map((r) => r.floor_name)).size} floors</div></div>
    </div>
    <section class="card">
      <div class="table-wrap"><table>
        <thead><tr><th scope="col">Floor</th><th scope="col">Zone</th>
          <th scope="col">Fits</th><th scope="col" class="num">Free</th>
          <th scope="col">Bays</th></tr></thead>
        <tbody>${rows.map((r) => `<tr>
          <td>${esc(r.floor_name)}</td><td>Zone ${esc(r.zone_code)}</td>
          <td>${esc(r.vehicle_type_name)}</td>
          <td class="num mono">${r.free_count}</td>
          <td class="mono" style="font-size:var(--t-xs);color:var(--ink-2)">${
            esc(r.slot_codes)}</td></tr>`).join('')}</tbody>
      </table></div>
    </section>`;
  animateCounts(host);
}

function animateCounts(host) {
  revealList(host.querySelectorAll('.stat'));
  host.querySelectorAll('[data-count]').forEach((el) => {
    const suffix = el.dataset.suffix || '';
    countTo(el, Number(el.dataset.count) || 0, {
      format: el.dataset.money ? moneyShort
        : (v) => Math.round(v).toLocaleString('en-IN') + suffix,
    });
  });
  revealList(host.querySelectorAll('tbody tr'), { step: 0.01, budget: 0.5 });
}

/* --- Vehicle history ---------------------------------------------------- */
async function vehicleHistory(host) {
  host.innerHTML = viewNote('v_session_duration',
    'Every stay one vehicle has made, across all facilities, with the bill each produced.') + `
    <form class="history-search" id="hist-form" novalidate>
      <div class="field" style="margin:0;flex:1;max-width:340px">
        <label for="hist-plate">Registration number</label>
        <input class="input reg" id="hist-plate" placeholder="TS09AB1234" autocomplete="off"
               spellcheck="false" maxlength="12">
        <div class="field-error"></div>
      </div>
      <button class="btn btn-primary" type="submit">${icon('search')} Show history</button>
    </form>
    <div id="hist-result"></div>`;
  const form = host.querySelector('#hist-form');
  const input = host.querySelector('#hist-plate');
  const out = host.querySelector('#hist-result');
  input.addEventListener('input', () => { input.value = input.value.toUpperCase().replace(/[^A-Z0-9]/g, ''); });
  let remembered = null;
  try { remembered = sessionStorage.getItem('sp.history.plate'); } catch { /* optional */ }
  empty(out, { title: 'Look up a vehicle', body: 'Enter a registration to see every stay, bill and its status.',
               iconName: 'history' });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const plate = input.value.trim();
    if (plate.length < 4) { input.focus(); return; }
    skeleton(out, { rows: 4 });
    let d;
    try { d = await api.report.vehicleHistory(plate); }
    catch (err) {
      if (err.status === 404) {
        empty(out, { title: `No vehicle ${plate} on file`, body: 'Check the registration and try again.', iconName: 'search' });
      } else errorState(out, err);
      return;
    }
    try { sessionStorage.setItem('sp.history.plate', plate); } catch { /* optional */ }
    const v = d.vehicle;
    const minutes = d.stays.filter((s) => !s.is_active).reduce((a, s) => a + Number(s.duration_minutes), 0);
    out.innerHTML = `
      <div class="stat-row">
        <div class="stat"><div class="stat-label">Vehicle</div>
          <div class="stat-value"><span class="plate-chip big-chip">${esc(v.plate_number)}</span></div>
          <div class="stat-foot">${esc([v.make, v.model, v.colour].filter(Boolean).join(' ') || v.vehicle_type_name)}</div></div>
        <div class="stat"><div class="stat-label">Owner</div>
          <div class="stat-value stat-text">${esc(v.customer_name)}</div>
          <div class="stat-foot mono">${esc(v.phone)}</div></div>
        <div class="stat"><div class="stat-label">Stays</div>
          <div class="stat-value" data-count="${d.totals.stays}">0</div>
          <div class="stat-foot">${esc(duration(minutes))} parked in total</div></div>
        <div class="stat stat-accent"><div class="stat-label">Billed</div>
          <div class="stat-value" data-count="${d.totals.billed}" data-money="1">₹0</div></div>
      </div>
      <section class="card"><div id="hist-table"></div></section>`;
    dataTable(out.querySelector('#hist-table'), {
      caption: `Stays for ${v.plate_number}`,
      rows: d.stays,
      searchPlaceholder: 'Search ticket, facility or bay',
      csv: `smartpark-history-${v.plate_number}.csv`,
      sort: { key: 'entry_time', dir: 'desc' },
      emptyTitle: 'No stays recorded for this vehicle',
      columns: [
        { key: 'ticket_no', label: 'Ticket', render: (s) => `<span class="mono">${esc(s.ticket_no)}</span>` },
        { key: 'facility_name', label: 'Facility', render: (s) => esc(s.facility_name) },
        { key: 'slot_code', label: 'Bay', render: (s) => `<span class="mono nowrap">${esc(s.slot_code)}</span>` },
        { key: 'entry_time', label: 'Entered', render: (s) => `<span class="mono nowrap">${esc(dateTime(s.entry_time))}</span>` },
        { key: 'exit_time', label: 'Exited', render: (s) => s.is_active
            ? '<span class="badge badge-occupied">Still parked</span>'
            : `<span class="mono nowrap">${esc(dateTime(s.exit_time))}</span>` },
        { key: 'duration_minutes', label: 'Stay', num: true,
          render: (s) => `<span class="mono nowrap">${esc(duration(s.duration_minutes))}</span>` },
        { key: 'total_amount', label: 'Bill', num: true,
          render: (s) => s.total_amount == null ? '<span class="muted">—</span>'
            : `<span class="money nowrap">${esc(money(s.total_amount))}</span>` },
        { key: 'bill_status', label: 'Status', render: (s) => s.bill_status
            ? `<span class="badge badge-${esc(s.bill_status)}">${esc(titleCase(s.bill_status))}</span>`
            : '<span class="muted">—</span>' },
      ],
    });
    animateCounts(out);
  });

  if (remembered) { input.value = remembered; form.requestSubmit(); }
  else input.focus();
}
