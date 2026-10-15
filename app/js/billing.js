/* billing.js — bills raised, and the ledger of payments recorded against them.
   Payments are RECORDED, not processed. No gateway, and no field anywhere in
   this file collects a card number, CVV or UPI credential. */
import { api, auth } from './api.js';
import {
  mountShell, icon, esc, money, moneyShort, duration, dateTime, titleCase,
  errorState, modal, toast, errorToast, fieldError, clearErrors, submitting,
  dataTable, skeleton, tabs, methodLabel,
} from './ui.js';
import { enter, revealList, countTo } from './motion.js';
import { stackBar } from './charts.js';

const STATUSES = [['all', 'All'], ['unpaid', 'Unpaid'], ['partly_paid', 'Part-paid'],
                  ['paid', 'Paid'], ['waived', 'Waived']];
const METHODS = ['cash', 'card', 'upi', 'netbanking', 'wallet', 'pass'];
const METHOD_COLOR = { cash: 'var(--accent)', upi: 'var(--warn)', card: 'var(--graphite)',
                       netbanking: 'var(--info)', wallet: 'var(--violet)', pass: 'var(--state-off)' };

const ctx = mountShell('billing.html', {
  title: 'Billing',
  subtitle: 'Bills raised at the gate, and the money recorded against them',
});
if (ctx) init(ctx);

async function init({ content }) {
  content.innerHTML = `
    <div id="stats" class="stat-row" aria-live="polite"></div>
    <div id="billing-tabs"></div>
    <section id="panel-bills" class="panel tabpanel" role="tabpanel">
      <div class="panel-head">
        <div class="seg" role="group" aria-label="Bill status" id="status-seg">
          ${STATUSES.map(([v, l], i) => `<button type="button" data-status="${v}"
              aria-pressed="${i === 0}">${l}</button>`).join('')}
        </div>
      </div>
      <div id="bills-table"></div>
    </section>
    <section id="panel-ledger" class="panel tabpanel" role="tabpanel" hidden>
      <div class="panel-head">
        <label class="sr-only" for="ledger-days">Period</label>
        <select class="select" id="ledger-days" style="max-width:170px">
          <option value="1">Today</option><option value="7" selected>Last 7 days</option>
          <option value="30">Last 30 days</option><option value="90">Last 90 days</option>
        </select>
        <label class="sr-only" for="ledger-method">Method</label>
        <select class="select" id="ledger-method" style="max-width:170px">
          <option value="all">All methods</option>
          ${METHODS.map((m) => `<option value="${m}">${methodLabel(m)}</option>`).join('')}
        </select>
        <span class="spacer"></span>
        <span class="hint">Every receipt, newest first. Operators see their own facility.</span>
      </div>
      <div class="ledger-mix" id="ledger-mix"></div>
      <div id="ledger-table"></div>
    </section>`;

  tabs(content.querySelector('#billing-tabs'), [
    { id: 'bills', label: 'Bills', icon: 'receipt', panel: 'panel-bills' },
    ...(auth.isStaff ? [{ id: 'ledger', label: 'Payments ledger', icon: 'history', panel: 'panel-ledger' }] : []),
  ], { label: 'Billing views', onChange: (id) => { if (id === 'ledger') loadLedger(); } });

  let status = 'all';
  let billsTable = null, ledgerTable = null, ledgerLoaded = false;

  content.querySelector('#status-seg').addEventListener('click', (e) => {
    const b = e.target.closest('[data-status]');
    if (!b) return;
    status = b.dataset.status;
    content.querySelectorAll('#status-seg button').forEach((x) =>
      x.setAttribute('aria-pressed', String(x === b)));
    loadBills();
  });
  content.querySelector('#ledger-days').addEventListener('change', loadLedger);
  content.querySelector('#ledger-method').addEventListener('change', loadLedger);

  enter(content.querySelector('#panel-bills'));
  loadBills();

  // Deep link from the gate: billing.html?bill=123 opens that bill directly.
  const wanted = new URLSearchParams(location.search).get('bill');
  if (wanted) { openBill(Number(wanted), loadBills); history.replaceState({}, '', 'billing.html'); }

  async function loadBills() {
    const host = content.querySelector('#bills-table');
    if (!billsTable) skeleton(host, { rows: 6 });
    let data;
    const q = host.querySelector('.dt-search input')?.value.trim() || '';
    try { data = await api.bills(status, q); }
    catch (err) { billsTable = null; errorState(host, err, loadBills); return; }
    renderStats(data.summary || {});

    if (billsTable) { billsTable.setRows(data.bills); return; }
    billsTable = dataTable(host, {
      caption: 'Bills',
      rows: data.bills,
      searchPlaceholder: 'Search registration, customer or bill',
      csv: 'smartpark-bills.csv',
      note: 'Latest 200 bills',
      onSearch: async (q) => (await api.bills(status, q)).bills,
      emptyTitle: 'No bills here',
      emptyBody: 'A bill is raised automatically when a vehicle exits the gate.',
      columns: [
        { key: 'bill_id', label: 'Bill', render: (b) => `<span class="mono">#${b.bill_id}</span>` },
        { key: 'plate_number', label: 'Vehicle',
          render: (b) => `<span class="plate-chip">${esc(b.plate_number)}</span>
            <div class="cell-sub">${esc(b.customer_name)}</div>` },
        { key: 'customer_name', label: 'Customer', csvOnly: true },
        { key: 'slot_code', label: 'Bay', render: (b) => `<span class="mono nowrap">${esc(b.slot_code)}</span>` },
        { key: 'generated_at', label: 'Raised',
          render: (b) => `<span class="mono nowrap">${esc(dateTime(b.generated_at))}</span>` },
        { key: 'billable_minutes', label: 'Stay',
          render: (b) => `<span class="mono nowrap">${esc(duration(b.billable_minutes))}</span>` },
        { key: 'total_amount', label: 'Total', num: true,
          render: (b) => `<span class="money nowrap">${esc(money(b.total_amount))}</span>` },
        { key: 'amount_due', label: 'Due', num: true,
          render: (b) => Number(b.amount_due) > 0.005
            ? `<span class="money nowrap due">${esc(money(b.amount_due))}</span>`
            : '<span class="muted">—</span>' },
        { key: 'status', label: 'Status',
          render: (b) => `<span class="badge badge-${esc(b.status)}">${esc(titleCase(b.status))}</span>` },
      ],
      onRowClick: (b) => openBill(b.bill_id, loadBills),
      rowActions: (b) => [
        { label: 'View invoice', icon: 'receipt', onClick: () => openBill(b.bill_id, loadBills) },
        ...(auth.isStaff && Number(b.amount_due) > 0.005
          ? [{ label: 'Record payment', icon: 'plus',
               onClick: () => recordPayment(b, () => { loadBills(); ledgerLoaded && loadLedger(); }) }]
          : []),
      ],
    });
  }

  function renderStats(s) {
    const amt = (k) => Number(s[k]?.amount || 0);
    const cnt = (k) => Number(s[k]?.count || 0);
    const host = content.querySelector('#stats');
    host.innerHTML = `
      <div class="stat stat-accent"><div class="stat-label">${icon('check')} Settled</div>
        <div class="stat-value" data-count="${amt('paid')}" data-money="1">₹0</div>
        <div class="stat-foot">${cnt('paid').toLocaleString('en-IN')} bills paid in full</div></div>
      <div class="stat stat-alert"><div class="stat-label">${icon('alert')} Outstanding</div>
        <div class="stat-value" data-count="${amt('unpaid') + amt('partly_paid')}" data-money="1">₹0</div>
        <div class="stat-foot">${cnt('unpaid')} unpaid · ${cnt('partly_paid')} part-paid</div></div>
      <div class="stat"><div class="stat-label">${icon('receipt')} Bills raised</div>
        <div class="stat-value" data-count="${cnt('paid') + cnt('unpaid') + cnt('partly_paid') + cnt('waived')}">0</div>
        <div class="stat-foot">all time${cnt('waived') ? ` · ${cnt('waived')} waived` : ''}</div></div>`;
    if (!host.dataset.shown) { revealList(host.querySelectorAll('.stat')); host.dataset.shown = '1'; }
    host.querySelectorAll('[data-count]').forEach((el) => countTo(el, Number(el.dataset.count),
      { format: el.dataset.money ? moneyShort : (v) => Math.round(v).toLocaleString('en-IN') }));
  }

  async function loadLedger() {
    ledgerLoaded = true;
    const host = content.querySelector('#ledger-table');
    const mix = content.querySelector('#ledger-mix');
    if (!ledgerTable) skeleton(host, { rows: 6 });
    let data;
    try {
      data = await api.payments({
        days: content.querySelector('#ledger-days').value,
        method: content.querySelector('#ledger-method').value, limit: 1000,
      });
    } catch (err) { ledgerTable = null; mix.innerHTML = ''; errorState(host, err, loadLedger); return; }

    const total = data.by_method.reduce((a, m) => a + Number(m.amount), 0);
    mix.innerHTML = data.by_method.length ? `
      <div class="mix-total"><span class="label">Collected</span>
        <span class="mix-amount">${esc(money(total))}</span>
        <span class="muted">${data.payments.length.toLocaleString('en-IN')} receipts</span></div>
      <div class="mix-bar" id="mix-bar"></div>
      <ul class="mix-legend">${data.by_method.map((m) => `<li>
        <i style="background:${METHOD_COLOR[m.method] || 'var(--state-off)'}"></i>
        ${esc(methodLabel(m.method))} <span class="mono">${esc(moneyShort(m.amount))}</span>
        <span class="muted">· ${m.n}</span></li>`).join('')}</ul>` : '';
    if (data.by_method.length) {
      stackBar(mix.querySelector('#mix-bar'), data.by_method.map((m) => ({
        label: methodLabel(m.method), value: Number(m.amount), color: METHOD_COLOR[m.method],
      })), { accessibleName: 'Collections by payment method' });
    }

    if (ledgerTable) { ledgerTable.setRows(data.payments); return; }
    ledgerTable = dataTable(host, {
      caption: 'Payments ledger',
      rows: data.payments,
      searchPlaceholder: 'Search registration, customer or reference',
      csv: 'smartpark-payments.csv',
      emptyTitle: 'No payments in this period',
      emptyBody: 'Try a longer period, or another payment method.',
      columns: [
        { key: 'paid_at', label: 'Received',
          render: (p) => `<span class="mono nowrap">${esc(dateTime(p.paid_at))}</span>` },
        { key: 'payment_id', label: 'Receipt', render: (p) => `<span class="mono">R-${p.payment_id}</span>` },
        { key: 'bill_id', label: 'Bill', render: (p) => `<span class="mono">#${p.bill_id}</span>` },
        { key: 'plate_number', label: 'Vehicle',
          render: (p) => `<span class="plate-chip">${esc(p.plate_number)}</span>
            <div class="cell-sub">${esc(p.customer_name)}</div>` },
        { key: 'customer_name', label: 'Customer', csvOnly: true },
        { key: 'method', label: 'Method', value: (p) => methodLabel(p.method), render: (p) => esc(methodLabel(p.method)) },
        { key: 'reference_no', label: 'Reference',
          render: (p) => p.reference_no ? `<span class="mono">${esc(p.reference_no)}</span>` : '<span class="muted">—</span>' },
        { key: 'received_by_name', label: 'Recorded by',
          render: (p) => p.received_by_name ? esc(p.received_by_name) : '<span class="muted">—</span>' },
        { key: 'amount', label: 'Amount', num: true,
          render: (p) => `<span class="money nowrap">${esc(money(p.amount))}</span>` },
      ],
      onRowClick: (p) => openBill(p.bill_id, loadBills),
    });
  }
}

async function openBill(id, onChange) {
  let b;
  try { b = await api.bill(id); }
  catch (err) { errorToast('Could not open that bill', err); return; }

  const paid = (b.payments || []).reduce((a, p) => a + Number(p.amount), 0);
  const due = Number(b.total_amount) - paid;

  modal({
    title: `Invoice #${b.bill_id}`,
    width: '600px',
    body: `
      <div class="invoice">
        <div class="invoice-head">
          <div>
            <div class="invoice-facility">${esc(b.facility_name)}</div>
            <div class="muted small">${esc(b.address_line)}, ${esc(b.city)}</div>
          </div>
          <span class="badge badge-${esc(b.status)}">${esc(titleCase(b.status))}</span>
        </div>
        <dl class="dl">
          <dt>Customer</dt><dd>${esc(b.customer_name)}</dd>
          <dt>Vehicle</dt><dd class="reg">${esc(b.plate_number)} · ${esc(b.vehicle_type_name)}</dd>
          <dt>Ticket</dt><dd class="mono">${esc(b.ticket_no)}</dd>
          <dt>Bay</dt><dd class="mono">${esc(b.slot_code)}</dd>
          <dt>Entered</dt><dd class="mono">${esc(dateTime(b.entry_time))}</dd>
          <dt>Exited</dt><dd class="mono">${esc(dateTime(b.exit_time))}</dd>
          <dt>Duration</dt><dd class="mono">${esc(duration(b.billable_minutes))}</dd>
        </dl>
        <hr class="rule-gap tight">
        <p class="muted small invoice-tariff">
          Tariff: ${esc(b.tariff_name)} — ${money(b.first_hour_rate)} first hour,
          ${money(b.subsequent_hour_rate)} thereafter, capped at ${money(b.daily_cap)} a day,
          first ${b.free_minutes} minutes free.</p>
        <dl class="dl">
          <dt>Parking charge</dt><dd class="money">${esc(money(b.base_amount))}</dd>
          <dt>Tax at ${esc(b.tax_rate_pct)}%</dt><dd class="money">${esc(money(b.tax_amount))}</dd>
          <dt class="strong">Total</dt><dd class="money strong big">${esc(money(b.total_amount))}</dd>
        </dl>
        ${(b.payments || []).length ? `
          <hr class="rule-gap tight">
          <div class="invoice-sub">Payments recorded</div>
          <dl class="dl">${b.payments.map((p) => `
            <dt>${esc(dateTime(p.paid_at))} · ${esc(methodLabel(p.method))}${
              p.reference_no ? ` · <span class="mono">${esc(p.reference_no)}</span>` : ''}</dt>
            <dd class="money">${esc(money(p.amount))}</dd>`).join('')}
            ${due > 0.005 ? `<dt class="strong due">Still due</dt>
              <dd class="money strong due">${esc(money(due))}</dd>` : ''}
          </dl>` : `<p class="muted small" style="margin-top:var(--s4)">No payment recorded against this bill yet.</p>`}
      </div>`,
    actions: [
      { label: 'Close', onClick: (c) => c() },
      { label: 'Print', onClick: () => window.print() },
      ...(auth.isStaff && due > 0.005 && b.status !== 'waived'
        ? [{ label: 'Record payment', variant: 'primary',
             onClick: (c) => { c(); recordPayment({ bill_id: b.bill_id, amount_due: due }, onChange); } }]
        : []),
    ],
  });
}

function recordPayment(bill, onDone) {
  const due = Number(bill.amount_due);
  modal({
    title: `Record payment for bill #${bill.bill_id}`,
    body: `
      <p class="muted small" style="margin-bottom:var(--s4)">
        This records a receipt that has already been taken. No card, CVV or UPI
        credential is collected or stored anywhere in this system.</p>
      <form id="pay-form" novalidate>
        <div class="form-row">
          <div class="field">
            <label for="pay-amount">Amount received <span class="req" aria-hidden="true">*</span></label>
            <input class="input mono" type="number" id="pay-amount" step="0.01" min="0.01"
                   max="${due.toFixed(2)}" value="${due.toFixed(2)}" required inputmode="decimal">
            <div class="help">Outstanding on this bill: ${money(due)}</div>
            <div class="field-error"></div>
          </div>
          <div class="field">
            <label for="pay-method">Method <span class="req" aria-hidden="true">*</span></label>
            <select class="select" id="pay-method" required>
              ${METHODS.filter((m) => m !== 'pass').map((m) =>
                `<option value="${m}">${methodLabel(m)}</option>`).join('')}
            </select><div class="field-error"></div>
          </div>
        </div>
        <div class="field">
          <label for="pay-ref">Receipt or transaction reference <span class="optional">(optional)</span></label>
          <input class="input mono" id="pay-ref" autocomplete="off" maxlength="60"
                 placeholder="e.g. the reference printed on the terminal slip">
          <div class="field-error"></div>
        </div>
      </form>`,
    actions: [
      { label: 'Cancel', onClick: (c) => c() },
      { label: 'Record payment', variant: 'primary', onClick: submit },
    ],
    onMount(scrim) {
      scrim.querySelector('#pay-form').addEventListener('submit', (e) => {
        e.preventDefault(); scrim.querySelector('[data-action="1"]').click();
      });
    },
  });

  async function submit(close, scrim) {
    const form = scrim.querySelector('#pay-form');
    clearErrors(form);
    const amt = scrim.querySelector('#pay-amount');
    const val = Number(amt.value);
    if (!amt.value || Number.isNaN(val) || val <= 0) {
      fieldError(amt, 'Enter an amount greater than zero.'); amt.focus(); return;
    }
    if (val > due + 0.005) {
      fieldError(amt, `That is more than the ${money(due)} outstanding.`); amt.focus(); return;
    }
    await submitting(scrim.querySelector('[data-action="1"]'), async () => {
      try {
        const r = await api.pay({
          bill_id: bill.bill_id, amount: Math.round(val * 100) / 100,
          method: scrim.querySelector('#pay-method').value,
          reference_no: scrim.querySelector('#pay-ref').value.trim() || null,
        });
        toast('Payment recorded',
              `Bill #${bill.bill_id} is now ${titleCase(r.status).toLowerCase()}.`, 'success');
        close(); onDone?.();
      } catch (err) { fieldError(amt, err.message); }
    });
  }
}
