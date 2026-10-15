/* ===========================================================================
   api.js — the only place that talks to the server.

   One data layer. There is no second client, no Firebase, no direct database
   access from the browser. Every screen goes through this module.
   =========================================================================== */

const TOKEN_KEY = 'smartpark.token';
const USER_KEY  = 'smartpark.user';

export const auth = {
  get token() { try { return localStorage.getItem(TOKEN_KEY); } catch { return null; } },
  get user() {
    try { return JSON.parse(localStorage.getItem(USER_KEY) || 'null'); } catch { return null; }
  },
  save(token, user) {
    try {
      localStorage.setItem(TOKEN_KEY, token);
      localStorage.setItem(USER_KEY, JSON.stringify(user));
    } catch { /* private browsing: the session simply will not persist */ }
  },
  clear() {
    try { localStorage.removeItem(TOKEN_KEY); localStorage.removeItem(USER_KEY); } catch {}
  },
  get isStaff() {
    const u = this.user;
    return !!u && (u.role === 'admin' || u.role === 'operator');
  },
};

/** Thrown for any non-2xx response. `.message` is safe to show a user: it is
 *  the server's own wording, which for integrity failures is the mapped
 *  constraint message from api/errors.py. */
export class ApiError extends Error {
  constructor(message, status, rule = null) {
    super(message); this.status = status; this.rule = rule; this.name = 'ApiError';
  }
}

async function request(method, path, body) {
  const headers = { 'Content-Type': 'application/json' };
  if (auth.token) headers.Authorization = `Bearer ${auth.token}`;

  let res;
  try {
    res = await fetch(path, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch {
    throw new ApiError('Cannot reach the server. Check that the API is running.', 0);
  }

  // A 401 on a request that carried a token means the session ended. On the
  // sign-in call itself it just means wrong credentials, and the server's own
  // message ("Email or password is incorrect.") is the one to show.
  if (res.status === 401 && headers.Authorization) {
    auth.clear();
    if (!location.pathname.endsWith('index.html') && location.pathname !== '/') {
      location.href = 'index.html';
    }
    throw new ApiError('Your session has expired. Sign in again.', 401);
  }

  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = null; }

  if (!res.ok) {
    let msg = `Request failed (${res.status}).`;
    const d = data?.detail;
    if (typeof d === 'string') msg = d;
    else if (Array.isArray(d) && d.length) {
      // FastAPI validation errors: surface the field, not the raw schema dump.
      msg = d.map((e) => {
        const field = (e.loc || []).filter((x) => x !== 'body').join('.');
        return field ? `${field}: ${e.msg}` : e.msg;
      }).join('; ');
    }
    throw new ApiError(msg, res.status, data?.rule || null);
  }
  return data;
}

export const get   = (p)    => request('GET', p);
export const post  = (p, b) => request('POST', p, b);
export const patch = (p, b) => request('PATCH', p, b);
export const del   = (p)    => request('DELETE', p);

/* --- Endpoints ---------------------------------------------------------- */
export const api = {
  login:        (email, password) => post('/api/auth/login', { email, password }),
  facilities:   ()                => get('/api/facilities'),
  vehicleTypes: ()                => get('/api/vehicle-types'),
  floors:       (f)               => get(`/api/floors?facility_id=${f}`),
  tariffs:      ()                => get('/api/tariffs'),
  createTariff: (b)               => post('/api/tariffs', b),
  passTypes:    ()                => get('/api/pass-types'),

  slots: (f, q = {}) => {
    const p = new URLSearchParams({ facility_id: f });
    Object.entries(q).forEach(([k, v]) => { if (v && v !== 'all') p.set(k, v); });
    return get(`/api/slots?${p}`);
  },
  freeSlots: (f, q = {}) => {
    const p = new URLSearchParams({ facility_id: f });
    Object.entries(q).forEach(([k, v]) => { if (v && v !== 'all') p.set(k, v); });
    return get(`/api/slots/free?${p}`);
  },

  gateEntry:  (plate, facility_id) => post('/api/gate/entry', { plate, facility_id }),
  gateLookup: (q)                  => get(`/api/gate/lookup?q=${encodeURIComponent(q)}`),
  gateExit:   (lookup)             => post('/api/gate/exit', { lookup }),

  sessions: (q = {}) => {
    const p = new URLSearchParams();
    Object.entries(q).forEach(([k, v]) => { if (v !== undefined && v !== null) p.set(k, v); });
    return get(`/api/sessions?${p}`);
  },

  reservations:      (s)     => get(`/api/reservations${s && s !== 'all' ? `?status=${s}` : ''}`),
  createReservation: (b)     => post('/api/reservations', b),
  setReservation:    (id, s) => patch(`/api/reservations/${id}?status=${s}`),

  passes:     ()   => get('/api/passes'),
  buyPass:    (b)  => post('/api/passes', b),
  cancelPass: (id) => del(`/api/passes/${id}`),

  bills: (s, q = '', limit = 200) => {
    const p = new URLSearchParams({ limit });
    if (s && s !== 'all') p.set('status', s);
    if (q) p.set('q', q);
    return get(`/api/bills?${p}`);
  },
  bill:       (id) => get(`/api/bills/${id}`),
  pay:        (b)  => post('/api/payments', b),

  customers:     (q) => get(`/api/customers${q ? `?q=${encodeURIComponent(q)}` : ''}`),
  createCustomer:(b) => post('/api/customers', b),
  updateCustomer:(id, b) => patch(`/api/customers/${id}`, b),
  deleteCustomer:(id) => del(`/api/customers/${id}`),
  vehicles:      (q = {}) => {
    const p = new URLSearchParams();
    Object.entries(q).forEach(([k, v]) => { if (v) p.set(k, v); });
    return get(`/api/vehicles?${p}`);
  },
  createVehicle: (b)  => post('/api/vehicles', b),
  deleteVehicle: (id) => del(`/api/vehicles/${id}`),
  updateVehicle: (id, b) => patch(`/api/vehicles/${id}`, b),

  setSlotService: (id, inService, note) =>
    patch(`/api/slots/${id}/service`, { in_service: inService, note: note || null }),
  payments: (q = {}) => {
    const p = new URLSearchParams();
    Object.entries(q).forEach(([k, v]) => { if (v && v !== 'all') p.set(k, v); });
    return get(`/api/payments?${p}`);
  },
  activity: (f, limit = 15) => get(`/api/activity?facility_id=${f}&limit=${limit}`),
  audit:    (q = {}) => {
    const p = new URLSearchParams();
    Object.entries(q).forEach(([k, v]) => { if (v) p.set(k, v); });
    return get(`/api/audit?${p}`);
  },

  dashboard: (f) => get(`/api/dashboard?facility_id=${f}`),
  report: {
    occupancy: (f) => get(`/api/reports/occupancy?facility_id=${f}`),
    peak:      (f) => get(`/api/reports/peak-hours?facility_id=${f}`),
    revenue:   (f) => get(`/api/reports/revenue?facility_id=${f}`),
    duration:  (f) => get(`/api/reports/duration?facility_id=${f}`),
    passUsage: ()  => get('/api/reports/pass-usage'),
    violations:()  => get('/api/reports/violations'),
    freeSlots: (f) => get(`/api/reports/free-slots?facility_id=${f}`),
    vehicleHistory: (plate) => get(`/api/reports/vehicle-history?plate=${encodeURIComponent(plate)}`),
  },
};
