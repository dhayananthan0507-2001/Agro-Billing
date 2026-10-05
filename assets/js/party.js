// Shared controller for customers.html and suppliers.html (Phase 3).
// The page sets window.PARTY (table + labels) and loads assets/js/auth.js first, so this file reuses
// auth.js's single Supabase client (client()), its credentials and validEmail() instead of duplicating them.
(() => {
const C = window.PARTY, T = C.table, NAME = C.nameField, PAGE = 25;
const db = client();
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = n => '₹' + Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const STATES = ['Andaman and Nicobar Islands', 'Andhra Pradesh', 'Arunachal Pradesh', 'Assam', 'Bihar', 'Chandigarh', 'Chhattisgarh', 'Dadra and Nagar Haveli and Daman and Diu', 'Delhi', 'Goa', 'Gujarat', 'Haryana', 'Himachal Pradesh', 'Jammu and Kashmir', 'Jharkhand', 'Karnataka', 'Kerala', 'Ladakh', 'Lakshadweep', 'Madhya Pradesh', 'Maharashtra', 'Manipur', 'Meghalaya', 'Mizoram', 'Nagaland', 'Odisha', 'Puducherry', 'Punjab', 'Rajasthan', 'Sikkim', 'Tamil Nadu', 'Telangana', 'Tripura', 'Uttar Pradesh', 'Uttarakhand', 'West Bengal'];
const COLS = `id,${NAME},phone,email,address,city,state,pincode,gst_number,opening_balance,balance_type,notes,is_active,created_at`;

let cid, role, page = 0, total = 0, timer, reqId = 0, rows = [], editing = null, pendingDeactivate = null;
const canWrite = () => role === 'owner' || role === 'manager';

// ---------- UI shell ----------
const toast = (t, ok = true) => { const e = $('toast'); e.textContent = t; e.style.background = ok ? '#1f4d2b' : '#a32020'; e.style.display = 'block'; clearTimeout(toast.t); toast.t = setTimeout(() => e.style.display = 'none', 4000); };

function shell() {
  const p = C.plural.toLowerCase();
  $('app').innerHTML = `
  <div class="top"><div><h2>${C.plural}</h2><p class="sub">${esc(C.description)}</p><small id="who"></small></div><button id="add" hidden>+ Add ${C.singular}</button></div>
  <div class="bar" style="margin-top:16px"><input id="q" type="search" placeholder="Search by name, phone or GST number…" aria-label="Search ${p}" autocomplete="off">
    <select id="fs" aria-label="Status filter"><option value="1">Active</option><option value="0">Inactive</option><option value="">All</option></select></div>
  <div class="tw" id="tw"><table><thead><tr><th>${C.singular}</th><th>Phone</th><th>GST</th><th>Location</th><th>Opening balance</th><th>Status</th><th>Actions</th></tr></thead><tbody id="rows"></tbody></table></div>
  <div id="state"></div>
  <div class="pg"><button class="ghost" id="prev" aria-label="Previous page">‹</button><span id="pn"></span><button class="ghost" id="next" aria-label="Next page">›</button></div>

  <dialog id="dlg"><h2 id="dt"></h2><form id="f" class="g" novalidate>
    <div class="f"><label for="${NAME}">${C.singular} name *</label><input id="${NAME}" name="${NAME}" maxlength="150" autocomplete="off"><small class="fe" data-for="${NAME}"></small></div>
    <div><label for="phone">Phone *</label><input id="phone" name="phone" type="tel" inputmode="tel" maxlength="20" placeholder="98765 43210"><small class="fe" data-for="phone"></small></div>
    <div><label for="email">Email</label><input id="email" name="email" type="email" maxlength="254" autocomplete="off"><small class="fe" data-for="email"></small></div>
    <div class="f"><label for="gst_number">GST number</label><input id="gst_number" name="gst_number" maxlength="15" placeholder="33AABCU9603R1ZX" style="text-transform:uppercase"><small class="fe" data-for="gst_number"></small></div>
    <div class="f"><label for="address">Address</label><textarea id="address" name="address" maxlength="500" rows="2"></textarea><small class="fe" data-for="address"></small></div>
    <div><label for="city">City / Town</label><input id="city" name="city" maxlength="100"><small class="fe" data-for="city"></small></div>
    <div><label for="state_sel">State</label><select id="state_sel" name="state"><option value="">Select state</option>${STATES.map(s => `<option>${s}</option>`).join('')}</select></div>
    <div><label for="pincode">Pincode</label><input id="pincode" name="pincode" inputmode="numeric" maxlength="6"><small class="fe" data-for="pincode"></small></div>
    <div><label for="opening_balance">Opening balance (₹)</label><input id="opening_balance" name="opening_balance" type="number" min="0" step="0.01" placeholder="0.00"><small class="fe" data-for="opening_balance"></small></div>
    <div class="f"><label for="balance_type">Balance type</label><select id="balance_type" name="balance_type">${['debit', 'credit'].map(k => `<option value="${k}">${esc(C.balanceOption[k])}</option>`).join('')}</select></div>
    <div class="f"><label for="notes">Notes</label><textarea id="notes" name="notes" maxlength="1000" rows="2"></textarea><small class="fe" data-for="notes"></small></div>
    <div class="f acts-row"><button type="button" class="ghost" id="cancel">Cancel</button><button id="save">Save ${C.singular.toLowerCase()}</button></div>
  </form></dialog>

  <dialog id="vdlg"><h2 id="vt"></h2><dl class="dl" id="vbody"></dl><div class="acts-row"><button type="button" class="ghost" id="vclose">Close</button></div></dialog>

  <dialog id="cdlg"><h2>Deactivate ${C.singular.toLowerCase()}?</h2><p id="cmsg"></p>
    <div class="acts-row"><button type="button" class="ghost" id="cno">Cancel</button><button type="button" class="danger" id="cyes">Deactivate</button></div></dialog>`;
}

// ---------- Errors ----------
function friendlyError(e) {
  const m = ((e?.message || '') + ' ' + (e?.details || '')).toLowerCase();
  if (/jwt|expired|not authenticated/.test(m) || e?.code === 'PGRST301') return { text: 'Your session has expired. Please sign in again.', auth: true };
  if (/failed to fetch|network|load failed/.test(m)) return { text: 'Network problem. Please check your connection and try again.' };
  if (e?.code === '23505' && /gst/.test(m)) return { text: `Another ${C.singular.toLowerCase()} in your shop already uses this GST number (it may be inactive).`, field: 'gst_number' };
  if (e?.code === '42501') return { text: 'You do not have permission for this action.' };
  if (e?.code === '23514') return { text: 'Some details are not valid. Please check the form and try again.' };
  return { text: 'Something went wrong. Please try again.' };
}
function fail(e, context) {
  console.error(`[${T}] ${context}:`, e);
  const f = friendlyError(e);
  toast(f.text, false);
  if (f.auth) setTimeout(() => location.replace('login.html'), 1500);
  return f;
}

// ---------- List ----------
function setState(html) { $('state').innerHTML = html; $('tw').hidden = !!html; }
async function load() {
  const my = ++reqId; // ignore out-of-order responses
  $('state').innerHTML = ''; $('tw').hidden = false;
  $('rows').innerHTML = '<tr><td colspan="7"><div class="sk"></div></td></tr>'.repeat(4);
  let q = db.from(T).select(COLS, { count: 'exact' }).eq('company_id', cid);
  const st = $('fs').value; if (st !== '') q = q.eq('is_active', st === '1');
  const s = $('q').value.trim().replace(/[,()%\\*"]/g, ' ').replace(/\s+/g, ' ').trim();
  if (s) q = q.or(`${NAME}.ilike.%${s}%,phone.ilike.%${s.replace(/[\s-]/g, '')}%,gst_number.ilike.%${s}%`);
  const { data, count, error } = await q.order(NAME).order('id').range(page * PAGE, page * PAGE + PAGE - 1);
  if (my !== reqId) return;
  if (error) {
    const f = fail(error, 'load'); $('rows').innerHTML = ''; $('pn').textContent = ''; $('prev').disabled = $('next').disabled = true;
    return setState(`<div class="st"><h3>Unable to load ${C.plural.toLowerCase()}.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="retry">Try again</button></div>`);
  }
  total = count || 0;
  if (!data.length && page > 0) { page = Math.max(0, Math.ceil(total / PAGE) - 1); return load(); } // e.g. last row on last page was deactivated
  rows = data;
  $('pn').textContent = total ? `${page * PAGE + 1}–${Math.min(total, (page + 1) * PAGE)} of ${total}` : '0';
  $('prev').disabled = page === 0; $('next').disabled = (page + 1) * PAGE >= total;
  if (!data.length) {
    $('rows').innerHTML = '';
    return setState(s ? `<div class="st"><h3>No ${C.plural.toLowerCase()} match “${esc(s)}”</h3><p>Try a different name, phone number or GST number.</p></div>`
      : st === '1' ? `<div class="st"><h3>No ${C.plural.toLowerCase()} yet</h3><p>Add your first ${C.singular.toLowerCase()} to start managing ${C.singular.toLowerCase()} records.</p>${canWrite() ? `<button id="empty-add">+ Add ${C.singular}</button>` : '<p>Ask the owner or a manager to add one.</p>'}</div>`
      : `<div class="st"><h3>Nothing to show</h3><p>No ${st === '0' ? 'inactive ' : ''}${C.plural.toLowerCase()} found.</p></div>`);
  }
  $('rows').innerHTML = data.map(r => {
    const bal = Number(r.opening_balance) > 0 ? `${money(r.opening_balance)}<span class="bl ${C.owesLabelType === r.balance_type ? 'owe' : ''}">${esc(C.balanceShort[r.balance_type])}</span>` : money(0);
    const loc = [r.city, r.state].filter(Boolean).join(', ');
    return `<tr><td><b>${esc(r[NAME])}</b>${r.email ? `<span class="sub2">${esc(r.email)}</span>` : ''}</td><td>${esc(r.phone)}</td><td>${esc(r.gst_number || '—')}</td><td>${esc(loc || '—')}</td><td>${bal}</td>
      <td><span class="b ${r.is_active ? 'in' : 'arc'}">${r.is_active ? 'Active' : 'Inactive'}</span></td>
      <td><div class="acts"><button class="ghost" data-act="view" data-id="${r.id}">View</button>${canWrite() ? `<button class="ghost" data-act="edit" data-id="${r.id}">Edit</button><button class="${r.is_active ? 'ghost' : ''}" data-act="${r.is_active ? 'off' : 'on'}" data-id="${r.id}">${r.is_active ? 'Deactivate' : 'Activate'}</button>` : ''}</div></td></tr>`;
  }).join('');
}

// ---------- Validation ----------
const GST_RE = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/;
function collect() {
  const g = n => (document.querySelector(`#f [name="${n}"]`).value || '').trim();
  const v = {
    [NAME]: g(NAME), phone: g('phone').replace(/[\s()-]/g, ''), email: g('email').toLowerCase(), gst_number: g('gst_number').toUpperCase(),
    address: g('address'), city: g('city'), state: g('state'), pincode: g('pincode'), notes: g('notes'),
    balance_type: g('balance_type'), balRaw: g('opening_balance')
  };
  const err = {};
  if (!v[NAME]) err[NAME] = `${C.singular} name is required.`; else if (v[NAME].length > 150) err[NAME] = 'Name is too long (max 150 characters).';
  if (!v.phone) err.phone = 'Phone number is required.'; else if (!/^\+?[0-9]{10,13}$/.test(v.phone)) err.phone = 'Enter a valid phone number (10–13 digits, e.g. 98765 43210 or +91 98765 43210).';
  if (v.email && (!validEmail(v.email) || v.email.length > 254)) err.email = 'Enter a valid email address.';
  if (v.gst_number && !GST_RE.test(v.gst_number)) err.gst_number = 'GST number must be 15 characters, e.g. 33AABCU9603R1ZX.';
  if (v.pincode && !/^[1-9][0-9]{5}$/.test(v.pincode)) err.pincode = 'Pincode must be 6 digits.';
  if (v.address.length > 500) err.address = 'Address is too long (max 500 characters).';
  if (v.city.length > 100) err.city = 'City is too long.';
  if (v.notes.length > 1000) err.notes = 'Notes are too long (max 1000 characters).';
  let bal = 0;
  if (v.balRaw !== '') { bal = Number(v.balRaw); if (!Number.isFinite(bal) || bal < 0) err.opening_balance = 'Opening balance must be 0 or more.'; else if (bal >= 1e12) err.opening_balance = 'Amount is too large.'; else bal = Math.round(bal * 100) / 100; }
  if (!['debit', 'credit'].includes(v.balance_type)) v.balance_type = C.defaultBalance;
  return { err, payload: { [NAME]: v[NAME], phone: v.phone, email: v.email || null, address: v.address || null, city: v.city || null, state: v.state || null, pincode: v.pincode || null, gst_number: v.gst_number || null, opening_balance: bal, balance_type: v.balance_type, notes: v.notes || null } };
}
function showErrors(err) {
  document.querySelectorAll('#f .fe').forEach(s => { s.textContent = err[s.dataset.for] || ''; });
  document.querySelectorAll('#f input,#f select,#f textarea').forEach(i => i.classList.toggle('bad', !!err[i.name]));
  const first = Object.keys(err)[0]; if (first) document.querySelector(`#f [name="${first}"]`)?.focus();
}

// ---------- Add / edit ----------
function openForm(rec) {
  editing = rec || null;
  $('f').reset(); showErrors({});
  $('dt').textContent = rec ? `Edit ${C.singular.toLowerCase()}` : `Add ${C.singular.toLowerCase()}`;
  const set = (n, v) => { document.querySelector(`#f [name="${n}"]`).value = v ?? ''; };
  if (rec) {
    [NAME, 'phone', 'email', 'gst_number', 'address', 'city', 'state', 'pincode', 'notes', 'balance_type'].forEach(n => set(n, rec[n]));
    set('opening_balance', Number(rec.opening_balance) ? rec.opening_balance : '');
  } else set('balance_type', C.defaultBalance);
  $('dlg').showModal();
}
async function save(e) {
  e.preventDefault();
  if (!canWrite()) return toast('You do not have permission for this action.', false);
  const { err, payload } = collect(); showErrors(err);
  if (Object.keys(err).length) return;
  const btn = $('save'); btn.disabled = true; const label = btn.textContent; btn.textContent = 'Saving…';
  try {
    // company_id comes only from the signed-in user's membership; on edit it is never sent (and the DB refuses changes to it).
    const res = editing
      ? await db.from(T).update(payload).eq('id', editing.id).eq('company_id', cid).select('id')
      : await db.from(T).insert({ ...payload, company_id: cid }).select('id');
    if (res.error) { const f = fail(res.error, 'save'); if (f.field) showErrors({ [f.field]: f.text }); return; }
    if (editing && !res.data.length) return toast('You do not have permission to change this record.', false);
    $('dlg').close(); toast(`✓ ${C.singular} ${editing ? 'updated' : 'added'} successfully`);
    if (!editing) { page = 0; }
    load();
  } catch (x) { fail(x, 'save'); } finally { btn.disabled = false; btn.textContent = label; }
}

// ---------- View / (de)activate ----------
function openView(r) {
  $('vt').textContent = r[NAME];
  const row = (k, v) => `<dt>${k}</dt><dd>${v ? esc(v) : '—'}</dd>`;
  $('vbody').innerHTML = row('Phone', r.phone) + row('Email', r.email) + row('GST number', r.gst_number) + row('Address', r.address) + row('City', r.city) + row('State', r.state) + row('Pincode', r.pincode)
    + `<dt>Opening balance</dt><dd>${money(r.opening_balance)}${Number(r.opening_balance) > 0 ? ' · ' + esc(C.balanceOption[r.balance_type]) : ''}</dd>`
    + row('Notes', r.notes) + `<dt>Status</dt><dd>${r.is_active ? 'Active' : 'Inactive'}</dd>` + row('Added on', new Date(r.created_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }));
  $('vdlg').showModal();
}
async function setActive(r, on) {
  const res = await db.from(T).update({ is_active: on }).eq('id', r.id).eq('company_id', cid).select('id');
  if (res.error) return fail(res.error, 'status');
  if (!res.data.length) return toast('You do not have permission to change this record.', false);
  toast(on ? `${C.singular} activated` : `${C.singular} deactivated`); load();
}

// ---------- Wiring ----------
function wire() {
  $('q').oninput = () => { clearTimeout(timer); timer = setTimeout(() => { page = 0; load(); }, 300); };
  $('fs').onchange = () => { page = 0; load(); };
  $('prev').onclick = () => { page--; load(); }; $('next').onclick = () => { page++; load(); };
  $('add').onclick = () => openForm(null);
  $('cancel').onclick = () => $('dlg').close(); $('vclose').onclick = () => $('vdlg').close();
  $('f').onsubmit = save;
  $('state').onclick = e => { if (e.target.id === 'retry') load(); if (e.target.id === 'empty-add') openForm(null); };
  $('rows').onclick = e => {
    const b = e.target.closest('button[data-act]'); if (!b) return;
    const r = rows.find(x => x.id === b.dataset.id); if (!r) return;
    if (b.dataset.act === 'view') openView(r);
    else if (!canWrite()) return;
    else if (b.dataset.act === 'edit') openForm(r);
    else if (b.dataset.act === 'on') setActive(r, true);
    else if (b.dataset.act === 'off') { pendingDeactivate = r; $('cmsg').textContent = `“${r[NAME]}” will be marked inactive. All their records are kept, and you can activate them again at any time.`; $('cdlg').showModal(); }
  };
  $('cno').onclick = () => { pendingDeactivate = null; $('cdlg').close(); };
  $('cyes').onclick = async () => { const r = pendingDeactivate; pendingDeactivate = null; $('cdlg').close(); if (r) await setActive(r, false); };
  $('out').onclick = async e => { e.preventDefault(); await db.auth.signOut(); location.replace('login.html'); };
  db.auth.onAuthStateChange(ev => { if (ev === 'SIGNED_OUT') location.replace('login.html'); }); // signed out in another tab / session ended
}

function init() { shell(); wire(); return boot(); }
async function boot() {
  $('state').innerHTML = ''; $('tw').hidden = false;
  $('rows').innerHTML = '<tr><td colspan="7"><div class="sk"></div></td></tr>'.repeat(3);
  // 1) verify session  2) resolve the user's company + role (same lookup as dashboard.html)  3) only then query company-scoped data
  const { data: { session } } = await db.auth.getSession();
  if (!session) return location.replace('login.html');
  const { data: m, error } = await db.from('company_members').select('company_id,role,companies(name)').eq('user_id', session.user.id).limit(1);
  if (error) {
    const f = fail(error, 'membership'); $('rows').innerHTML = '';
    return setState(`<div class="st"><h3>Unable to load ${C.plural.toLowerCase()}.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="retry-init">Try again</button></div>`);
  }
  if (!m.length) return location.replace('login.html');
  cid = m[0].company_id; role = m[0].role;
  $('who').textContent = `${m[0].companies?.name || ''} · ${role}`;
  $('add').hidden = !canWrite();
  load();
}
document.addEventListener('click', e => { if (e.target.id === 'retry-init') boot().catch(x => fail(x, 'retry')); });
init().catch(e => { console.error(e); toast('Something went wrong. Please refresh the page.', false); });
})();
