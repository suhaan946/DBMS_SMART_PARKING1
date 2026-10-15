/* gate.js — the operator console. Entry on the left, exit on the right.
   Both sides are thin: fn_gate_entry and fn_gate_exit do the work in one
   transaction each, so this file never computes a charge or picks a slot. */
import { api, ApiError, auth } from './api.js';
import {
  mountShell, icon, esc, money, duration, dateTime, timeOnly,
  errorState, facility, toast, fieldError, clearErrors, submitting, modal, dataTable, skeleton,
} from './ui.js';
import { enter, revealList, flashBay, bindInteractive } from './motion.js';

const ctx = mountShell('gate.html', {
  title: 'Gate',
  subtitle: 'Record arrivals and departures',
});
if (ctx) init(ctx);

async function init({ content, user }) {
  if (!auth.isStaff) {
    errorState(content, new ApiError('The gate console is for staff accounts only.', 403));
    return;
  }

  content.innerHTML = `
    <div class="toolbar">
      <label class="sr-only" for="facility">Facility</label>
      <select class="select" id="facility" style="max-width:260px"></select>
    </div>

    <div class="dash-grid gate-grid">
      <section class="card" id="entry-card">
        <div class="card-head"><h2>Arrival</h2>
          <span class="hint">The next free bay is chosen and locked automatically</span></div>
        <form id="entry-form" novalidate>
          <div class="field">
            <label for="plate">Registration number</label>
            <input class="input reg" id="plate" name="plate" autocomplete="off"
                   placeholder="TS09AB1234" spellcheck="false" required
                   aria-describedby="plate-hint">
            <div class="help" id="plate-hint">Letters and digits only, no spaces.</div>
            <div class="field-error" id="plate-error"></div>
          </div>
          <button class="btn btn-primary btn-lg btn-block" type="submit" id="entry-submit"
                  data-interactive>${icon('gate')} Record arrival</button>
        </form>
        <div id="entry-result" style="margin-top:var(--s5)"></div>
      </section>

      <section class="card" id="exit-card">
        <div class="card-head"><h2>Departure</h2>
          <span class="hint">Look up by ticket number or registration</span></div>
        <form id="exit-form" novalidate>
          <div class="field">
            <label for="lookup">Ticket or registration</label>
            <input class="input reg" id="lookup" name="lookup" autocomplete="off"
                   placeholder="TK-A1B2C3D4 or TS09AB1234" spellcheck="false" required>
            <div class="field-error" id="lookup-error"></div>
          </div>
          <button class="btn btn-lg btn-block" type="submit" id="lookup-submit"
                  data-interactive>${icon('search')} Look up vehicle</button>
        </form>
        <div id="exit-result" style="margin-top:var(--s5)"></div>
      </section>
    </div>

    <section class="card" style="margin-top:var(--s5)">
      <div class="card-head"><h2>Today at this gate</h2>
        <div class="spacer"></div>
        <button class="btn btn-sm" id="refresh-activity" data-interactive>
          ${icon('refresh')} Refresh</button></div>
      <div id="activity"></div>
    </section>`;

  const selF = content.querySelector('#facility');
  let activityTable = null;
  let facilities;
  try { facilities = await api.facilities(); }
  catch (err) { errorState(content, err, () => location.reload()); return; }

  const scoped = user.facility_id
    ? facilities.filter((f) => f.facility_id === user.facility_id) : facilities;
  selF.innerHTML = scoped.map((f) =>
    `<option value="${f.facility_id}">${esc(f.name)} — ${esc(f.city)}</option>`).join('');
  if (scoped.length === 1) selF.disabled = true;
  const remembered = facility.get();
  if (remembered && scoped.some((f) => f.facility_id === remembered)) selF.value = String(remembered);
  selF.addEventListener('change', () => { facility.set(Number(selF.value)); loadActivity(); });

  enter(content.querySelector('#entry-card'));
  enter(content.querySelector('#exit-card'), { delay: 0.06 });

  setupEntry(content, selF);
  setupExit(content, selF);
  loadActivity();
  content.querySelector('#refresh-activity').addEventListener('click', loadActivity);

  async function loadActivity() {
    const host = content.querySelector('#activity');
    if (!activityTable) skeleton(host, { rows: 4 });
    let rows;
    try { rows = await api.sessions({ facility_id: Number(selF.value), limit: 12 }); }
    catch (err) { activityTable = null; errorState(host, err, loadActivity); return; }
    if (activityTable) { activityTable.setRows(rows); return; }
    activityTable = dataTable(host, {
      caption: 'Recent gate events',
      rows,
      pageSize: 12,
      searchPlaceholder: 'Search registration, ticket or bay',
      emptyTitle: 'No sessions yet',
      emptyBody: 'Record a gate entry above to begin the log.',
      columns: [
        { key: 'entry_time', label: 'Arrived',
          render: (r) => `<span class="mono nowrap">${esc(timeOnly(r.entry_time))}</span>` },
        { key: 'plate_number', label: 'Vehicle', render: (r) => `<span class="plate-chip">${esc(r.plate_number)}</span>` },
        { key: 'ticket_no', label: 'Ticket', csvOnly: true },
        { key: 'slot_code', label: 'Bay', render: (r) => `<span class="mono nowrap">${esc(r.slot_code)}</span>` },
        { key: 'duration_minutes', label: 'Stay', num: true,
          render: (r) => `<span class="mono nowrap">${esc(duration(r.duration_minutes))}</span>` },
        { key: 'is_active', label: 'State', value: (r) => (r.is_active ? 'In lot' : 'Departed'),
          render: (r) => `<span class="badge ${r.is_active ? 'badge-occupied' : 'badge-paid'}">${
            r.is_active ? 'In lot' : 'Departed'}</span>` },
        { key: 'total_amount', label: 'Charge', num: true,
          render: (r) => r.total_amount != null ? `<span class="money nowrap">${esc(money(r.total_amount))}</span>`
            : '<span class="muted">—</span>' },
      ],
    });
  }

  // Exposed so the entry and exit handlers can refresh the log after a change.
  content._reloadActivity = loadActivity;
}

const PLATE_RE = /^[A-Z]{2}[0-9]{1,2}[A-Z]{1,3}[0-9]{4}$/;

function setupEntry(content, selF) {
  const form = content.querySelector('#entry-form');
  const plate = content.querySelector('#plate');
  const submit = content.querySelector('#entry-submit');
  const result = content.querySelector('#entry-result');

  plate.addEventListener('input', () => {
    plate.value = plate.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (plate.closest('.field').dataset.invalid === 'true') fieldError(plate, '');
  });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    clearErrors(form);
    const v = plate.value.trim();
    if (!v) { fieldError(plate, 'Enter the registration number.'); plate.focus(); return; }
    if (!PLATE_RE.test(v)) {
      fieldError(plate, 'Use the Indian format, for example TS09AB1234.');
      plate.focus(); return;
    }

    await submitting(submit, async () => {
      try {
        const r = await api.gateEntry(v, Number(selF.value));
        result.innerHTML = `
          <div class="ticket">
            <div style="font-size:var(--t-xs);text-transform:uppercase;
                        letter-spacing:0.07em;color:var(--ink-2)">Bay assigned</div>
            <div class="ticket-slot">${esc(r.slot_code)}</div>
            <div class="ticket-no">${esc(r.ticket_no)}</div>
            <dl class="dl" style="margin-top:var(--s4);text-align:left">
              <dt>Vehicle</dt><dd class="mono">${esc(r.plate_number || v)}</dd>
              <dt>Customer</dt><dd>${esc(r.customer_name || '—')}</dd>
              <dt>Type</dt><dd>${esc(r.vehicle_type_name || '—')}</dd>
              <dt>Entered</dt><dd class="mono">${esc(dateTime(r.entry_time))}</dd>
              ${r.pass_id ? '<dt>Pass</dt><dd><span class="badge badge-active">Covered by pass</span></dd>' : ''}
            </dl>
          </div>`;
        flashBay(result.querySelector('.ticket'));
        enter(result.querySelector('.ticket'));
        toast('Arrival recorded', `${v} is in bay ${r.slot_code}.`, 'success');
        plate.value = ''; plate.focus();
        content._reloadActivity?.();
      } catch (err) {
        // The message is the database's own, mapped in api/errors.py.
        fieldError(plate, err.message);
        result.innerHTML = '';
        plate.focus();
      }
    });
  });
}

function setupExit(content, selF) {
  const form = content.querySelector('#exit-form');
  const input = content.querySelector('#lookup');
  const submit = content.querySelector('#lookup-submit');
  const result = content.querySelector('#exit-result');
  let ticking = null;

  input.addEventListener('input', () => {
    input.value = input.value.toUpperCase();
    if (input.closest('.field').dataset.invalid === 'true') fieldError(input, '');
  });

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    clearErrors(form);
    const q = input.value.trim();
    if (!q) { fieldError(input, 'Enter a ticket number or registration.'); input.focus(); return; }

    await submitting(submit, async () => {
      try {
        const s = await api.gateLookup(q);
        showExitPanel(s);
      } catch (err) {
        fieldError(input, err.message);
        result.innerHTML = '';
      }
    });
  });

  function showExitPanel(s) {
    clearInterval(ticking);
    const taxRate = Number(s.tax_rate_pct) || 0;
    result.innerHTML = `
      <div class="card" style="background:var(--surface-2);border-style:dashed">
        <dl class="dl">
          <dt>Vehicle</dt><dd class="reg">${esc(s.plate_number)}</dd>
          <dt>Customer</dt><dd>${esc(s.customer_name)}</dd>
          <dt>Bay</dt><dd class="mono">${esc(s.slot_code)}</dd>
          <dt>Ticket</dt><dd class="mono">${esc(s.ticket_no)}</dd>
          <dt>Entered</dt><dd class="mono">${esc(dateTime(s.entry_time))}</dd>
          <dt>Elapsed</dt><dd class="mono clock" id="elapsed">${esc(duration(s.minutes_so_far))}</dd>
        </dl>
        <hr style="border:0;border-top:1px solid var(--rule);margin:var(--s4) 0">
        ${s.pass_id ? `
          <p style="font-size:var(--t-sm)">
            <span class="badge badge-active">Covered by pass</span>
            This stay is included in the customer’s pass, so no charge applies.</p>` : ''}
        <dl class="dl">
          <dt>Parking charge</dt><dd class="money" id="base">${esc(money(s.running_charge))}</dd>
          <dt>Tax at ${taxRate}%</dt>
          <dd class="money" id="tax">${esc(money(s.running_charge * taxRate / 100))}</dd>
          <dt style="font-weight:600;color:var(--ink)">Total due</dt>
          <dd class="money" id="total" style="font-weight:600;font-size:var(--t-md)">${
            esc(money(s.running_charge * (1 + taxRate / 100)))}</dd>
        </dl>
        <p style="font-size:var(--t-xs);color:var(--ink-2);margin-top:var(--s3)">
          Computed by the database from the tariff in force when the vehicle
          arrived. The figure confirmed on exit is the figure billed.</p>
        <button class="btn btn-primary btn-block btn-lg" id="confirm-exit"
                style="margin-top:var(--s4)" data-interactive>
          ${icon('check')} Confirm departure</button>
      </div>`;
    enter(result.firstElementChild);
    bindInteractive(result);

    // The live clock re-reads from the server rather than extrapolating, so
    // what the operator quotes is always what fn_calculate_charge will bill.
    ticking = setInterval(async () => {
      try {
        const f = await api.gateLookup(s.ticket_no);
        const t = Number(f.tax_rate_pct) || 0;
        result.querySelector('#elapsed').textContent = duration(f.minutes_so_far);
        result.querySelector('#base').textContent = money(f.running_charge);
        result.querySelector('#tax').textContent = money(f.running_charge * t / 100);
        result.querySelector('#total').textContent = money(f.running_charge * (1 + t / 100));
      } catch { clearInterval(ticking); }
    }, 20000);

    result.querySelector('#confirm-exit').addEventListener('click', async (ev) => {
      const btn = ev.currentTarget;
      await submitting(btn, async () => {
        try {
          const r = await api.gateExit(s.ticket_no);
          clearInterval(ticking);
          showBill(r, s);
          input.value = ''; input.focus();
          content._reloadActivity?.();
        } catch (err) {
          toast('Could not record the departure', err.message, 'error');
        }
      });
    });
  }

  function showBill(r, s) {
    result.innerHTML = '';
    // A zero bill is marked paid by the database (trg_bill_enforce_amounts),
    // so there is nothing to collect and no payment step to offer.
    const free = Number(r.total_amount) === 0;
    modal({
      title: 'Departure recorded',
      body: `
        <p style="color:var(--ink-2);font-size:var(--t-sm);margin-bottom:var(--s4)">
          Bay <strong class="mono">${esc(r.slot_code)}</strong> is free again.
          Bill <strong class="mono">#${r.bill_id}</strong> has been raised${free
            ? ' and is already settled: the stay was inside the free period or covered by a pass' : ''}.</p>
        <dl class="dl">
          <dt>Vehicle</dt><dd class="reg">${esc(s.plate_number)}</dd>
          <dt>Duration</dt><dd class="mono">${esc(duration(r.billable_minutes))}</dd>
          <dt>Parking charge</dt><dd class="money">${esc(money(r.base_amount))}</dd>
          <dt>Tax</dt><dd class="money">${esc(money(r.tax_amount))}</dd>
          <dt style="font-weight:600;color:var(--ink)">Total</dt>
          <dd class="money" style="font-weight:600">${esc(money(r.total_amount))}</dd>
        </dl>`,
      actions: free
        ? [{ label: 'Done', variant: 'primary', onClick: (c) => c() }]
        : [
            { label: 'Done', onClick: (c) => c() },
            { label: 'Record payment', variant: 'primary',
              onClick: (c) => { c(); location.href = `billing.html?bill=${r.bill_id}`; } },
          ],
    });
    toast('Departure recorded', `Bill #${r.bill_id} for ${money(r.total_amount)}.`, 'success');
  }
}
