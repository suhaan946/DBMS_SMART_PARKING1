/* ===========================================================================
   bay-sheet.js — the bay detail panel.

   Opens beside the map rather than over it, so the operator never loses their
   place on the floor. Focus is trapped while open, Escape closes, and focus
   returns to the bay that was clicked.
   =========================================================================== */
import { auth, api } from './api.js';
import {
  icon, esc, money, duration, dateTime, titleCase, toast, errorToast, BAY_WORD,
  fieldError, submitting,
} from './ui.js';
import { openPanel, closePanel, bindInteractive } from './motion.js';

export function openBaySheet(slot, onChange) {
  // Remember WHICH bay, not just the node. Closing may trigger a refresh that
  // re-renders the map, and focusing a detached element silently drops the
  // keyboard user back to the top of the document.
  const previouslyFocused = document.activeElement;
  const returnToSlotId = previouslyFocused?.closest?.('.bay')?.dataset.slotId
                       ?? String(slot.slot_id);

  const scrim = document.createElement('div');
  scrim.className = 'sheet-scrim';
  const sheet = document.createElement('aside');
  sheet.className = 'sheet';
  sheet.setAttribute('role', 'dialog');
  sheet.setAttribute('aria-modal', 'true');
  sheet.setAttribute('aria-labelledby', 'sheet-title');

  const state = slot.slot_state;
  const word = BAY_WORD[state] || titleCase(state);

  const facts = [
    ['Floor', slot.floor_name],
    ['Zone', `Zone ${slot.zone_code}`],
    ['Built for', slot.vehicle_type_name],
  ];
  const occupancy = state === 'occupied' ? [
    ['Vehicle', slot.plate_number],
    ['Customer', slot.customer_name],
    ['Ticket', slot.ticket_no],
    ['Entered', dateTime(slot.entry_time)],
    ['Elapsed', duration(minutesSince(slot.entry_time))],
    ['Charge so far', money(slot.running_charge)],
  ] : [];

  sheet.innerHTML = `
    <div class="sheet-head">
      <div style="flex:1;min-width:0">
        <div class="label">Bay</div>
        <h2 id="sheet-title" class="mono">${esc(slot.slot_code)}</h2>
        <div style="margin-top:var(--s2)">
          <span class="badge badge-${esc(state)}">${esc(word)}</span>
        </div>
      </div>
      <button class="btn btn-icon btn-ghost" data-close
              aria-label="Close bay details">${icon('close')}</button>
    </div>
    <div class="sheet-body">
      <dl class="dl">
        ${facts.map(([k, v]) =>
          `<dt>${esc(k)}</dt><dd>${esc(v ?? '—')}</dd>`).join('')}
      </dl>
      ${occupancy.length ? `
        <div style="margin:var(--s5) 0 var(--s3)" class="label">Current session</div>
        <dl class="dl">
          ${occupancy.map(([k, v]) => `<dt>${esc(k)}</dt>
            <dd class="${/Vehicle|Ticket|Elapsed|Charge/.test(k) ? 'mono' : ''}">${esc(v ?? '—')}</dd>`).join('')}
        </dl>
        <p style="font-size:var(--t-2xs);color:var(--ink-2);margin-top:var(--s4)">
          The charge is computed by the database from the tariff in force when
          the vehicle arrived. It is the figure that will be billed on exit.
        </p>` : ''}
      ${state === 'reserved' ? `
        <div class="warn-state" style="margin-top:var(--s5);text-align:left;padding:var(--s4)">
          ${icon('clock')}
          <div class="empty-title" style="font-size:var(--t-sm)">Held for an arrival</div>
          <p style="font-size:var(--t-xs)">This bay is blocked for a booked window.
          Two live holds cannot overlap on one bay — the database refuses the second.</p>
        </div>` : ''}
      ${state === 'out_of_service' ? `
        <div class="empty" style="margin-top:var(--s5);text-align:left;padding:var(--s4)">
          ${icon('ban')}
          <div class="empty-title" style="font-size:var(--t-sm)">Not in service</div>
          <p style="font-size:var(--t-xs)">${slot.service_note
            ? `Reason: ${esc(slot.service_note)}` : 'Allocation skips this bay entirely.'}</p>
        </div>
        ${auth.isStaff ? `<button class="btn btn-primary btn-block" type="button" id="svc-return"
            style="margin-top:var(--s4)" data-interactive>${icon('check')} Return to service</button>` : ''}` : ''}
      ${state === 'free' ? `
        <div class="empty" style="margin-top:var(--s5);text-align:left;padding:var(--s4);
                    border-color:var(--state-free-line);background:var(--ok-wash)">
          ${icon('check')}
          <div class="empty-title" style="font-size:var(--t-sm)">Available now</div>
          <p style="font-size:var(--t-xs)">The next arrival of a matching vehicle type may be
          allocated here.</p>
        </div>
        ${auth.isStaff ? `<form class="service-form" id="svc-form" novalidate>
          <div class="label">Maintenance</div>
          <div class="field">
            <label for="svc-note">Why is it going out of service?</label>
            <input class="input" id="svc-note" maxlength="200" autocomplete="off"
                   placeholder="e.g. Drain cover lifted">
            <div class="field-error"></div>
          </div>
          <button class="btn btn-danger btn-block" type="submit" data-interactive>
            ${icon('wrench')} Take out of service</button>
          <p class="muted small" style="margin-top:var(--s2)">An occupied or held bay cannot be
            taken out; the database checks and locks the bay first.</p>
        </form>` : ''}` : ''}
    </div>
    <div class="sheet-foot">
      ${state === 'occupied' && auth.isStaff
        ? `<a class="btn btn-primary btn-block" data-interactive
             href="gate.html?lookup=${encodeURIComponent(slot.ticket_no || slot.plate_number || '')}">
             ${icon('gate')} Record departure</a>`
        : `<a class="btn btn-block" href="slots.html" data-interactive>Open full map</a>`}
    </div>`;

  document.body.appendChild(scrim);
  document.body.appendChild(sheet);
  document.body.style.overflow = 'hidden';
  openPanel(scrim, sheet, { from: 'right' });

  const close = async () => {
    await closePanel(scrim, sheet, { from: 'right' });
    scrim.remove(); sheet.remove();
    document.body.style.overflow = '';

    // The panel is read-only, so a plain close changes nothing and must NOT
    // trigger a refresh — a refresh here was re-rendering the map and losing
    // the caller's focus. onChange is invoked only after a real mutation.
    restoreFocus();
  };

  /** Focus the bay again, re-queried by id in case the map was re-rendered. */
  function restoreFocus() {
    const live = document.querySelector(`.bay[data-slot-id="${returnToSlotId}"]`);
    (live || previouslyFocused)?.focus?.();
  }

  /** Call after an action that actually altered state. */
  async function closeAndRefresh() {
    await closePanel(scrim, sheet, { from: 'right' });
    scrim.remove(); sheet.remove();
    document.body.style.overflow = '';
    await onChange?.();
    restoreFocus();
  }

  sheet.querySelector('#svc-form')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const note = sheet.querySelector('#svc-note');
    if (!note.value.trim()) { fieldError(note, 'Give a reason, so the next shift knows.'); note.focus(); return; }
    await submitting(e.submitter || e.currentTarget.querySelector('button'), async () => {
      try {
        await api.setSlotService(slot.slot_id, false, note.value.trim());
        toast('Bay taken out of service', `${slot.slot_code}: ${note.value.trim()}`, 'success');
        await closeAndRefresh();
      } catch (err) { fieldError(note, err.message); }
    });
  });
  sheet.querySelector('#svc-return')?.addEventListener('click', async (e) => {
    await submitting(e.currentTarget, async () => {
      try {
        await api.setSlotService(slot.slot_id, true);
        toast('Bay back in service', `${slot.slot_code} can be allocated again.`, 'success');
        await closeAndRefresh();
      } catch (err) { errorToast('Could not return the bay', err); }
    });
  });

  scrim.addEventListener('click', close);
  sheet.querySelector('[data-close]').addEventListener('click', close);

  const focusables = () => sheet.querySelectorAll(
    'button:not([disabled]),[href],input:not([disabled]),select:not([disabled]),[tabindex]:not([tabindex="-1"])');
  sheet.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') { e.preventDefault(); close(); return; }
    if (e.key !== 'Tab') return;
    const f = Array.from(focusables());
    if (!f.length) return;
    const first = f[0], last = f[f.length - 1];
    if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
    else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
  });

  sheet.querySelector('[data-close]')?.focus();
  bindInteractive(sheet);
  return { close };
}

function minutesSince(iso) {
  if (!iso) return 0;
  return Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
}
