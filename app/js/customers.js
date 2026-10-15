/* customers.js — customer and vehicle records. */
import { api, auth } from './api.js';
import {
  mountShell, icon, esc, dateOnly, errorState, modal, toast, errorToast,
  fieldError, clearErrors, submitting, confirmDialog, dataTable, skeleton, openMenu,
} from './ui.js';
import { enter } from './motion.js';

const ctx = mountShell('customers.html', {
  title: 'Customers',
  subtitle: 'People and the vehicles they park',
});
if (ctx) init(ctx);

const isAdmin = () => auth.user?.role === 'admin';

async function init({ content }) {
  content.innerHTML = `
    <section class="panel" id="customers-panel">
      <div class="panel-head">
        <h2>Customer register</h2>
        <span class="hint">Search, sort, export, or open a customer's vehicles.</span>
        <span class="spacer"></span>
        ${auth.isStaff ? `<button class="btn btn-primary" id="new-customer" data-interactive>
          ${icon('plus')} Add customer</button>` : ''}
      </div>
      <div id="table"></div>
    </section>`;
  enter(content.querySelector('#customers-panel'));
  content.querySelector('#new-customer')?.addEventListener('click', () => customerForm(null, load));

  const host = content.querySelector('#table');
  let table = null;
  load();

  async function load() {
    if (!table) skeleton(host, { rows: 6 });
    let rows;
    try { rows = await api.customers(); }
    catch (err) { table = null; errorState(host, err, load); return; }

    if (table) { table.setRows(rows); return; }
    table = dataTable(host, {
      caption: 'Customers',
      rows,
      searchPlaceholder: 'Search name, phone or email',
      csv: 'smartpark-customers.csv',
      sort: { key: 'full_name' },
      emptyTitle: 'No customers on file',
      emptyBody: 'Add the first customer to start recording vehicles.',
      columns: [
        { key: 'full_name', label: 'Name',
          render: (c) => `<span class="cell-strong">${esc(c.full_name)}</span>` },
        { key: 'phone', label: 'Phone', render: (c) => `<span class="mono">${esc(c.phone)}</span>` },
        { key: 'email', label: 'Email', render: (c) => c.email ? esc(c.email)
            : '<span class="muted">—</span>' },
        { key: 'vehicle_count', label: 'Vehicles', num: true,
          render: (c) => `<span class="mono">${c.vehicle_count}</span>` },
        { key: 'created_at', label: 'Customer since',
          render: (c) => `<span class="mono">${esc(dateOnly(c.created_at))}</span>` },
      ],
      onRowClick: (c) => showVehicles(c, load),
      rowActions: (c) => [
        { label: 'Vehicles', icon: 'car', onClick: () => showVehicles(c, load) },
        ...(auth.isStaff ? [{ label: 'Edit details', icon: 'edit',
                               onClick: () => customerForm(c, load) }] : []),
        ...(isAdmin() ? [{ label: 'Delete customer', icon: 'trash', danger: true,
                           disabled: c.vehicle_count > 0,
                           onClick: () => removeCustomer(c, load) }] : []),
      ],
    });
  }
}

/* One form for both "add" and "edit". `existing` is null when adding. */
function customerForm(existing, onDone) {
  const editing = !!existing;
  modal({
    title: editing ? `Edit ${existing.full_name}` : 'Add a customer',
    body: `
      <form id="cust-form" novalidate>
        <div class="field">
          <label for="c-name">Full name <span class="req" aria-hidden="true">*</span></label>
          <input class="input" id="c-name" required autocomplete="name" maxlength="120"
                 value="${esc(existing?.full_name || '')}">
          <div class="field-error"></div>
        </div>
        <div class="form-row">
          <div class="field">
            <label for="c-phone">Phone <span class="req" aria-hidden="true">*</span></label>
            <input class="input mono" id="c-phone" required inputmode="numeric"
                   maxlength="10" placeholder="9876543210" autocomplete="tel"
                   value="${esc(existing?.phone || '')}">
            <div class="help">Ten digits, no spaces or country code.</div>
            <div class="field-error"></div>
          </div>
          <div class="field">
            <label for="c-email">Email <span class="optional">(optional)</span></label>
            <input class="input" type="email" id="c-email" autocomplete="email" maxlength="160"
                   placeholder="name@example.com" value="${esc(existing?.email || '')}">
            <div class="field-error"></div>
          </div>
        </div>
      </form>`,
    actions: [
      { label: 'Cancel', onClick: (c) => c() },
      { label: editing ? 'Save changes' : 'Add customer', variant: 'primary', onClick: submit },
    ],
    onMount(scrim) {
      const phone = scrim.querySelector('#c-phone');
      phone.addEventListener('input', () => {
        phone.value = phone.value.replace(/\D/g, '').slice(0, 10);
      });
      scrim.querySelector('#cust-form').addEventListener('submit', (e) => {
        e.preventDefault(); scrim.querySelector('[data-action="1"]').click();
      });
    },
  });

  async function submit(close, scrim) {
    const form = scrim.querySelector('#cust-form');
    clearErrors(form);
    const name = scrim.querySelector('#c-name'), phone = scrim.querySelector('#c-phone');
    const email = scrim.querySelector('#c-email');
    let bad = false;
    if (!name.value.trim()) { fieldError(name, 'Enter the customer’s name.'); bad = true; }
    if (!/^[0-9]{10}$/.test(phone.value)) { fieldError(phone, 'Enter exactly ten digits.'); bad = true; }
    if (email.value.trim() && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email.value.trim())) {
      fieldError(email, 'That does not look like an email address.'); bad = true;
    }
    if (bad) { scrim.querySelector('[aria-invalid="true"]')?.focus(); return; }

    const body = { full_name: name.value.trim(), phone: phone.value, email: email.value.trim() };
    await submitting(scrim.querySelector('[data-action="1"]'), async () => {
      try {
        if (editing) {
          await api.updateCustomer(existing.customer_id, body);
          toast('Changes saved', `${body.full_name} is up to date.`, 'success');
        } else {
          await api.createCustomer(body);
          toast('Customer added', 'You can now register their vehicles.', 'success');
        }
        close(); onDone();
      } catch (err) {
        // Uniqueness failures name the field they belong to.
        const target = err.rule === 'customer_email_key' || err.rule === 'ck_customer_email_shape'
          ? email : err.rule === 'customer_phone_key' || err.rule === 'ck_customer_phone_shape'
          ? phone : null;
        if (target) fieldError(target, err.message); else errorToast('Could not save', err);
      }
    });
  }
}

async function removeCustomer(c, onDone) {
  if (!await confirmDialog('Delete this customer?',
    `${c.full_name} will be removed permanently. Customers with vehicles, bookings or passes on record cannot be deleted.`,
    'Delete customer')) return;
  try {
    await api.deleteCustomer(c.customer_id);
    toast('Customer deleted', `${c.full_name} has been removed.`, 'success');
    onDone();
  } catch (err) { errorToast('Could not delete', err); }
}

async function showVehicles(customer, onDone) {
  let vehicles = [], types = [];
  try {
    [vehicles, types] = await Promise.all([
      api.vehicles({ customer_id: customer.customer_id }), api.vehicleTypes()]);
  } catch (err) { errorToast('Could not load vehicles', err); return; }

  const list = (vs) => vs.length ? `
    <div class="dt"><div class="table-wrap"><table role="table">
      <caption class="sr-only">Vehicles</caption>
      <thead role="rowgroup"><tr role="row"><th scope="col" role="columnheader">Registration</th>
        <th scope="col" role="columnheader">Type</th>
        <th scope="col" role="columnheader">Vehicle</th><th scope="col" role="columnheader">State</th>
        <th scope="col" role="columnheader" class="dt-act-h"><span class="sr-only">Actions</span></th></tr></thead>
      <tbody role="rowgroup">${vs.map((v, i) => `<tr role="row" data-i="${i}">
        <td role="cell" data-label="Registration"><span class="plate-chip">${esc(v.plate_number)}</span></td>
        <td role="cell" data-label="Type">${esc(v.vehicle_type_name)}</td>
        <td role="cell" data-label="Vehicle">${esc([v.make, v.model, v.colour].filter(Boolean).join(' ') || '—')}</td>
        <td role="cell" data-label="State">${v.is_parked ? '<span class="badge badge-occupied">In lot</span>'
                          : '<span class="badge badge-neutral">Away</span>'}</td>
        <td role="cell" class="dt-act"><button class="btn btn-icon btn-sm btn-ghost" type="button"
            data-veh="${v.vehicle_id}" aria-haspopup="menu"
            aria-label="Actions for ${esc(v.plate_number)}">${icon('more')}</button></td>
      </tr>`).join('')}</tbody></table></div></div>` : `
    <div class="empty" style="border:0;background:transparent">
      ${icon('car')}<div class="empty-title">No vehicles yet</div>
      <p>Add one below so this customer can park.</p></div>`;

  modal({
    title: `Vehicles — ${customer.full_name}`,
    width: '680px',
    body: `<div id="veh-list">${list(vehicles)}</div>
      <hr class="rule-gap">
      <h3 class="form-heading">Register a vehicle</h3>
      <form id="veh-form" novalidate>
        <div class="form-row">
          <div class="field">
            <label for="v-plate">Registration number <span class="req" aria-hidden="true">*</span></label>
            <input class="input reg" id="v-plate" required placeholder="TS09AB1234"
                   spellcheck="false" autocomplete="off" maxlength="12">
            <div class="field-error"></div>
          </div>
          <div class="field">
            <label for="v-type">Vehicle type <span class="req" aria-hidden="true">*</span></label>
            <select class="select" id="v-type" required>
              ${types.map((t) => `<option value="${t.vehicle_type_id}">${esc(t.name)}</option>`).join('')}
            </select><div class="field-error"></div>
          </div>
        </div>
        <div class="form-row">
          <div class="field"><label for="v-make">Make</label>
            <input class="input" id="v-make" placeholder="Maruti" maxlength="60"></div>
          <div class="field"><label for="v-model">Model</label>
            <input class="input" id="v-model" placeholder="Swift" maxlength="60"></div>
          <div class="field"><label for="v-colour">Colour</label>
            <input class="input" id="v-colour" placeholder="White" maxlength="30"></div>
        </div>
        <button class="btn btn-primary" type="submit" id="v-submit" data-interactive>
          ${icon('plus')} Register vehicle</button>
      </form>`,
    actions: [{ label: 'Done', onClick: (c) => { c(); onDone(); } }],
    onMount(scrim) {
      const plate = scrim.querySelector('#v-plate');
      plate.addEventListener('input', () => {
        plate.value = plate.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
      });
      scrim.querySelector('#veh-list').addEventListener('click', (e) => {
        const b = e.target.closest('[data-veh]');
        if (!b) return;
        const v = vehicles.find((x) => x.vehicle_id === Number(b.dataset.veh));
        openMenu(b, [
          { label: 'Edit details', icon: 'edit', onClick: () => editVehicle(v, () => refresh(scrim)) },
          { label: 'Remove vehicle', icon: 'trash', danger: true, disabled: v.is_parked,
            onClick: () => removeVehicle(v, scrim) },
        ]);
      });
      scrim.querySelector('#veh-form').addEventListener('submit', async (e) => {
        e.preventDefault();
        const form = e.currentTarget;
        clearErrors(form);
        const v = plate.value.trim();
        if (!/^[A-Z]{2}[0-9]{1,2}[A-Z]{1,3}[0-9]{4}$/.test(v)) {
          fieldError(plate, 'Use the Indian format, for example TS09AB1234.');
          plate.focus(); return;
        }
        await submitting(scrim.querySelector('#v-submit'), async () => {
          try {
            await api.createVehicle({
              customer_id: customer.customer_id, plate_number: v,
              vehicle_type_id: Number(scrim.querySelector('#v-type').value),
              make: scrim.querySelector('#v-make').value.trim() || null,
              model: scrim.querySelector('#v-model').value.trim() || null,
              colour: scrim.querySelector('#v-colour').value.trim() || null,
            });
            toast('Vehicle registered', `${v} is on file.`, 'success');
            form.reset();
            await refresh(scrim);
          } catch (err) { fieldError(plate, err.message); }
        });
      });
    },
  });

  async function refresh(scrim) {
    vehicles = await api.vehicles({ customer_id: customer.customer_id });
    scrim.querySelector('#veh-list').innerHTML = list(vehicles);
  }

  async function removeVehicle(v, scrim) {
    if (!await confirmDialog('Remove this vehicle?',
      `${v.plate_number} will be removed from ${customer.full_name}. A vehicle with parking history cannot be removed.`,
      'Remove vehicle')) return;
    try {
      await api.deleteVehicle(v.vehicle_id);
      toast('Vehicle removed', `${v.plate_number} is no longer on file.`, 'success');
      await refresh(scrim);
    } catch (err) { errorToast('Could not remove that vehicle', err); }
  }
}

function editVehicle(v, onDone) {
  modal({
    title: `Edit ${v.plate_number}`,
    width: '520px',
    body: `
      <form id="ve-form" novalidate>
        <div class="field">
          <label for="ve-plate">Registration number</label>
          <input class="input reg" id="ve-plate" value="${esc(v.plate_number)}" maxlength="12"
                 spellcheck="false" autocomplete="off">
          <div class="help">Owner and vehicle type are fixed once a vehicle is on file.</div>
          <div class="field-error"></div>
        </div>
        <div class="form-row">
          <div class="field"><label for="ve-make">Make</label>
            <input class="input" id="ve-make" value="${esc(v.make || '')}" maxlength="60"></div>
          <div class="field"><label for="ve-model">Model</label>
            <input class="input" id="ve-model" value="${esc(v.model || '')}" maxlength="60"></div>
          <div class="field"><label for="ve-colour">Colour</label>
            <input class="input" id="ve-colour" value="${esc(v.colour || '')}" maxlength="30"></div>
        </div>
      </form>`,
    actions: [
      { label: 'Cancel', onClick: (c) => c() },
      { label: 'Save changes', variant: 'primary', onClick: save },
    ],
    onMount(scrim) {
      const plate = scrim.querySelector('#ve-plate');
      plate.addEventListener('input', () => {
        plate.value = plate.value.toUpperCase().replace(/[^A-Z0-9]/g, '');
      });
    },
  });

  async function save(close, scrim) {
    const plate = scrim.querySelector('#ve-plate');
    clearErrors(scrim.querySelector('#ve-form'));
    if (!/^[A-Z]{2}[0-9]{1,2}[A-Z]{1,3}[0-9]{4}$/.test(plate.value)) {
      fieldError(plate, 'Use the Indian format, for example TS09AB1234.'); plate.focus(); return;
    }
    const val = (id) => scrim.querySelector(id).value.trim() || null;
    await submitting(scrim.querySelector('[data-action="1"]'), async () => {
      try {
        await api.updateVehicle(v.vehicle_id, {
          plate_number: plate.value, make: val('#ve-make'),
          model: val('#ve-model'), colour: val('#ve-colour'),
        });
        toast('Vehicle updated', `${plate.value} saved.`, 'success');
        close(); onDone();
      } catch (err) { fieldError(plate, err.message); }
    });
  }
}
