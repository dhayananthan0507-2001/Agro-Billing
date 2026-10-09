// Expenses page (Phase 6). Reuses auth.js's single Supabase client (client()).
// Owner/manager only (the database also hides expenses from cashiers). Expenses are never deleted: cancelling sets status 'cancelled',
// and the database records who/when and refuses any later change. company_id and created_by come from the signed-in user, not the form.
(() => {
const db = client();
const PAGE = 25;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = v => '₹' + Number(v || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const pad = n => String(n).padStart(2, '0');
const iso = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const today = () => iso(new Date());
const fdate = s => s ? new Date(s + 'T00:00:00').toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '—';
const PM = { cash: 'Cash', upi: 'UPI', card: 'Card', bank_transfer: 'Bank transfer', other: 'Other' };

let cid, role, page = 0, total = 0, reqId = 0, timer, rows = [], names = {}, cats = [], editing = null, busy = false;
const canWrite = () => role === 'owner' || role === 'manager';
const toast = (t, ok = true) => { const e = $('toast'); e.textContent = t; e.style.background = ok ? '#1f4d2b' : '#a32020'; e.style.display = 'block'; clearTimeout(toast.t); toast.t = setTimeout(() => e.style.display = 'none', 5000); };
const dec = (str, scale) => { const s = String(str ?? '').trim(); if (s === '') return 0n; if (!/^\d+(\.\d+)?$/.test(s)) return null; const [i, f = ''] = s.split('.'); if (f.length > scale) return null; return BigInt(i + f.padEnd(scale, '0')); };

const ERR = { INVALID_DATE: 'The expense date is not valid (it cannot be in the future).', CATEGORY_INACTIVE: 'That category is inactive or not available. Choose another.', EXPENSE_CANCELLED: 'This expense is cancelled and cannot be changed.', COMPANY_IMMUTABLE: 'This record cannot be moved to another shop.' };
function friendly(e) {
  const m = e?.message || '', low = (m + ' ' + (e?.details || '')).toLowerCase();
  if (ERR[m]) return { text: ERR[m] };
  if (/jwt|expired|not authenticated/.test(low) || e?.code === 'PGRST301') return { text: 'Your session has expired. Please sign in again.', auth: true };
  if (/failed to fetch|network|load failed/.test(low)) return { text: 'Network problem. Please check your connection and try again.' };
  if (e?.code === '42501') return { text: 'You do not have permission for this action. Only owners and managers can manage expenses.' };
  if (e?.code === '23505') return { text: 'A category with that name already exists.' };
  if (e?.code === '23514') return { text: 'Some values are not valid. Please check the form and try again.' };
  if (e?.code === '22P02') return { text: 'Some values are not valid numbers or dates.' };
  return { text: 'Something went wrong. Please try again.' };
}
function fail(e, ctx, prefix = '') {
  console.error('[expenses]', ctx, e);
  const f = friendly(e); toast((prefix ? prefix + ' ' : '') + f.text, false);
  if (f.auth) setTimeout(() => location.replace('login.html'), 1500);
  return f;
}

function shell() {
  $('app').innerHTML = `
  <div class="top"><div><h2>Expenses</h2><p class="sub">Record shop expenses such as rent, electricity, transport and labour. Cancelled expenses stay on record.</p><small id="who"></small></div>
    <div class="acts"><button id="add">+ Add Expense</button><button id="cats" class="ghost">Manage categories</button></div></div>
  <div class="cards s4" id="ecards" style="margin-top:14px"></div>
  <div class="bar">
    <input id="q" type="search" placeholder="Search description, reference or notes…" aria-label="Search expenses" autocomplete="off">
    <select id="fcat" aria-label="Category"><option value="">All categories</option></select>
    <select id="fdate" aria-label="Date range"><option value="">Any date</option><option value="today">Today</option><option value="week">This week</option><option value="month">This month</option><option value="custom">Custom range…</option></select>
    <input id="dfrom" type="date" aria-label="From date" hidden><input id="dto" type="date" aria-label="To date" hidden>
    <select id="fmeth" aria-label="Payment method"><option value="">Any method</option>${Object.entries(PM).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}</select>
    <select id="fst" aria-label="Status"><option value="active">Active</option><option value="cancelled">Cancelled</option><option value="">Any status</option></select>
  </div>
  <div class="tw" id="tw"><table><thead><tr><th>Date</th><th>Category</th><th>Description</th><th>Amount</th><th>Method</th><th>Created by</th><th>Status</th><th>Actions</th></tr></thead><tbody id="rows"></tbody></table></div>
  <div id="state"></div>
  <div class="pg"><button class="ghost" id="prev" aria-label="Previous page">‹</button><span id="pn"></span><button class="ghost" id="next" aria-label="Next page">›</button></div>

  <dialog id="dlg"><h2 id="dt"></h2><div id="derr" class="errbox" hidden></div><div class="g">
    <div><label for="xdate">Date *</label><input id="xdate" type="date" max="${today()}"></div>
    <div><label for="xcat">Category *</label><select id="xcat"></select></div>
    <div class="f"><label for="xdesc">Description *</label><input id="xdesc" maxlength="200" autocomplete="off" placeholder="e.g. Freight for fertiliser delivery"></div>
    <div><label for="xamt">Amount (₹) *</label><input id="xamt" inputmode="decimal" placeholder="0.00"></div>
    <div><label for="xpm">Payment method</label><select id="xpm">${Object.entries(PM).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}</select></div>
    <div><label for="xref">Reference no.</label><input id="xref" maxlength="100" autocomplete="off"></div>
    <div class="f"><label for="xnotes">Notes</label><textarea id="xnotes" rows="2" maxlength="500"></textarea></div>
  </div><div class="acts-row"><button type="button" class="ghost" id="xcancel">Cancel</button><button type="button" id="xsave">Save expense</button></div></dialog>

  <dialog id="catdlg"><h2>Expense categories</h2><p class="hint">Inactive categories stay on old expenses but cannot be used for new ones.</p><div id="catlist"></div>
    <div class="cat-row"><input id="newcat" maxlength="60" placeholder="New category name" autocomplete="off"><button type="button" id="addcat">Add</button></div>
    <div class="acts-row"><button type="button" class="ghost" id="catclose">Close</button></div></dialog>

  <dialog id="cdlg"><h2 id="ct"></h2><p id="cm"></p><textarea id="creason" rows="2" maxlength="500" placeholder="Reason (optional)" hidden></textarea>
    <div class="acts-row"><button type="button" class="ghost" id="cno">Go back</button><button type="button" id="cyes">Confirm</button></div></dialog>`;
}
function ask({ title, msg, ok = 'Confirm', danger = false, reason = false, back = 'Go back' }) {
  return new Promise(res => {
    const d = $('cdlg'); $('ct').textContent = title; $('cm').textContent = msg; $('creason').hidden = !reason; $('creason').value = ''; $('cno').textContent = back;
    const y = $('cyes'); y.textContent = ok; y.className = danger ? 'danger' : '';
    let done = false; const fin = v => { if (done) return; done = true; d.onclose = null; if (d.open) d.close(); res(v); };
    y.onclick = () => fin({ reason: $('creason').value.trim() }); $('cno').onclick = () => fin(null); d.onclose = () => fin(null);
    d.showModal();
  });
}
function setState(html) { $('state').innerHTML = html; $('tw').hidden = !!html; }

async function loadStats() {
  const day = today();
  const [f, s] = await Promise.all([db.rpc('finance_stats', { p_company: cid, p_date: day }), db.rpc('sale_stats', { p_company: cid, p_date: day })]);
  if (f.error) { console.warn('finance_stats unavailable', f.error); $('ecards').innerHTML = ''; return; }
  const net = s.error ? null : Number(s.data.today_total) - Number(f.data.today_expenses);
  $('ecards').innerHTML = [["Today's expenses", money(f.data.today_expenses), ''], ['This month', money(f.data.month_expenses), 'month to date'],
    ...(net === null ? [] : [['Net sales after expenses', money(net), "today's sales − today's expenses (not profit)"]])]
    .map(([k, v, h]) => `<div class="card"><small>${k}</small><b>${esc(v)}</b>${h ? `<span class="hint">${esc(h)}</span>` : ''}</div>`).join('');
}
async function loadCats() {
  const { data, error } = await db.from('expense_categories').select('id,name,is_active').eq('company_id', cid).order('name');
  if (error) { console.warn('categories', error); return; }
  cats = data;
  $('fcat').innerHTML = '<option value="">All categories</option>' + cats.map(c => `<option value="${c.id}">${esc(c.name)}${c.is_active ? '' : ' (inactive)'}</option>`).join('');
}

function dateRange() {
  const v = $('fdate').value, t = new Date();
  if (v === 'today') return [iso(t), iso(t)];
  if (v === 'week') { const d = new Date(t); d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); return [iso(d), iso(t)]; }
  if (v === 'month') return [iso(new Date(t.getFullYear(), t.getMonth(), 1)), iso(t)];
  if (v === 'custom') return [$('dfrom').value || null, $('dto').value || null];
  return [null, null];
}
async function load() {
  const my = ++reqId;
  $('state').innerHTML = ''; $('tw').hidden = false;
  $('rows').innerHTML = '<tr><td colspan="8"><div class="sk"></div></td></tr>'.repeat(4);
  let q = db.from('expenses').select('id,expense_date,category_id,description,amount,payment_method,reference_number,notes,status,cancel_reason,created_by,expense_categories(name)', { count: 'exact' }).eq('company_id', cid);
  const s = $('q').value.trim().replace(/[,()%\\*"]/g, ' ').replace(/\s+/g, ' ').trim();
  if (s) q = q.or(`description.ilike.%${s}%,reference_number.ilike.%${s}%,notes.ilike.%${s}%`);
  if ($('fcat').value) q = q.eq('category_id', $('fcat').value);
  if ($('fmeth').value) q = q.eq('payment_method', $('fmeth').value);
  if ($('fst').value) q = q.eq('status', $('fst').value);
  const [from, to] = dateRange(); if (from) q = q.gte('expense_date', from); if (to) q = q.lte('expense_date', to);
  const { data, count, error } = await q.order('expense_date', { ascending: false }).order('created_at', { ascending: false }).order('id').range(page * PAGE, page * PAGE + PAGE - 1);
  if (my !== reqId) return;
  if (error) {
    const f = fail(error, 'load'); $('rows').innerHTML = ''; $('pn').textContent = ''; $('prev').disabled = $('next').disabled = true;
    return setState(`<div class="st"><h3>Unable to load expenses.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="retry">Try again</button></div>`);
  }
  total = count || 0;
  if (!data.length && page > 0) { page = Math.max(0, Math.ceil(total / PAGE) - 1); return load(); }
  rows = data;
  const need = [...new Set(data.map(r => r.created_by).filter(u => u && !(u in names)))];
  if (need.length) { const r = await db.from('profiles').select('id,full_name').in('id', need); (r.data || []).forEach(p => { names[p.id] = p.full_name; }); need.forEach(u => { if (!(u in names)) names[u] = '—'; }); if (my !== reqId) return; }
  $('pn').textContent = total ? `${page * PAGE + 1}–${Math.min(total, (page + 1) * PAGE)} of ${total}` : '0';
  $('prev').disabled = page === 0; $('next').disabled = (page + 1) * PAGE >= total;
  if (!data.length) {
    $('rows').innerHTML = '';
    const filtered = s || $('fcat').value || $('fmeth').value || $('fdate').value || $('fst').value !== 'active';
    return setState(filtered ? '<div class="st"><h3>No expenses match your filters</h3><p>Try changing or clearing the filters.</p></div>'
      : '<div class="st"><h3>No expenses yet</h3><p>Add your first expense to start tracking what the shop spends.</p><button id="empty-add">+ Add Expense</button></div>');
  }
  $('rows').innerHTML = data.map(r => {
    const live = r.status === 'active';
    return `<tr><td>${fdate(r.expense_date)}</td><td>${esc(r.expense_categories?.name || '—')}</td><td>${esc(r.description)}${r.reference_number ? `<span class="sub2">Ref: ${esc(r.reference_number)}</span>` : ''}${r.notes ? `<span class="sub2">${esc(r.notes)}</span>` : ''}</td>
      <td class="amt">${money(r.amount)}</td><td>${esc(PM[r.payment_method] || r.payment_method)}</td><td>${esc(names[r.created_by] || '—')}</td>
      <td><span class="b ${live ? 'in' : 'out'}">${live ? 'Active' : 'Cancelled'}</span>${r.cancel_reason ? `<span class="sub2">${esc(r.cancel_reason)}</span>` : ''}</td>
      <td>${live ? `<div class="acts"><button class="ghost" data-act="edit" data-id="${r.id}">Edit</button><button class="ghost" data-act="cancel" data-id="${r.id}">Cancel</button></div>` : ''}</td></tr>`;
  }).join('');
}

// ---------- add / edit ----------
function openForm(rec) {
  editing = rec || null;
  $('dt').textContent = rec ? 'Edit expense' : 'Add expense'; $('derr').hidden = true;
  const usable = cats.filter(c => c.is_active || c.id === rec?.category_id);
  $('xcat').innerHTML = '<option value="">Select category</option>' + usable.map(c => `<option value="${c.id}">${esc(c.name)}${c.is_active ? '' : ' (inactive)'}</option>`).join('');
  $('xdate').value = rec?.expense_date || today(); $('xcat').value = rec?.category_id || ''; $('xdesc').value = rec?.description || ''; $('xamt').value = rec ? rec.amount : '';
  $('xpm').value = rec?.payment_method || 'cash'; $('xref').value = rec?.reference_number || ''; $('xnotes').value = rec?.notes || '';
  $('dlg').showModal(); $('xdesc').focus();
}
function validate() {
  const errs = [], d = $('xdate').value, a = dec($('xamt').value, 2);
  if (!d || isNaN(Date.parse(d))) errs.push('Enter a valid date.'); else if (d > today()) errs.push('The date cannot be in the future.');
  if (!$('xcat').value) errs.push('Choose a category.');
  if (!$('xdesc').value.trim()) errs.push('Enter a description.');
  if (a === null) errs.push('Enter a valid amount (up to 2 decimals).'); else if (a <= 0n) errs.push('Amount must be greater than 0.');
  const box = $('derr'); box.hidden = !errs.length; box.innerHTML = errs.length ? `<ul>${errs.map(e => `<li>${esc(e)}</li>`).join('')}</ul>` : '';
  return errs;
}
async function save() {
  if (busy || !canWrite() || validate().length) return;
  const body = { expense_date: $('xdate').value, category_id: $('xcat').value, description: $('xdesc').value.trim(), amount: $('xamt').value.trim(), payment_method: $('xpm').value,
    reference_number: $('xref').value.trim() || null, notes: $('xnotes').value.trim() || null };
  busy = true; $('xsave').disabled = true;
  try {
    // company_id only on insert and only from the signed-in user's membership; created_by is filled in by the database
    const res = editing ? await db.from('expenses').update(body).eq('id', editing.id).eq('company_id', cid).select('id') : await db.from('expenses').insert({ ...body, company_id: cid }).select('id');
    if (res.error) { const f = fail(res.error, 'save'); $('derr').hidden = false; $('derr').textContent = f.text; return; }
    if (editing && !res.data.length) { toast('You do not have permission to change this expense.', false); return; }
    $('dlg').close(); toast(editing ? '✓ Expense updated' : '✓ Expense added'); if (!editing) page = 0; load(); loadStats();
  } catch (e) { fail(e, 'save'); } finally { busy = false; $('xsave').disabled = false; }
}
async function cancelExpense(id) {
  const r = rows.find(x => x.id === id); if (!r || busy) return;
  const a = await ask({ title: 'Cancel this expense?', msg: `${money(r.amount)} — ${r.description}. It stays in the list marked as cancelled and stops counting in totals. This cannot be undone.`, ok: 'Cancel expense', back: 'Keep expense', danger: true, reason: true });
  if (!a) return;
  busy = true;
  try {
    const res = await db.from('expenses').update({ status: 'cancelled', cancel_reason: a.reason || null }).eq('id', id).eq('company_id', cid).select('id');
    if (res.error) { fail(res.error, 'cancel', 'Expense was not cancelled.'); return; }
    if (!res.data.length) { toast('You do not have permission to cancel this expense.', false); return; }
    toast('Expense cancelled.'); load(); loadStats();
  } catch (e) { fail(e, 'cancel', 'Expense was not cancelled.'); } finally { busy = false; }
}

// ---------- categories ----------
function renderCats() {
  $('catlist').innerHTML = cats.map(c => `<div class="cat-row"><input data-cid="${c.id}" value="${esc(c.name)}" maxlength="60" aria-label="Category name"><button type="button" class="ghost" data-rename="${c.id}">Rename</button>
    <button type="button" class="ghost" data-toggle="${c.id}">${c.is_active ? 'Deactivate' : 'Activate'}</button></div>`).join('');
}
async function catWrite(promise, okMsg) {
  const res = await promise;
  if (res.error) { fail(res.error, 'category'); return false; }
  if (res.data && !res.data.length) { toast('You do not have permission to change categories.', false); return false; }
  toast(okMsg); await loadCats(); renderCats(); return true;
}

function wire() {
  const reload = () => { page = 0; load(); };
  $('q').oninput = () => { clearTimeout(timer); timer = setTimeout(reload, 300); };
  ['fcat', 'fmeth', 'fst', 'dfrom', 'dto'].forEach(i => $(i).onchange = reload);
  $('fdate').onchange = () => { const c = $('fdate').value === 'custom'; $('dfrom').hidden = $('dto').hidden = !c; reload(); };
  $('prev').onclick = () => { page--; load(); }; $('next').onclick = () => { page++; load(); };
  $('add').onclick = () => openForm(null);
  $('cats').onclick = () => { renderCats(); $('catdlg').showModal(); };
  $('state').onclick = e => { if (e.target.id === 'retry') load(); if (e.target.id === 'empty-add') openForm(null); };
  $('rows').onclick = e => { const b = e.target.closest('button[data-act]'); if (!b) return; const r = rows.find(x => x.id === b.dataset.id); if (b.dataset.act === 'edit' && r) openForm(r); else if (b.dataset.act === 'cancel') cancelExpense(b.dataset.id); };
  $('xcancel').onclick = () => $('dlg').close(); $('xsave').onclick = save;
  $('catclose').onclick = () => $('catdlg').close();
  $('addcat').onclick = async () => { const n = $('newcat').value.trim(); if (!n) return toast('Enter a category name.', false); if (await catWrite(db.from('expense_categories').insert({ company_id: cid, name: n }).select('id'), 'Category added')) $('newcat').value = ''; };
  $('catlist').onclick = e => {
    const rn = e.target.closest('[data-rename]'), tg = e.target.closest('[data-toggle]');
    if (rn) { const id = rn.dataset.rename, n = document.querySelector(`#catlist input[data-cid="${id}"]`).value.trim(); if (!n) return toast('Enter a category name.', false); catWrite(db.from('expense_categories').update({ name: n }).eq('id', id).eq('company_id', cid).select('id'), 'Category renamed'); }
    if (tg) { const c = cats.find(x => x.id === tg.dataset.toggle); catWrite(db.from('expense_categories').update({ is_active: !c.is_active }).eq('id', c.id).eq('company_id', cid).select('id'), c.is_active ? 'Category deactivated' : 'Category activated'); }
  };
  $('out').onclick = async e => { e.preventDefault(); await db.auth.signOut(); location.replace('login.html'); };
  db.auth.onAuthStateChange(evt => { if (evt === 'SIGNED_OUT') location.replace('login.html'); });
}

function init() { shell(); wire(); return boot(); }
async function boot() {
  $('state').innerHTML = ''; $('tw').hidden = false;
  $('rows').innerHTML = '<tr><td colspan="8"><div class="sk"></div></td></tr>'.repeat(3);
  const { data: { session } } = await db.auth.getSession();
  if (!session) return location.replace('login.html');
  const { data: m, error } = await db.from('company_members').select('company_id,role,companies(name)').eq('user_id', session.user.id).limit(1);
  if (error) {
    const f = fail(error, 'membership'); $('rows').innerHTML = '';
    return setState(`<div class="st"><h3>Unable to load expenses.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="retry-init">Try again</button></div>`);
  }
  if (!m.length) return location.replace('login.html');
  cid = m[0].company_id; role = m[0].role;
  $('who').textContent = `${m[0].companies?.name || ''} · ${role}`;
  if (!canWrite()) { $('app').innerHTML = '<div class="st" style="margin-top:20px"><h3>Expenses are for owners and managers</h3><p>Ask the shop owner if you need access to expense records.</p></div>'; return; }
  await Promise.all([loadCats(), load(), loadStats()]);
}
document.addEventListener('click', e => { if (e.target.id === 'retry-init') boot().catch(x => fail(x, 'retry')); });
init().catch(e => { console.error(e); toast('Something went wrong. Please refresh the page.', false); });
})();
