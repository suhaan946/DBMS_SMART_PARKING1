/* settings.js — tariffs, facility structure and the audit trail (admin only). */
import { api } from './api.js';
import {
  mountShell, icon, esc, money, dateOnly, dateTime, titleCase, errorState, skeleton, empty,
  modal, toast, errorToast, fieldError, clearErrors, submitting, dataTable, tabs,
} from './ui.js';
import { enter } from './motion.js';

const AUDITED = ['reservation', 'parking_session', 'bill', 'payment', 'parking_pass',
                 'customer', 'vehicle', 'slot', 'tariff', 'violation'];
const ACTION_BADGE = { INSERT: 'free', UPDATE: 'held', DELETE: 'unpaid' };

const ctx = mountShell('settings.html', {
  title: 'Settings',
  subtitle: 'Tariffs, facility structure and the audit trail',
});
if (ctx) init(ctx);

async function init({ content, user }) {
  if (user.role !== 'admin') {
    empty(content, { title: 'Administrators only',
                     body: 'Tariffs, facility structure and the audit trail are managed by an administrator.',
                     iconName: 'lock', action: { href: 'dashboard.html', label: 'Back to the dashboard' } });
    return;
  }

  content.innerHTML = `
    <div id="settings-tabs"></div>
    <section class="panel tabpanel" id="panel-tariffs" role="tabpanel">
      <div class="panel-head">
        <h2>Tariffs</h2>
        <span class="spacer"></span>
        <button class="btn btn-primary btn-sm" id="new-tariff" data-interactive>${icon('plus')} New tariff</button>
      </div>
      <p class="rule-note">${icon('lock')}
        Tariffs are never edited in place: a new one closes the old, so past bills still
        re-derive from their rates. Overlaps are refused (<code>ex_tariff_no_overlap</code>).</p>
      <div id="tariffs"></div>
    </section>
    <section class="tabpanel" id="panel-structure" role="tabpanel" hidden>
      <section class="panel" style="margin-bottom:var(--s5)">
        <div class="panel-head"><h2>Facilities</h2>
          <span class="hint">Seeded by migration; read-only here</span></div>
        <div id="facilities"></div>
      </section>
      <section class="panel">
        <div class="panel-head"><h2>Vehicle types</h2></div>
        <div id="types"></div>
      </section>
    </section>
    <section class="panel tabpanel" id="panel-audit" role="tabpanel" hidden>
      <div class="panel-head">
        <label class="sr-only" for="audit-table">Table</label>
        <select class="select" id="audit-table" style="max-width:220px">
          <option value="">Every table</option>
          ${AUDITED.map((t) => `<option value="${t}">${titleCase(t)}</option>`).join('')}
        </select>
        <span class="spacer"></span>
        <button class="btn btn-sm" type="button" id="audit-refresh">${icon('refresh')} Refresh</button>
      </div>
      <p class="rule-note">${icon('history')}
        Written by the <code>trg_audit</code> trigger on every insert, update and delete.
        No application role can edit or delete it.</p>
      <div id="audit"></div>
    </section>`;

  let auditLoaded = false, auditTable = null;
  tabs(content.querySelector('#settings-tabs'), [
    { id: 'tariffs', label: 'Tariffs', icon: 'receipt', panel: 'panel-tariffs' },
    { id: 'structure', label: 'Facilities', icon: 'grid', panel: 'panel-structure' },
    { id: 'audit', label: 'Audit trail', icon: 'history', panel: 'panel-audit' },
  ], { label: 'Settings sections', onChange: (id) => { if (id === 'audit' && !auditLoaded) loadAudit(); } });

  content.querySelector('#new-tariff').addEventListener('click', () => newTariff(load));
  content.querySelector('#audit-table').addEventListener('change', loadAudit);
  content.querySelector('#audit-refresh').addEventListener('click', loadAudit);
  enter(content.querySelector('#panel-tariffs'));
  let tariffTable = null;
  load();

  async function load() {
    let facilities, types, tariffs;
    try {
      [facilities, types, tariffs] = await Promise.all([
        api.facilities(), api.vehicleTypes(), api.tariffs()]);
    } catch (err) { errorState(content.querySelector('#tariffs'), err, load); return; }

    content.querySelector('#facilities').innerHTML = `
      <div class="table-wrap"><table>
        <caption class="sr-only">Facilities</caption>
        <thead><tr><th scope="col">Name</th><th scope="col">Address</th>
          <th scope="col">Hours</th><th scope="col" class="num">Tax rate</th></tr></thead>
        <tbody>${facilities.map((f) => `<tr>
          <td class="cell-strong">${esc(f.name)}</td>
          <td>${esc(f.address_line)}, ${esc(f.city)}</td>
          <td class="mono">${esc(String(f.opens_at).slice(0, 5))}–${esc(String(f.closes_at).slice(0, 5))}</td>
          <td class="num mono">${esc(f.tax_rate_pct)}%</td></tr>`).join('')}</tbody>
      </table></div>`;
    content.querySelector('#types').innerHTML = `
      <div class="table-wrap"><table>
        <caption class="sr-only">Vehicle types</caption>
        <thead><tr><th scope="col">Code</th><th scope="col">Name</th></tr></thead>
        <tbody>${types.map((t) => `<tr>
          <td class="mono">${esc(t.code)}</td><td>${esc(t.name)}</td></tr>`).join('')}</tbody>
      </table></div>`;

    if (tariffTable) { tariffTable.setRows(tariffs); return; }
    tariffTable = dataTable(content.querySelector('#tariffs'), {
      caption: 'Tariffs',
      rows: tariffs,
      searchPlaceholder: 'Search facility, vehicle type or name',
      csv: 'smartpark-tariffs.csv',
      emptyTitle: 'No tariffs configured',
      emptyBody: 'Open one so exits can be billed.',
      columns: [
        { key: 'facility_name', label: 'Facility', render: (t) => esc(t.facility_name) },
        { key: 'vehicle_type_name', label: 'Vehicle type', render: (t) => esc(t.vehicle_type_name) },
        { key: 'name', label: 'Name', csvOnly: true },
        { key: 'free_minutes', label: 'Free', num: true, render: (t) => `<span class="mono">${t.free_minutes}m</span>` },
        { key: 'first_hour_rate', label: 'First hour', num: true,
          render: (t) => `<span class="money">${esc(money(t.first_hour_rate))}</span>` },
        { key: 'subsequent_hour_rate', label: 'Thereafter', num: true,
          render: (t) => `<span class="money">${esc(money(t.subsequent_hour_rate))}</span>` },
        { key: 'daily_cap', label: 'Daily cap', num: true,
          render: (t) => `<span class="money">${esc(money(t.daily_cap))}</span>` },
        { key: 'in_force', label: 'In force', value: (t) => (t.in_force ? 0 : 1),
          render: (t) => t.in_force ? '<span class="badge badge-active">Current</span>'
            : `<span class="badge badge-neutral">Until ${esc(dateOnly(t.effective_to))}</span>` },
      ],
    });
  }

  async function loadAudit() {
    auditLoaded = true;
    const host = content.querySelector('#audit');
    if (!auditTable) skeleton(host, { rows: 6 });
    let rows;
    try { rows = await api.audit({ table: content.querySelector('#audit-table').value, limit: 300 }); }
    catch (err) { auditTable = null; errorState(host, err, loadAudit); return; }
    if (auditTable) { auditTable.setRows(rows); return; }
    auditTable = dataTable(host, {
      caption: 'Audit trail',
      rows,
      searchPlaceholder: 'Search person, table or change',
      csv: 'smartpark-audit.csv',
      note: `Latest ${rows.length} changes`,
      emptyTitle: 'No changes recorded here yet',
      emptyBody: 'Inserts, updates and deletes on this table will appear as they happen.',
      columns: [
        { key: 'occurred_at', label: 'When',
          render: (a) => `<span class="mono nowrap">${esc(dateTime(a.occurred_at))}</span>` },
        { key: 'actor_name', label: 'Who', value: (a) => a.actor_name || 'System',
          render: (a) => a.actor_name
            ? `<span class="cell-strong">${esc(a.actor_name)}</span><div class="cell-sub">${esc(titleCase(a.actor_role))}</div>`
            : '<span class="muted">System</span>' },
        { key: 'action', label: 'Action',
          render: (a) => `<span class="badge badge-${ACTION_BADGE[a.action] || 'neutral'}">${esc(titleCase(a.action.toLowerCase()))}</span>` },
        { key: 'table_name', label: 'Record', value: (a) => `${a.table_name} ${a.row_id}`,
          render: (a) => `${esc(titleCase(a.table_name))} <span class="mono muted">#${a.row_id}</span>` },
        { key: 'changes', label: 'Change', sortable: false, value: (a) => summarise(a),
          render: (a) => `<span class="audit-summary">${esc(summarise(a))}</span>` },
      ],
      onRowClick: showChange,
    });
  }
}

/* One line describing a change, e.g. "is_active: true → false, service_note: — → Drain". */
function summarise(a) {
  if (a.action !== 'UPDATE') {
    return `${a.action === 'INSERT' ? 'Created' : 'Deleted'} with ${Object.keys(a.changes || {}).length} fields`;
  }
  return Object.entries(a.changes || {}).map(([k, v]) =>
    `${k}: ${show(v.from)} → ${show(v.to)}`).join(', ');
}
// Timestamps arrive as ISO strings from to_jsonb(); show them as the rest of
// the app does rather than as 2026-10-05T16:10:37.546915+05:30.
const ISO_TS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/;
const show = (v) => v === null || v === undefined ? '—'
  : typeof v === 'object' ? JSON.stringify(v)
  : typeof v === 'string' && ISO_TS.test(v) ? dateTime(v) : String(v);

function showChange(a) {
  const entries = Object.entries(a.changes || {});
  modal({
    title: `${titleCase(a.action.toLowerCase())} · ${titleCase(a.table_name)} #${a.row_id}`,
    width: '620px',
    body: `
      <dl class="dl" style="margin-bottom:var(--s4)">
        <dt>When</dt><dd class="mono">${esc(dateTime(a.occurred_at))}</dd>
        <dt>Who</dt><dd>${esc(a.actor_name || 'System (no signed-in user)')}${
          a.actor_role ? ` · ${esc(titleCase(a.actor_role))}` : ''}</dd>
      </dl>
      <div class="table-wrap"><table class="audit-diff">
        <caption class="sr-only">Changed fields</caption>
        <thead><tr><th scope="col">Field</th>${a.action === 'UPDATE'
          ? '<th scope="col">Before</th><th scope="col">After</th>' : '<th scope="col">Value</th>'}</tr></thead>
        <tbody>${entries.map(([k, v]) => a.action === 'UPDATE'
          ? `<tr><td class="mono">${esc(k)}</td><td class="mono muted">${esc(show(v.from))}</td>
               <td class="mono">${esc(show(v.to))}</td></tr>`
          : `<tr><td class="mono">${esc(k)}</td><td class="mono">${esc(show(v))}</td></tr>`).join('')}</tbody>
      </table></div>`,
    actions: [{ label: 'Close', variant: 'primary', onClick: (c) => c() }],
  });
}

async function newTariff(onDone) {
  let facilities, types;
  try { [facilities, types] = await Promise.all([api.facilities(), api.vehicleTypes()]); }
  catch (err) { errorToast('Could not open the form', err); return; }

  modal({
    title: 'Open a new tariff',
    width: '620px',
    body: `
      <p style="color:var(--ink-2);font-size:var(--t-sm);margin-bottom:var(--s4)">
        The tariff currently in force for this facility and vehicle type will be
        closed with today's date. Bills already raised keep their original rates.
      </p>
      <form id="t-form" novalidate>
        <div class="form-row">
          <div class="field"><label for="t-facility">Facility</label>
            <select class="select" id="t-facility" required>${facilities.map((f) =>
              `<option value="${f.facility_id}">${esc(f.name)}</option>`).join('')}</select>
            <div class="field-error"></div></div>
          <div class="field"><label for="t-type">Vehicle type</label>
            <select class="select" id="t-type" required>${types.map((t) =>
              `<option value="${t.vehicle_type_id}">${esc(t.name)}</option>`).join('')}</select>
            <div class="field-error"></div></div>
        </div>
        <div class="field"><label for="t-name">Name</label>
          <input class="input" id="t-name" required placeholder="SmartPark Central — Car, 2026 rates">
          <div class="field-error"></div></div>
        <div class="form-row">
          <div class="field"><label for="t-free">Free minutes</label>
            <input class="input mono" type="number" id="t-free" value="15" min="0" max="1440" required>
            <div class="field-error"></div></div>
          <div class="field"><label for="t-first">First hour (₹)</label>
            <input class="input mono" type="number" id="t-first" value="40" min="0" step="1" required>
            <div class="field-error"></div></div>
        </div>
        <div class="form-row">
          <div class="field"><label for="t-next">Each hour after (₹)</label>
            <input class="input mono" type="number" id="t-next" value="25" min="0" step="1" required>
            <div class="field-error"></div></div>
          <div class="field"><label for="t-cap">Daily cap (₹)</label>
            <input class="input mono" type="number" id="t-cap" value="250" min="0" step="1" required>
            <div class="help">Cannot be lower than the first-hour rate.</div>
            <div class="field-error"></div></div>
        </div>
      </form>`,
    actions: [
      { label: 'Cancel', onClick: (c) => c() },
      { label: 'Open tariff', variant: 'primary', onClick: submit },
    ],
  });

  async function submit(close, scrim) {
    const form = scrim.querySelector('#t-form');
    clearErrors(form);
    const g = (id) => scrim.querySelector(id);
    const name = g('#t-name'), free = g('#t-free'), first = g('#t-first');
    const next = g('#t-next'), cap = g('#t-cap');

    let bad = false;
    if (!name.value.trim()) { fieldError(name, 'Give the tariff a name.'); bad = true; }
    for (const [el, label] of [[free, 'Free minutes'], [first, 'First hour'],
                               [next, 'Hourly rate'], [cap, 'Daily cap']]) {
      if (el.value === '' || Number(el.value) < 0) {
        fieldError(el, `${label} cannot be blank or negative.`); bad = true;
      }
    }
    if (!bad && Number(cap.value) < Number(first.value)) {
      fieldError(cap, 'The daily cap cannot be lower than the first-hour rate.'); bad = true;
    }
    if (bad) { scrim.querySelector('[aria-invalid="true"]')?.focus(); return; }

    const btn = scrim.querySelector('[data-action="1"]');
    await submitting(btn, async () => {
      try {
        await api.createTariff({
          facility_id: Number(g('#t-facility').value),
          vehicle_type_id: Number(g('#t-type').value),
          name: name.value.trim(),
          free_minutes: Number(free.value),
          first_hour_rate: Number(first.value),
          subsequent_hour_rate: Number(next.value),
          daily_cap: Number(cap.value),
        });
        toast('Tariff opened', 'New arrivals will be billed at these rates.', 'success');
        close(); onDone();
      } catch (err) { fieldError(name, err.rule ? `${err.message} (${err.rule})` : err.message); }
    });
  }
}
