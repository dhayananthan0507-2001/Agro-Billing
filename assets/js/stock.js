// Stock page (Phase 7): movement history, stock adjustments / write-offs, expiry + low-stock alerts.
// STEP 1 SHIPS THE HISTORY VIEW ONLY: stock.html sets window.STOCK_TABS = ['hist'], so the Adjust and Alerts tabs are hidden and cannot be opened.
// Later steps simply remove that setting. History only READS existing tables under their existing RLS and calls no database function.
(() => {
const db = client(), T = Tools, { esc, money, num, fdate, fdt } = T, $$ = id => document.getElementById(id);
const PAGE = 25;
const TYPES = { opening: ['Opening stock', 'arc'], purchase: ['Purchase', 'in'], purchase_return: ['Purchase cancelled / returned', 'low'], sale: ['Sale', 'in'], sale_return: ['Sale cancelled / returned', 'low'], adjustment: ['Adjustment', 'low'], damage: ['Write-off / damage', 'out'] };
const REASONS = ['Count correction', 'Damaged', 'Expired', 'Spillage / loss', 'Sample / gift', 'Other'];
const ENABLED = window.STOCK_TABS || ['hist', 'adj', 'alerts'];   // which tabs exist; Step 1 = History only
let cid, role, tab = 'hist', page = 0, total = 0, reqId = 0, timer, prod = null, names = {}, bnames = {}, searchSeq = 0, adj = null, alerts = null, rows = [], busy = false;
const canAdj = () => role === 'owner' || role === 'manager', isOwner = () => role === 'owner';

const ERR = {
  NOT_ALLOWED: 'You do not have permission for this action. Only owners and managers can adjust stock.', INVALID_QUANTITY: 'Quantity must be more than 0 (up to 3 decimals).', INVALID_TYPE: 'Choose what kind of adjustment this is.',
  REASON_REQUIRED: 'A reason is required (at least 3 characters).', REASON_TOO_LONG: 'The reason is too long (max 300 characters).', BATCH_NOT_FOUND: 'That batch was not found for this product.',
  INVENTORY_ROW_MISSING: 'This product has no stock record, so it cannot be adjusted. Please contact support.', BATCH_EXPIRED: 'This batch has expired, so stock cannot be added to it. You can still write it off.',
  INSUFFICIENT_STOCK: 'There is not enough stock in this batch for that.'
};
function friendly(e) {
  const m = e?.message || '', low = (m + ' ' + (e?.details || '')).toLowerCase();
  if (ERR[m]) return { text: ERR[m] };
  if (/jwt|expired|not authenticated/.test(low) || e?.code === 'PGRST301') return { text: 'Your session has expired. Please sign in again.', auth: true };
  if (/failed to fetch|network|load failed/.test(low)) return { text: 'Network problem. Please check your connection and try again.' };
  if (e?.code === '23505') return { text: 'This adjustment was already saved.', dup: true };
  if (e?.code === '40P01' || e?.code === '40001') return { text: 'Another change was happening at the same moment. Please try again.' };
  return { text: 'Something went wrong. Please try again.' };
}
function fail(e, ctx, prefix = '') {
  console.error('[stock]', ctx, e);
  const f = friendly(e); T.toast((prefix ? prefix + ' ' : '') + f.text, false);
  if (f.auth) setTimeout(() => location.replace('login.html'), 1500);
  return f;
}

function shell() {
  $$('app').innerHTML = `
  <div class="top"><div><h2>Stock</h2><p class="sub">See every stock movement, correct or write off stock, and watch expiry dates and low stock.</p><small id="who"></small></div></div>
  <div class="tabs" role="tablist"><button data-tab="hist" class="on">History</button><button data-tab="adj" id="tabadj">Adjust stock</button><button data-tab="alerts">Expiry &amp; low stock</button></div>

  <section id="s-hist">
    <div class="bar" style="margin-top:14px">
      <div id="pfwrap" style="min-width:230px"><input id="hp" placeholder="Filter by product…" autocomplete="off" aria-label="Filter by product"></div>
      <select id="htype" aria-label="Movement type"><option value="">All movement types</option>${Object.entries(TYPES).map(([k, v]) => `<option value="${k}">${v[0]}</option>`).join('')}</select>
      <select id="hdate" aria-label="Date range">${T.presetOptions('')}</select>
      <input id="hfrom" type="date" aria-label="From date" hidden><input id="hto" type="date" aria-label="To date" hidden>
      <input id="hq" type="search" placeholder="Search reference or reason…" aria-label="Search" autocomplete="off">
      <button class="ghost" id="hcsv">Export CSV</button>
    </div>
    <div class="tw" id="htw"><table><thead><tr><th>Date &amp; time</th><th>Product</th><th>Batch</th><th>Type</th><th class="rt">Change</th><th class="rt">Stock after</th><th>Reference</th><th>Reason / note</th><th>By</th></tr></thead><tbody id="hrows"></tbody></table></div>
    <div id="hstate"></div>
    <div class="pg"><button class="ghost" id="hprev" aria-label="Previous page">‹</button><span id="hpn"></span><button class="ghost" id="hnext" aria-label="Next page">›</button></div>
  </section>

  <section id="s-adj" hidden></section>
  <section id="s-alerts" hidden></section>

  <dialog id="cdlg"><h2 id="ct"></h2><p id="cm"></p><div class="acts-row"><button type="button" class="ghost" id="cno">Go back</button><button type="button" id="cyes">Confirm</button></div></dialog>`;
}
function setTab(t) {
  if (!ENABLED.includes(t)) return;      // a tab that is switched off can never be opened (not even from the browser console)
  tab = t; PopList.hide();
  document.querySelectorAll('.tabs button').forEach(b => b.classList.toggle('on', b.dataset.tab === t));
  $$('s-hist').hidden = t !== 'hist'; $$('s-adj').hidden = t !== 'adj'; $$('s-alerts').hidden = t !== 'alerts';
  if (t === 'adj') renderAdj(); if (t === 'alerts') loadAlerts();
}

// ---------- History ----------
function histQuery(q) {
  if (prod) q = q.eq('product_id', prod.id);
  if ($$('htype').value) q = q.eq('movement_type', $$('htype').value);
  const [from, to] = T.range($$('hdate').value, $$('hfrom').value, $$('hto').value);
  if (from) q = q.gte('created_at', new Date(from + 'T00:00:00').toISOString());
  if (to) q = q.lt('created_at', new Date(new Date(to + 'T00:00:00').getTime() + 86400000).toISOString());
  const s = $$('hq').value.trim().replace(/[,()%\\*"]/g, ' ').replace(/\s+/g, ' ').trim();
  if (s) q = q.or(`reference_id.ilike.%${s}%,notes.ilike.%${s}%`);
  return q;
}
const SEL = 'id,product_id,batch_id,movement_type,quantity,previous_quantity,new_quantity,reference_type,reference_id,notes,created_by,created_at,products(product_name,unit)';
async function enrich(data) {
  const bs = [...new Set(data.map(r => r.batch_id).filter(b => b && !(b in bnames)))], us = [...new Set(data.map(r => r.created_by).filter(u => u && !(u in names)))];
  const [b, u] = await Promise.all([bs.length ? db.from('product_batches').select('id,batch_number').in('id', bs) : { data: [] }, us.length ? db.from('profiles').select('id,full_name').in('id', us) : { data: [] }]);
  (b.data || []).forEach(x => { bnames[x.id] = x.batch_number; }); (u.data || []).forEach(x => { names[x.id] = x.full_name; }); us.forEach(x => { if (!(x in names)) names[x] = '—'; });
}
function histRow(r) {
  const t = TYPES[r.movement_type] || [r.movement_type, 'arc'], q = Number(r.quantity), ref = ['purchase', 'sale'].includes(r.reference_type) ? r.reference_id : '';
  return [r.created_at, r.products?.product_name || '—', bnames[r.batch_id] || '—', t[0], q, r.new_quantity, ref || '', r.notes || '', names[r.created_by] || '—', r.products?.unit || '', t[1]];
}
async function loadHist() {
  const my = ++reqId;
  $$('hstate').innerHTML = ''; $$('htw').hidden = false;
  $$('hrows').innerHTML = '<tr><td colspan="9"><div class="sk"></div></td></tr>'.repeat(4);
  const { data, count, error } = await histQuery(db.from('inventory_movements').select(SEL, { count: 'exact' }).eq('company_id', cid)).order('created_at', { ascending: false }).order('id', { ascending: false }).range(page * PAGE, page * PAGE + PAGE - 1);
  if (my !== reqId) return;
  if (error) {
    const f = fail(error, 'history'); $$('hrows').innerHTML = ''; $$('hpn').textContent = ''; $$('hprev').disabled = $$('hnext').disabled = true; $$('htw').hidden = true;
    return void ($$('hstate').innerHTML = `<div class="st"><h3>Unable to load stock history.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="hretry">Try again</button></div>`);
  }
  total = count || 0;
  if (!data.length && page > 0) { page = Math.max(0, Math.ceil(total / PAGE) - 1); return loadHist(); }
  await enrich(data); if (my !== reqId) return;
  rows = data;
  $$('hpn').textContent = total ? `${page * PAGE + 1}–${Math.min(total, (page + 1) * PAGE)} of ${total}` : '0';
  $$('hprev').disabled = page === 0; $$('hnext').disabled = (page + 1) * PAGE >= total;
  if (!data.length) { $$('hrows').innerHTML = ''; $$('htw').hidden = true; const f = prod || $$('htype').value || $$('hdate').value || $$('hq').value.trim();
    return void ($$('hstate').innerHTML = f ? '<div class="st"><h3>No movements match your filters</h3><p>Try changing or clearing the filters.</p></div>' : '<div class="st"><h3>No stock movements yet</h3><p>Purchases, sales and adjustments will appear here.</p></div>'); }
  $$('hrows').innerHTML = data.map(r => { const [dt, pn, bn, tl, q, after, ref, note, by, unit, cls] = histRow(r);
    return `<tr><td>${fdt(dt)}</td><td>${esc(pn)}</td><td>${esc(bn)}</td><td><span class="b ${cls}">${esc(tl)}</span></td><td class="rt ${q >= 0 ? 'up' : 'down'}">${q >= 0 ? '+' : '−'}${num(Math.abs(q))} ${esc(unit)}</td><td class="rt">${num(after)} ${esc(unit)}</td><td>${esc(ref || '—')}</td><td style="white-space:normal;min-width:160px">${esc(note || '—')}</td><td>${esc(by)}</td></tr>`; }).join('');
}
async function exportHist() {
  const { data, error } = await histQuery(db.from('inventory_movements').select(SEL).eq('company_id', cid)).order('created_at', { ascending: false }).order('id', { ascending: false }).range(0, 1999);
  if (error) return void fail(error, 'export');
  await enrich(data);
  T.csv('stock-history.csv', ['Date time', 'Product', 'Batch', 'Type', 'Change', 'Unit', 'Stock after', 'Reference', 'Reason', 'By'], data.map(r => { const [dt, pn, bn, tl, q, after, ref, note, by, unit] = histRow(r); return [new Date(dt).toLocaleString('en-IN'), pn, bn, tl, q, unit, after, ref, note, by]; }));
  if (data.length === 2000) T.toast('Exported the newest 2,000 movements. Narrow the dates to export older ones.', false);
}

// ---------- product picker (shared by history filter and the adjust form) ----------
async function pickProduct(input, onPick, activeOnly) {
  const s = input.value.trim().replace(/[,()%\\*"]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!s) { PopList.hide(); return; }
  const my = ++searchSeq;
  let q = db.from('products').select('id,product_name,sku,product_code,unit,is_active').eq('company_id', cid).or(`product_name.ilike.%${s}%,sku.ilike.%${s}%,product_code.ilike.%${s}%`).order('product_name').limit(10);
  if (activeOnly) q = q.eq('is_active', true);
  const { data, error } = await q;
  if (my !== searchSeq || !input.isConnected) return;
  if (error) { console.warn(error); PopList.show(input, '<div class="none">Search failed. Try again.</div>', null); return; }
  PopList.show(input, data.length ? data.map((p, i) => `<button type="button" data-i="${i}"><b>${esc(p.product_name)}</b><span class="hint">${esc([p.sku || p.product_code, p.unit, p.is_active ? '' : 'archived'].filter(Boolean).join(' · '))}</span></button>`).join('') : '<div class="none">No product found.</div>', i => onPick(data[i]));
}
function renderProdChip() {
  $$('pfwrap').innerHTML = prod ? `<span class="chip"><b>${esc(prod.product_name)}</b><button class="ghost" id="pclear" aria-label="Clear product filter">✕</button></span>` : '<input id="hp" placeholder="Filter by product…" autocomplete="off" aria-label="Filter by product">';
}

// ---------- Adjust stock (later step: switched off in Step 1, see ENABLED) ----------
const unitOf = () => adj?.product?.unit || '';
async function selectAdjProduct(p) {
  adj = { ...(adj || {}), product: p, batches: [], batch: '', total: null };
  renderAdj();
  const [b, i] = await Promise.all([db.from('product_batches').select('id,batch_number,quantity,expiry_date').eq('company_id', cid).eq('product_id', p.id).order('expiry_date', { ascending: true, nullsFirst: false }).order('batch_number'),
    db.from('inventory').select('quantity').eq('company_id', cid).eq('product_id', p.id).maybeSingle()]);
  if (adj?.product?.id !== p.id) return;
  if (b.error) return void fail(b.error, 'batches');
  adj.batches = b.data; adj.total = i.data ? Number(i.data.quantity) : null; if (adj.pre) { adj.batch = adj.pre.batch; } renderAdj();
  if (adj.pre) { const pre = adj.pre; adj.pre = null; $$('akind').value = pre.kind; $$('aqty').value = pre.qty; $$('areason').value = pre.reason; onAdjChange(); }
}
function isExpired(b) { return b.expiry_date && b.expiry_date < T.today(); }
function renderAdj() {
  const el = $$('s-adj');
  if (!canAdj()) { el.innerHTML = '<div class="st" style="margin-top:20px"><h3>Stock adjustments are for owners and managers</h3><p>Ask the shop owner or a manager to correct or write off stock.</p></div>'; return; }
  const keep = adj ? { kind: $$('akind')?.value, qty: $$('aqty')?.value, reason: $$('areason')?.value, note: $$('anote')?.value, batch: $$('abatch')?.value } : {};
  const p = adj?.product;
  el.innerHTML = `<div id="aerr" class="errbox" hidden></div>
    <div class="card2"><div class="g">
      <div class="f"><label for="ap">Product</label>${p ? `<div class="chip"><b>${esc(p.product_name)}</b>${adj.total !== null ? `<span class="hint">In stock: ${num(adj.total)} ${esc(p.unit)}</span>` : ''}<button class="ghost" id="aclear" aria-label="Change product">Change</button></div>` : '<input id="ap" placeholder="Search product, SKU or code…" autocomplete="off">'}</div>
      <div class="f"><label for="abatch">Batch</label><select id="abatch" ${p ? '' : 'disabled'}><option value="">${p ? (adj.batches.length ? 'Select batch' : 'Loading batches…') : 'Choose a product first'}</option>
        ${(adj?.batches || []).map(b => `<option value="${b.id}">${esc(b.batch_number)} · ${num(b.quantity)} ${esc(p.unit)}${b.expiry_date ? ' · exp ' + fdate(b.expiry_date) : ''}${isExpired(b) ? ' · EXPIRED' : ''}</option>`).join('')}</select></div>
      <div><label for="akind">What are you doing?</label><select id="akind"><option value="decrease">Remove stock (−) — count correction, loss, sample</option><option value="damage">Write off damaged / expired stock (−)</option><option value="increase">Add stock (+) — count correction</option></select></div>
      <div><label for="aqty">Quantity ${p ? '(' + esc(p.unit) + ')' : ''}</label><input id="aqty" inputmode="decimal" placeholder="0"></div>
      <div><label for="areason">Reason *</label><select id="areason">${REASONS.map(r => `<option>${r}</option>`).join('')}</select></div>
      <div><label for="anote">Note <span class="hint">(required for “Other”)</span></label><input id="anote" maxlength="250" autocomplete="off"></div>
    </div><small class="hint" id="ahint"></small></div>
    <div class="acts-row"><button id="asave" type="button" ${p ? '' : 'disabled'}>Save adjustment</button></div>`;
  if (keep.kind) { $$('akind').value = keep.kind; $$('aqty').value = keep.qty; $$('areason').value = keep.reason; $$('anote').value = keep.note; if (keep.batch) $$('abatch').value = keep.batch; }
  if (adj?.batch && !keep.batch) $$('abatch').value = adj.batch;
  onAdjChange();
}
function onAdjChange() {
  const b = adj?.batches.find(x => x.id === $$('abatch')?.value), k = $$('akind')?.value, h = $$('ahint'); if (!h) return;
  h.textContent = !b ? '' : isExpired(b) && k === 'increase' ? 'This batch has expired: stock cannot be added to it. Choose “Write off” to remove it.' : k === 'increase' ? `Batch now holds ${num(b.quantity)} ${unitOf()}.` : `Batch holds ${num(b.quantity)} ${unitOf()}; you can remove up to that.`;
  if (k === 'damage' && b && $$('areason').value === 'Count correction') $$('areason').value = isExpired(b) ? 'Expired' : 'Damaged';
}
function adjValidate() {
  const errs = [], b = adj?.batches.find(x => x.id === $$('abatch').value), k = $$('akind').value, q = T.dec($$('aqty').value, 3), r = $$('areason').value, note = $$('anote').value.trim();
  if (!adj?.product) errs.push('Choose a product.'); if (!b) errs.push('Choose a batch.');
  if (q === null) errs.push('Enter a valid quantity (up to 3 decimals).'); else if (q <= 0n) errs.push('Quantity must be more than 0.');
  if (b && q && q > 0n) { if (k === 'increase' && isExpired(b)) errs.push('This batch has expired, so stock cannot be added to it.'); if (k !== 'increase' && Number($$('aqty').value) > Number(b.quantity)) errs.push(`The batch only holds ${num(b.quantity)} ${unitOf()}.`); }
  if (r === 'Other' && note.length < 3) errs.push('Please type a short note for “Other”.');
  const box = $$('aerr'); box.hidden = !errs.length; box.innerHTML = errs.length ? `<b>Please fix the following:</b><ul>${errs.map(e => `<li>${esc(e)}</li>`).join('')}</ul>` : '';
  return errs;
}
async function saveAdj() {
  if (busy || !canAdj() || adjValidate().length) return;
  const b = adj.batches.find(x => x.id === $$('abatch').value), k = $$('akind').value, qty = $$('aqty').value.trim(), notes = ($$('areason').value + ($$('anote').value.trim() ? ': ' + $$('anote').value.trim() : '')).slice(0, 300);
  const verb = k === 'increase' ? `Add ${num(qty)} ${unitOf()} to` : k === 'damage' ? `Write off ${num(qty)} ${unitOf()} from` : `Remove ${num(qty)} ${unitOf()} from`;
  if (!await T.ask({ title: 'Save this stock change?', msg: `${verb} ${adj.product.product_name}, batch ${b.batch_number}. Reason: ${notes}. This is recorded in the stock history and cannot be undone except by another adjustment.`, ok: 'Save adjustment', danger: k !== 'increase' })) return;
  busy = true; $$('asave').disabled = true;
  try {
    const res = await db.rpc('adjust_stock', { p_product: adj.product.id, p_batch: b.id, p_kind: k, p_qty: qty, p_notes: notes, p_request: adj.req });
    if (res.error) { const f = fail(res.error, 'adjust', 'Stock was not changed.'); if (f.dup) { adj = null; renderAdj(); } return; }
    T.toast(`Stock updated. ${adj.product.product_name} now has ${num(res.data)} ${unitOf()} in total.`);
    adj = null; renderAdj(); page = 0; loadHist();
  } catch (e) { fail(e, 'adjust', 'Stock was not changed.'); } finally { busy = false; const s = $$('asave'); if (s) s.disabled = !adj?.product; }
}
function startWriteOff(item) {      // from the Expired list
  adj = { product: { id: item.product_id, product_name: item.product_name, unit: item.unit }, batches: [], batch: item.batch_id, pre: { batch: item.batch_id, kind: 'damage', qty: String(Number(item.quantity)), reason: 'Expired' }, req: T.uuid() };
  setTab('adj'); selectAdjProduct(adj.product);
}

// ---------- Alerts (later step: switched off in Step 1, see ENABLED) ----------
async function loadAlerts() {
  const el = $$('s-alerts'); el.innerHTML = '<div class="sk" style="margin-top:14px"></div>';
  const { data, error } = await db.rpc('stock_alerts', { p_company: cid, p_limit: 200 });
  if (error) { const f = fail(error, 'alerts'); el.innerHTML = `<div class="st"><h3>Unable to load alerts.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="aretry">Try again</button></div>`; return; }
  alerts = data; const c = data.counts, cost = data.show_cost;
  const batchTable = (title, list, cls, writeoff) => `<div class="sec"><h3>${title} <span class="b ${cls}">${list.length}</span></h3>${list.length ? `<div class="tw"><table><thead><tr><th>Product</th><th>Batch</th><th>Expiry</th><th class="rt">Days</th><th class="rt">Quantity</th>${cost ? '<th class="rt">Cost value</th>' : ''}<th></th></tr></thead><tbody>
    ${list.map((x, i) => `<tr><td><b>${esc(x.product_name)}</b></td><td>${esc(x.batch_number)}</td><td>${fdate(x.expiry_date)}</td><td class="rt ${x.days < 0 ? 'down' : ''}">${x.days < 0 ? 'expired ' + (-x.days) + ' d ago' : x.days === 0 ? 'today' : x.days + ' d'}</td><td class="rt">${num(x.quantity)} ${esc(x.unit)}</td>${cost ? `<td class="rt">${Number(x.cost) > 0 ? money(x.value) : '<span class="hint">cost not recorded</span>'}</td>` : ''}
      <td>${writeoff && canAdj() ? `<button class="ghost" data-wo="${i}">Write off</button>` : ''}</td></tr>`).join('')}</tbody></table></div>
    ${cost && list.some(x => !(Number(x.cost) > 0)) ? '<p class="hint">Batches with no recorded cost are not given a value.</p>' : ''}` : '<p class="hint">None.</p>'}</div>`;
  const prodTable = (title, list, cls, low) => `<div class="sec"><h3>${title} <span class="b ${cls}">${list.length}</span></h3>${list.length ? `<div class="tw"><table><thead><tr><th>Product</th>${low ? '<th class="rt">In stock</th><th class="rt">Alert level</th>' : ''}</tr></thead><tbody>
    ${list.map(x => `<tr><td><b>${esc(x.product_name)}</b></td>${low ? `<td class="rt">${num(x.quantity)} ${esc(x.unit)}</td><td class="rt">${num(x.threshold)} ${esc(x.unit)} <span class="hint">${x.uses_default ? '(shop default)' : '(product minimum)'}</span></td>` : ''}</tr>`).join('')}</tbody></table></div>` : '<p class="hint">None.</p>'}</div>`;
  const known = l => l.reduce((a, x) => a + (Number(x.cost) > 0 ? Number(x.value) : 0), 0);
  el.innerHTML = `<div class="cards s5" style="margin-top:14px">${[['Expired batches', c.expired], ['Expiring within ' + data.expiry_days + ' days', c.expiring_soon], ['Low stock', c.low], ['Out of stock', c.out]].map(([k, v]) => `<div class="card"><small>${k}</small><b>${v}</b></div>`).join('')}
      ${cost ? `<div class="card"><small>Expired + expiring (known cost)</small><b>${money(known(data.expired) + known(data.expiring_soon))}</b></div>` : ''}</div>
    ${batchTable('Expired stock', data.expired, 'out', true)}${batchTable('Expiring soon', data.expiring_soon, 'low', false)}${prodTable('Low stock', data.low, 'low', true)}${prodTable('Out of stock', data.out, 'out', false)}
    <div class="sec card2"><h3>Alert settings</h3><p class="hint">A product uses its own minimum stock. If that is 0, the shop default below applies (0 = no default). “Expiring soon” looks this many days ahead.</p>
      ${isOwner() ? `<div class="g"><div><label for="slow">Shop default low-stock level</label><input id="slow" type="number" min="0" step="1" value="${data.low_default}"></div><div><label for="sexp">Expiry warning (days)</label><input id="sexp" type="number" min="1" max="365" step="1" value="${data.expiry_days}"></div></div><div class="acts-row"><button id="ssave" type="button">Save settings</button></div>`
        : `<p>Shop default low-stock level: <b>${data.low_default}</b> · Expiry warning: <b>${data.expiry_days} days</b>. Only the owner can change these.</p>`}</div>`;
}
async function saveSettings() {
  if (!isOwner() || busy) return;
  const low = Number($$('slow').value), exp = Number($$('sexp').value);
  if (!Number.isInteger(low) || low < 0 || low > 100000) return T.toast('Low-stock level must be a whole number, 0 or more.', false);
  if (!Number.isInteger(exp) || exp < 1 || exp > 365) return T.toast('Expiry warning must be between 1 and 365 days.', false);
  busy = true;
  try {
    const res = await db.from('company_settings').update({ low_stock_threshold: low, expiry_alert_days: exp }).eq('company_id', cid).select('company_id');
    if (res.error) return void fail(res.error, 'settings', 'Settings were not saved.');
    if (!res.data.length) return void T.toast('Shop settings were not found, or you do not have permission to change them.', false);
    T.toast('Settings saved.'); loadAlerts();
  } catch (e) { fail(e, 'settings'); } finally { busy = false; }
}

function wire() {
  const reload = () => { page = 0; loadHist(); };
  document.querySelector('.tabs').onclick = e => { const b = e.target.closest('button[data-tab]'); if (b) setTab(b.dataset.tab); };
  ['htype', 'hfrom', 'hto'].forEach(i => $$(i).onchange = reload);
  $$('hdate').onchange = () => { const c = $$('hdate').value === 'custom'; $$('hfrom').hidden = $$('hto').hidden = !c; reload(); };
  $$('hq').oninput = () => { clearTimeout(timer); timer = setTimeout(reload, 300); };
  $$('hprev').onclick = () => { page--; loadHist(); }; $$('hnext').onclick = () => { page++; loadHist(); };
  $$('hcsv').onclick = exportHist;
  $$('s-hist').addEventListener('input', e => { if (e.target.id === 'hp') { clearTimeout(timer); timer = setTimeout(() => pickProduct(e.target, p => { prod = p; renderProdChip(); reload(); }, false), 250); } });
  $$('s-hist').addEventListener('keydown', e => { if (e.target.id === 'hp') PopList.key(e); });
  $$('s-hist').onclick = e => { if (e.target.id === 'pclear') { prod = null; renderProdChip(); reload(); } if (e.target.id === 'hretry') loadHist(); };
  const sa = $$('s-adj');
  sa.addEventListener('input', e => { if (e.target.id === 'ap') { clearTimeout(timer); timer = setTimeout(() => pickProduct(e.target, p => { adj = { req: T.uuid() }; selectAdjProduct(p); }, true), 250); } });
  sa.addEventListener('keydown', e => { if (e.target.id === 'ap') PopList.key(e); });
  sa.addEventListener('change', e => { if (['abatch', 'akind', 'areason'].includes(e.target.id)) { if (e.target.id === 'abatch' && adj) adj.batch = e.target.value; onAdjChange(); } });
  sa.onclick = e => { if (e.target.id === 'asave') saveAdj(); if (e.target.id === 'aclear') { adj = null; renderAdj(); } };
  const al = $$('s-alerts');
  al.onclick = e => { if (e.target.id === 'ssave') saveSettings(); if (e.target.id === 'aretry') loadAlerts(); const w = e.target.closest('[data-wo]'); if (w) startWriteOff(alerts.expired[+w.dataset.wo]); };
  $$('out').onclick = async e => { e.preventDefault(); await db.auth.signOut(); location.replace('login.html'); };
  db.auth.onAuthStateChange(evt => { if (evt === 'SIGNED_OUT') location.replace('login.html'); });
}

function init() { shell(); wire(); return boot(); }
async function boot() {
  const { data: { session } } = await db.auth.getSession();
  if (!session) return location.replace('login.html');
  const { data: m, error } = await db.from('company_members').select('company_id,role,companies(name)').eq('user_id', session.user.id).limit(1);
  if (error) { const f = fail(error, 'membership'); $$('hstate').innerHTML = `<div class="st"><h3>Unable to load.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="retry-init">Try again</button></div>`; return; }
  if (!m.length) return location.replace('login.html');
  cid = m[0].company_id; role = m[0].role; $$('who').textContent = `${m[0].companies?.name || ''} · ${role}`;
  document.querySelectorAll('.tabs button').forEach(b => { if (!ENABLED.includes(b.dataset.tab)) b.hidden = true; });
  if (ENABLED.length === 1) document.querySelector('.tabs').hidden = true;
  if (!canAdj()) $$('tabadj').hidden = true;
  adj = null; await loadHist();
}
document.addEventListener('click', e => { if (e.target.id === 'retry-init') boot().catch(x => fail(x, 'retry')); });
init().catch(e => { console.error(e); T.toast('Something went wrong. Please refresh the page.', false); });
})();
