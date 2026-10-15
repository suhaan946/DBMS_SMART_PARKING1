/* reservations.js — bookings, with the expiry sweep run server-side on read. */
import { api, auth } from './api.js';
import {
  mountShell, icon, esc, dateTime, titleCase, skeleton, errorState, dataTable,
  modal, toast, errorToast, fieldError, clearErrors, submitting, confirmDialog,
} from './ui.js';
import { enter } from './motion.js';

const FILTERS = [
  ['live', 'Live', (r) => r.status === 'held' || r.status === 'confirmed'],
  ['fulfilled', 'Fulfilled', (r) => r.status === 'fulfilled'],
  ['expired', 'Expired', (r) => r.status === 'expired'],
  ['cancelled', 'Cancelled', (r) => r.status === 'cancelled'],
  ['all', 'All', () => true],
];

const ctx = mountShell('reservations.html', {
  title: 'Reservations',
  subtitle: 'Bays held for a vehicle over a booked window',
});
if (ctx) init(ctx);

async function init({ content }) {
  content.innerHTML = `
    <section class="panel" id="res-panel">
      <div class="panel-head">
        <div class="seg" role="group" aria-label="Reservation status" id="res-seg"></div>
        <span class="spacer"></span>
        <button class="btn btn-primary" id="new" data-interactive>${icon('plus')} New reservation</button>
      </div>
      <p class="rule-note">${icon('lock')}
        Two live holds can never overlap on one bay: the database refuses the second
        (<code>ex_reservation_no_overlap</code>). Lapsed holds expire automatically.</p>
      <div id="res-table"></div>
    </section>`;

  let rows = [], filter = 'live', table = null;
  const seg = content.querySelector('#res-seg');
  seg.addEventListener('click', (e) => {
    const b = e.target.closest('[data-filter]');
    if (!b) return;
    filter = b.dataset.filter;
    paint();
  });
  content.querySelector('#new').addEventListener('click', () => newReservation(load));
  enter(content.querySelector('#res-panel'));
  load();

  async function load() {
    const host = content.querySelector('#res-table');
    if (!table) skeleton(host, { rows: 5 });
    try { rows = await api.reservations('all'); }
    catch (err) { table = null; errorState(host, err, load); return; }
    paint();
  }

  function paint() {
    seg.innerHTML = FILTERS.map(([id, label, test]) => `<button type="button" data-filter="${id}"
        aria-pressed="${id === filter}">${label} <span class="seg-count">${rows.filter(test).length}</span></button>`).join('');
    const shown = rows.filter(FILTERS.find((f) => f[0] === filter)[2]);
    const host = content.querySelector('#res-table');
    if (table) { table.setRows(shown); return; }
    table = dataTable(host, {
      caption: 'Reservations',
      rows: shown,
      searchPlaceholder: 'Search customer, registration or bay',
      csv: 'smartpark-reservations.csv',
      sort: { key: 'reserved_from', dir: 'desc' },
      emptyTitle: 'No reservations here',
      emptyBody: 'Use New reservation to hold a bay for an arrival, or pick another status.',
      columns: [
        { key: 'customer_name', label: 'Customer',
          render: (r) => `<span class="cell-strong">${esc(r.customer_name)}</span>
            <div class="cell-sub mono">${esc(r.phone)}</div>` },
        { key: 'plate_number', label: 'Vehicle',
          render: (r) => `<span class="plate-chip">${esc(r.plate_number)}</span>
            <div class="cell-sub">${esc(r.vehicle_type_name)}</div>` },
        { key: 'slot_code', label: 'Bay',
          render: (r) => `<span class="mono nowrap">${esc(r.slot_code)}</span>
            <div class="cell-sub">${esc(r.floor_name)}</div>` },
        { key: 'reserved_from', label: 'From',
          render: (r) => `<span class="mono nowrap">${esc(dateTime(r.reserved_from))}</span>` },
        { key: 'reserved_until', label: 'Until',
          render: (r) => `<span class="mono nowrap">${esc(dateTime(r.reserved_until))}</span>` },
        { key: 'status', label: 'Status',
          render: (r) => `<span class="badge badge-${esc(r.status)}">${esc(titleCase(r.status))}</span>` },
      ],
      rowActions: (r) => {
        const live = r.status === 'held' || r.status === 'confirmed';
        if (!live) return [{ label: 'No actions for a closed booking', icon: 'info', disabled: true }];
        return [
          ...(r.status === 'held' && auth.isStaff
            ? [{ label: 'Confirm hold', icon: 'check', onClick: () => setStatus(r, 'confirmed') }] : []),
          { label: 'Cancel reservation', icon: 'close', danger: true, onClick: () => setStatus(r, 'cancelled') },
        ];
      },
    });
  }

  async function setStatus(r, status) {
    if (status === 'cancelled' && !await confirmDialog('Cancel this reservation?',
      `${r.plate_number}'s hold on bay ${r.slot_code} is released straight away and the bay becomes available to other drivers.`,
      'Cancel reservation')) return;
    try {
      await api.setReservation(r.reservation_id, status);
      toast(status === 'cancelled' ? 'Reservation cancelled' : 'Reservation confirmed',
            status === 'cancelled' ? `Bay ${r.slot_code} is free again.` : `Bay ${r.slot_code} stays held.`,
            'success');
      load();
    } catch (err) { errorToast('Could not update the reservation', err); }
  }
}

async function newReservation(onDone) {
  let customers = [], facilities = [];
  try {
    [customers, facilities] = await Promise.all([api.customers(), api.facilities()]);
  } catch (err) { errorToast('Could not open the form', err); return; }

  const local = (d) => new Date(d.getTime() - d.getTimezoneOffset() * 60000).toISOString().slice(0, 16);
  const start = new Date(Date.now() + 30 * 60000);
  const end   = new Date(Date.now() + 150 * 60000);

  modal({
    title: 'New reservation',
    width: '620px',
    body: `
      <form id="res-form" novalidate>
        <div class="field">
          <label for="r-customer">Customer <span class="req" aria-hidden="true">*</span></label>
          <select class="select" id="r-customer" required>
            ${customers.length === 1 ? '' : '<option value="">Choose a customer…</option>'}
            ${customers.map((c) => `<option value="${c.customer_id}">${esc(c.full_name)} — ${
              esc(c.phone)}</option>`).join('')}
          </select>
          <div class="field-error"></div>
        </div>
        <div class="field">
          <label for="r-vehicle">Vehicle <span class="req" aria-hidden="true">*</span></label>
          <select class="select" id="r-vehicle" required disabled>
            <option value="">Choose a customer first</option></select>
          <div class="field-error"></div>
        </div>
        <div class="form-row">
          <div class="field">
            <label for="r-from">From <span class="req" aria-hidden="true">*</span></label>
            <input class="input" type="datetime-local" id="r-from" value="${local(start)}"
                   min="${local(new Date())}" required>
            <div class="field-error"></div>
          </div>
          <div class="field">
            <label for="r-until">Until <span class="req" aria-hidden="true">*</span></label>
            <input class="input" type="datetime-local" id="r-until" value="${local(end)}" required>
            <div class="field-error"></div>
          </div>
        </div>
        <div class="field">
          <label for="r-slot">Bay <span class="req" aria-hidden="true">*</span></label>
          <select class="select" id="r-slot" required disabled>
            <option value="">Choose a vehicle first</option></select>
          <div class="help">Bays built for this vehicle's type and free now. A clash with
            another booking in your window is caught when you save.</div>
          <div class="field-error"></div>
        </div>
      </form>`,
    actions: [
      { label: 'Cancel', onClick: (c) => c() },
      { label: 'Create reservation', variant: 'primary', onClick: submit },
    ],
    onMount(scrim) {
      const cSel = scrim.querySelector('#r-customer');
      const vSel = scrim.querySelector('#r-vehicle');
      const sSel = scrim.querySelector('#r-slot');

      const loadVehicles = async () => {
        vSel.disabled = true; vSel.innerHTML = '<option value="">Loading…</option>';
        sSel.disabled = true; sSel.innerHTML = '<option value="">Choose a vehicle first</option>';
        if (!cSel.value) { vSel.innerHTML = '<option value="">Choose a customer first</option>'; return; }
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
      };
      cSel.addEventListener('change', loadVehicles);
      if (cSel.value) loadVehicles();

      vSel.addEventListener('change', async () => {
        sSel.disabled = true; sSel.innerHTML = '<option value="">Loading bays…</option>';
        const typeId = vSel.selectedOptions[0]?.dataset.type;
        if (!typeId) return;
        try {
          const perFacility = await Promise.all(facilities.map((f) =>
            api.freeSlots(f.facility_id, { vehicle_type_id: typeId })));
          const groups = facilities.map((f, i) => [f, perFacility[i]]).filter(([, s]) => s.length);
          if (!groups.length) {
            sSel.innerHTML = '<option value="">No free bays for this vehicle type</option>';
            return;
          }
          sSel.innerHTML = '<option value="">Choose a bay…</option>' + groups.map(([f, slots]) =>
            `<optgroup label="${esc(f.name)}">${slots.map((s) =>
              `<option value="${s.slot_id}">${esc(s.slot_code)} — ${esc(s.floor_name)}, Zone ${
                esc(s.zone_code)}</option>`).join('')}</optgroup>`).join('');
          sSel.disabled = false;
        } catch (err) { sSel.innerHTML = `<option value="">${esc(err.message)}</option>`; }
      });
    },
  });

  async function submit(close, scrim) {
    const form = scrim.querySelector('#res-form');
    clearErrors(form);
    const c = scrim.querySelector('#r-customer'), v = scrim.querySelector('#r-vehicle');
    const f = scrim.querySelector('#r-from'), u = scrim.querySelector('#r-until');
    const s = scrim.querySelector('#r-slot');

    let bad = false;
    if (!c.value) { fieldError(c, 'Choose a customer.'); bad = true; }
    if (!v.value) { fieldError(v, 'Choose a vehicle.'); bad = true; }
    if (!s.value) { fieldError(s, 'Choose a bay.'); bad = true; }
    if (!f.value) { fieldError(f, 'Set a start time.'); bad = true; }
    else if (new Date(f.value) < new Date(Date.now() - 60000)) {
      fieldError(f, 'The start time has already passed.'); bad = true;
    }
    if (!u.value) { fieldError(u, 'Set an end time.'); bad = true; }
    if (f.value && u.value && new Date(u.value) <= new Date(f.value)) {
      fieldError(u, 'The end time must be after the start time.'); bad = true;
    }
    if (bad) { scrim.querySelector('[aria-invalid="true"]')?.focus(); return; }

    await submitting(scrim.querySelector('[data-action="1"]'), async () => {
      try {
        await api.createReservation({
          customer_id: Number(c.value), vehicle_id: Number(v.value), slot_id: Number(s.value),
          reserved_from: new Date(f.value).toISOString(),
          reserved_until: new Date(u.value).toISOString(),
        });
        toast('Reservation created', `${v.selectedOptions[0].textContent.split(' — ')[0]} has bay ${
          s.selectedOptions[0].textContent.split(' — ')[0]} for that window.`, 'success');
        close(); onDone();
      } catch (err) {
        fieldError(s, err.rule ? `${err.message} (${err.rule})` : err.message);
      }
    });
  }
}
