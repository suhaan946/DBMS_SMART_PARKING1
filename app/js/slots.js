/* slots.js — the signature screen: a floor plan, not a spreadsheet. */
import { api } from './api.js';
import {
  mountShell, icon, esc, money, duration, dateTime, titleCase,
  skeleton, empty, errorState, facility, toast,
  bayHTML, zoneHTML, groupByZone,
} from './ui.js';
import { enter, revealList, bindInteractive, applyBayChanges } from './motion.js';
import { openBaySheet } from './bay-sheet.js';

const ctx = mountShell('slots.html', {
  title: 'Floor map',
  subtitle: 'Live availability by floor and zone',
});
if (ctx) init(ctx);

async function init({ content, user }) {
  content.innerHTML = `
    <div class="toolbar">
      <label class="sr-only" for="facility">Facility</label>
      <select class="select" id="facility" style="max-width:240px"></select>
      <label class="sr-only" for="vtype">Vehicle type</label>
      <select class="select" id="vtype" style="max-width:180px">
        <option value="all">All vehicle types</option></select>
      <label class="sr-only" for="state">Availability</label>
      <select class="select" id="state" style="max-width:170px">
        <option value="all">All states</option>
        <option value="free">Free only</option>
        <option value="reserved">Reserved</option>
        <option value="occupied">Occupied</option>
        <option value="out_of_service">Out of service</option>
      </select>
      <div class="spacer"></div>
      <button class="btn" id="refresh" data-interactive>${icon('refresh')} Refresh</button>
    </div>

    <div class="card" style="margin-bottom:var(--s5)">
      <div id="summary" class="stat-row" style="margin:0"></div>
    </div>

    <div class="floor-tabs" id="floor-tabs" role="tablist" aria-label="Floors"></div>
    <div class="legend" style="margin-bottom:var(--s5)">
      <span class="legend-item"><span class="sw sw-free"></span>Free</span>
      <span class="legend-item"><span class="sw sw-held"></span>Reserved</span>
      <span class="legend-item"><span class="sw sw-full"></span>Occupied</span>
      <span class="legend-item"><span class="sw sw-off"></span>Out of service</span>
      <span class="legend-item" style="color:var(--ink-2)">
        Every bay also shows its state in words — colour is never the only cue.</span>
    </div>
    <div id="map"></div>`;

  const selF = content.querySelector('#facility');
  const selV = content.querySelector('#vtype');
  const selS = content.querySelector('#state');
  const tabs = content.querySelector('#floor-tabs');
  let floorFilter = 'all';

  let facilities, types;
  try {
    [facilities, types] = await Promise.all([api.facilities(), api.vehicleTypes()]);
  } catch (err) { errorState(content, err, () => location.reload()); return; }

  const scoped = user.facility_id
    ? facilities.filter((f) => f.facility_id === user.facility_id) : facilities;
  selF.innerHTML = scoped.map((f) =>
    `<option value="${f.facility_id}">${esc(f.name)}</option>`).join('');
  if (scoped.length === 1) selF.disabled = true;
  const remembered = facility.get();
  if (remembered && scoped.some((f) => f.facility_id === remembered)) selF.value = String(remembered);

  selV.innerHTML += types.map((t) =>
    `<option value="${t.vehicle_type_id}">${esc(t.name)}</option>`).join('');

  [selF, selV, selS].forEach((el) => el.addEventListener('change', () => {
    if (el === selF) { facility.set(Number(selF.value)); floorFilter = 'all'; }
    load();
  }));
  content.querySelector('#refresh').addEventListener('click', () => load({ announce: true }));

  load();

  async function load({ announce = false } = {}) {
    const host = content.querySelector('#map');
    skeleton(host, { rows: 6, kind: 'slot' });
    let data;
    try {
      data = await api.slots(Number(selF.value), {
        vehicle_type_id: selV.value, state: selS.value,
      });
    } catch (err) { errorState(host, err, load); return; }

    renderSummary(content.querySelector('#summary'), data.counts);
    renderTabs(tabs, data.slots, floorFilter, (lvl) => { floorFilter = lvl; load(); });
    renderMap(host, data.slots, floorFilter, selS.value !== 'all' || selV.value !== 'all', () => load());
    if (announce) toast('Refreshed', 'Slot states are current.', 'success');
  }
}

function renderSummary(host, counts) {
  const c = counts || {};
  const total = Object.values(c).reduce((a, b) => a + b, 0);
  const cell = (label, n, tone) => `
    <div class="stat" style="border:0;padding:0">
      <div class="stat-label"><span class="sw sw-${tone}"></span>${label}</div>
      <div class="stat-value mono" style="font-size:var(--t-xl)">${n || 0}</div>
    </div>`;
  host.innerHTML =
    cell('Free', c.free, 'free') + cell('Reserved', c.reserved, 'held') +
    cell('Occupied', c.occupied, 'full') + cell('Out of service', c.out_of_service, 'off') +
    `<div class="stat" style="border:0;padding:0">
       <div class="stat-label">Total bays</div>
       <div class="stat-value mono" style="font-size:var(--t-xl)">${total}</div></div>`;
}

function renderTabs(host, slots, active, onPick) {
  const floors = [...new Map(slots.map((s) =>
    [s.level_number, s.floor_name])).entries()].sort((a, b) => a[0] - b[0]);
  host.innerHTML = `<button class="floor-tab" role="tab"
      aria-selected="${active === 'all'}" data-level="all">All floors</button>` +
    floors.map(([lvl, name]) => `<button class="floor-tab" role="tab"
      aria-selected="${String(active) === String(lvl)}" data-level="${lvl}">${esc(name)}</button>`).join('');
  host.querySelectorAll('.floor-tab').forEach((b) =>
    b.addEventListener('click', () => onPick(b.dataset.level)));
}

function renderMap(host, slots, floorFilter, filtered, onChange) {
  const shown = floorFilter === 'all'
    ? slots : slots.filter((s) => String(s.level_number) === String(floorFilter));

  if (!shown.length) {
    empty(host, {
      title: filtered ? 'No bays match these filters' : 'No bays on this floor',
      body: filtered
        ? 'Widen the vehicle type or availability filter to see more bays.'
        : 'Add zones and slots for this floor in Settings.',
      iconName: 'grid',
    });
    return;
  }

  // Same renderer as the dashboard map, so a bay looks and behaves identically
  // wherever it appears.
  host.innerHTML = groupByZone(shown).map((z) => zoneHTML(z)).join('');
  revealList(host.querySelectorAll('.bay'));
  bindInteractive(host);

  const byId = new Map(shown.map((s) => [String(s.slot_id), s]));
  host.querySelectorAll('.bay').forEach((el) => {
    el.addEventListener('click', () => {
      const s = byId.get(el.dataset.slotId);
      if (s) openBaySheet(s, onChange);
    });
  });
}
