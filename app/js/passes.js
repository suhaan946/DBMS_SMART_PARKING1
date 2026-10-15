/* passes.js — sell, validate and cancel parking passes. */
import { api, auth } from './api.js';
import {
  mountShell, icon, esc, money, moneyShort, dateOnly, duration, titleCase,
  errorState, modal, toast, errorToast, fieldError, clearErrors, submitting, confirmDialog,
  dataTable, skeleton,
} from './ui.js';
import { enter, revealList, countTo } from './motion.js';

const STATES = [['active', 'Active'], ['scheduled', 'Scheduled'], ['expired', 'Expired'],
                ['cancelled', 'Cancelled'], ['all', 'All']];

const ctx = mountShell('passes.html', {
  title: 'Passes',
  subtitle: 'Season tickets and how much they are used',
});
if (ctx) init(ctx);

async function init({ content }) {
  content.innerHTML = `
    <div id="stats" class="stat-row"></div>
    <section class="panel" id="pass-panel">
      <div class="panel-head">
        <div class="seg" role="group" aria-label="Pass state" id="pass-seg"></div>
        <span class="spacer"></span>
        <button class="btn btn-primary" id="sell" data-interactive>${icon('plus')} Sell a pass</button>
      </div>
      <p class="rule-note">${icon('lock')}
        A pass bills every stay it covers at zero. One vehicle cannot hold two live passes at
        a facility over the same dates (<code>ex_pass_no_overlap</code>).</p>
      <div id="pass-table"></div>
    </section>`;

  let all = [], state = 'active', table = null;
  const seg = content.querySelector('#pass-seg');
  seg.addEventListener('click', (e) => {
    const b = e.target.closest('[data-state]');
    if (b) { state = b.dataset.state; paint(); }
  });
  content.querySelector('#sell').addEventListener('click', () => sellPass(load));
  enter(content.querySelector('#pass-panel'));
  load();

  async function load() {
    const host = content.querySelector('#pass-table');
    if (!table) skeleton(host, { rows: 5 });
    try { all = await api.passes(); }
    catch (err) { table = null; errorState(host, err, load); return; }
    renderStats();
    paint();
  }

  function renderStats() {
    const n = (s) => all.filter((p) => p.pass_state === s).length;
    const revenue = all.filter((p) => p.pass_state !== 'cancelled')
                       .reduce((a, p) => a + Number(p.price_paid || 0), 0);
    const host = content.querySelector('#stats');
    host.innerHTML = `
      <div class="stat"><div class="stat-label">${icon('ticket')} Active now</div>
        <div class="stat-value" data-count="${n('active')}">0</div>
        <div class="stat-foot">${n('scheduled')} starting later</div></div>
      <div class="stat"><div class="stat-label">${icon('clock')} Expired</div>
        <div class="stat-value" data-count="${n('expired')}">0</div>
        <div class="stat-foot">${n('cancelled')} cancelled</div></div>
      <div class="stat stat-accent"><div class="stat-label">${icon('receipt')} Pass revenue</div>
        <div class="stat-value" data-count="${revenue}" data-money="1">₹0</div>
        <div class="stat-foot">across ${all.length} passes sold</div></div>
      <div class="stat"><div class="stat-label">${icon('car')} Stays covered</div>
        <div class="stat-value" data-count="${all.reduce((a, p) => a + Number(p.sessions_used || 0), 0)}">0</div>
        <div class="stat-foot">sessions billed at zero</div></div>`;
    if (!host.dataset.shown) { revealList(host.querySelectorAll('.stat')); host.dataset.shown = '1'; }
    host.querySelectorAll('[data-count]').forEach((el) => countTo(el, Number(el.dataset.count),
      { format: el.dataset.money ? moneyShort : (v) => Math.round(v).toLocaleString('en-IN') }));
  }

  function paint() {
    seg.innerHTML = STATES.map(([id, label]) => `<button type="button" data-state="${id}"
        aria-pressed="${id === state}">${label} <span class="seg-count">${
        id === 'all' ? all.length : all.filter((p) => p.pass_state === id).length}</span></button>`).join('');
    const rows = state === 'all' ? all : all.filter((p) => p.pass_state === state);
    if (table) { table.setRows(rows); return; }
    table = dataTable(content.querySelector('#pass-table'), {
      caption: 'Passes',
      rows,
      searchPlaceholder: 'Search customer, registration or product',
      csv: 'smartpark-passes.csv',
      sort: { key: 'valid_to', dir: 'desc' },
      emptyTitle: 'No passes in this state',
      emptyBody: 'Use Sell a pass to issue one, or pick another state.',
      columns: [
        { key: 'customer_name', label: 'Customer',
          render: (p) => `<span class="cell-strong">${esc(p.customer_name)}</span>` },
        { key: 'plate_number', label: 'Vehicle',
          render: (p) => `<span class="plate-chip">${esc(p.plate_number)}</span>` },
        { key: 'pass_type_name', label: 'Product', render: (p) => esc(p.pass_type_name) },
        { key: 'valid_to', label: 'Valid',
          render: (p) => `<span class="mono nowrap">${esc(dateOnly(p.valid_from))}
            <span class="muted">→</span> ${esc(dateOnly(p.valid_to))}</span>
            ${p.pass_state === 'active' ? `<div class="cell-sub">${p.days_remaining} days left</div>` : ''}` },
        { key: 'price_paid', label: 'Paid', num: true,
          render: (p) => `<span class="money nowrap">${esc(money(p.price_paid))}</span>` },
        { key: 'sessions_used', label: 'Stays', num: true,
          render: (p) => `<span class="mono">${p.sessions_used}</span>
            <div class="cell-sub">${esc(duration(p.minutes_used))}</div>` },
        { key: 'pass_state', label: 'State',
          render: (p) => `<span class="badge badge-${esc(p.pass_state)}">${esc(titleCase(p.pass_state))}</span>` },
      ],
      rowActions: (p) => (p.pass_state === 'active' || p.pass_state === 'scheduled')
        ? [{ label: 'Cancel pass', icon: 'close', danger: true, onClick: () => cancel(p) }]
        : [{ label: 'No actions for a closed pass', icon: 'info', disabled: true }],
    });
  }

  async function cancel(p) {
    if (!await confirmDialog('Cancel this pass?',
      `${p.plate_number}'s ${p.pass_type_name} stops covering stays from now on. It stays on record for the usage report.`,
      'Cancel pass')) return;
    try {
      await api.cancelPass(p.pass_id);
      toast('Pass cancelled', 'Future stays will be billed at tariff.', 'success');
      load();
    } catch (err) { errorToast('Could not cancel the pass', err); }
  }
}

async function sellPass(onDone) {
  let customers, passTypes, facilities;
  try {
    [customers, passTypes, facilities] = await Promise.all([
      api.customers(), api.passTypes(), api.facilities()]);
  } catch (err) { errorToast('Could not open the form', err); return; }

  const today = new Date();
  const local = (d) => new Date(d.getTime() - d.getTimezoneOffset() * 60000)
                        .toISOString().slice(0, 10);

  modal({
    title: 'Sell a pass',
    width: '600px',
    body: `
      <form id="pass-form" novalidate>
        <div class="field">
          <label for="p-customer">Customer</label>
          <select class="select" id="p-customer" required>
            <option value="">Choose a customer…</option>
            ${customers.map((c) => `<option value="${c.customer_id}">${esc(c.full_name)} — ${
              esc(c.phone)}</option>`).join('')}
          </select><div class="field-error"></div>
        </div>
        <div class="field">
          <label for="p-vehicle">Vehicle</label>
          <select class="select" id="p-vehicle" required disabled>
            <option value="">Choose a customer first</option></select>
          <div class="field-error"></div>
        </div>
        <div class="field">
          <label for="p-type">Pass product</label>
          <select class="select" id="p-type" required disabled>
            <option value="">Choose a vehicle first</option></select>
          <div class="help">Only products matching that vehicle type are listed.
            Price and duration come from the product, not from this form.</div>
          <div class="field-error"></div>
        </div>
        <div class="form-row">
          <div class="field">
            <label for="p-facility">Facility</label>
            <select class="select" id="p-facility" required>
              ${facilities.map((f) => `<option value="${f.facility_id}">${
                esc(f.name)}</option>`).join('')}
            </select><div class="field-error"></div>
          </div>
          <div class="field">
            <label for="p-from">Valid from</label>
            <input class="input" type="date" id="p-from" value="${local(today)}" required>
            <div class="field-error"></div>
          </div>
        </div>
        <div id="p-summary"></div>
      </form>`,
    actions: [
      { label: 'Cancel', onClick: (c) => c() },
      { label: 'Sell pass', variant: 'primary', onClick: submit },
    ],
    onMount(scrim) {
      const cSel = scrim.querySelector('#p-customer');
      const vSel = scrim.querySelector('#p-vehicle');
      const tSel = scrim.querySelector('#p-type');
      const summary = scrim.querySelector('#p-summary');

      cSel.addEventListener('change', async () => {
        vSel.disabled = true; tSel.disabled = true; summary.innerHTML = '';
        tSel.innerHTML = '<option value="">Choose a vehicle first</option>';
        if (!cSel.value) { vSel.innerHTML = '<option value="">Choose a customer first</option>'; return; }
        vSel.innerHTML = '<option value="">Loading…</option>';
        try {
          const vs = await api.vehicles({ customer_id: cSel.value });
          if (!vs.length) {
            vSel.innerHTML = '<option value="">No vehicles on file for this customer</option>';
            return;
          }
          vSel.innerHTML = '<option value="">Choose a vehicle…</option>' + vs.map((v) =>
            `<option value="${v.vehicle_id}" data-type="${v.vehicle_type_id}">${
              esc(v.plate_number)} — ${esc(v.vehicle_type_name)}</option>`).join('');
          vSel.disabled = false;
        } catch (err) { vSel.innerHTML = `<option value="">${esc(err.message)}</option>`; }
      });

      vSel.addEventListener('change', () => {
        summary.innerHTML = '';
        const typeId = vSel.selectedOptions[0]?.dataset.type;
        const opts = passTypes.filter((p) => String(p.vehicle_type_id) === String(typeId));
        if (!opts.length) {
          tSel.innerHTML = '<option value="">No products for this vehicle type</option>';
          tSel.disabled = true; return;
        }
        tSel.innerHTML = '<option value="">Choose a product…</option>' + opts.map((p) =>
          `<option value="${p.pass_type_id}" data-days="${p.duration_days}" data-price="${p.price}">${
            esc(p.name)} — ${money(p.price)}</option>`).join('');
        tSel.disabled = false;
      });

      const refreshSummary = () => {
        const o = tSel.selectedOptions[0];
        if (!o?.value) { summary.innerHTML = ''; return; }
        const from = new Date(scrim.querySelector('#p-from').value);
        const to = new Date(from.getTime() + Number(o.dataset.days) * 86400000);
        summary.innerHTML = `<div class="pass-summary">
          <dl class="dl">
            <dt>Runs for</dt><dd class="mono">${o.dataset.days} ${Number(o.dataset.days) === 1 ? 'day' : 'days'}</dd>
            <dt>Expires</dt><dd class="mono">${esc(dateOnly(to.toISOString()))}</dd>
            <dt class="strong">Price</dt>
            <dd class="money strong">${esc(money(o.dataset.price))}</dd>
          </dl></div>`;
      };
      tSel.addEventListener('change', refreshSummary);
      scrim.querySelector('#p-from').addEventListener('change', refreshSummary);
    },
  });

  async function submit(close, scrim) {
    const form = scrim.querySelector('#pass-form');
    clearErrors(form);
    const c = scrim.querySelector('#p-customer'), v = scrim.querySelector('#p-vehicle');
    const t = scrim.querySelector('#p-type'), f = scrim.querySelector('#p-facility');
    const d = scrim.querySelector('#p-from');

    let bad = false;
    if (!c.value) { fieldError(c, 'Choose a customer.'); bad = true; }
    if (!v.value) { fieldError(v, 'Choose a vehicle.'); bad = true; }
    if (!t.value) { fieldError(t, 'Choose a pass product.'); bad = true; }
    if (!d.value) { fieldError(d, 'Set a start date.'); bad = true; }
    if (bad) { scrim.querySelector('[aria-invalid="true"]')?.focus(); return; }

    const btn = scrim.querySelector('[data-action="1"]');
    await submitting(btn, async () => {
      try {
        await api.buyPass({
          customer_id: Number(c.value), vehicle_id: Number(v.value),
          pass_type_id: Number(t.value), facility_id: Number(f.value),
          valid_from: new Date(d.value + 'T00:00:00').toISOString(),
        });
        toast('Pass sold', 'It covers every stay inside its window.', 'success');
        close(); onDone();
      } catch (err) { fieldError(t, err.rule ? `${err.message} (${err.rule})` : err.message); }
    });
  }
}
