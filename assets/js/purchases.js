// Purchases page (Phase 4). Reuses auth.js's single Supabase client (client()).
// All writes go through the database functions create_purchase / update_purchase / cancel_purchase, which save the purchase,
// its items, stock, stock history and audit log in ONE transaction. The totals shown here are previews; the database
// recomputes everything from the items. Money maths uses BigInt (exact) and mirrors the database's rounding.
(() => {
const db = client();
const PAGE = 25;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = v => '₹' + Number(v || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const moneyP = b => (b < 0n ? '-' : '') + money(Math.abs(Number(b)) / 100);            // BigInt paise -> text
const qtyTxt = v => Number(v).toLocaleString('en-IN', { maximumFractionDigits: 3 });
const pad = n => String(n).padStart(2, '0');
const iso = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const today = () => iso(new Date());
const fdate = s => s ? new Date(s + 'T00:00:00').toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '—';
const ST = { draft: ['arc', 'Draft'], completed: ['in', 'Completed'], cancelled: ['out', 'Cancelled'] };
const PY = { paid: ['in', 'Paid'], partial: ['low', 'Partially paid'], unpaid: ['out', 'Unpaid'] };

let cid, role, companyName = '', shop = null, page = 0, total = 0, reqId = 0, timer, rows = [], suppliers = [], ed = null, lineSeq = 0, viewing = null, busy = false;
const canWrite = () => role === 'owner' || role === 'manager';
const toast = (t, ok = true) => { const e = $('toast'); e.textContent = t; e.style.background = ok ? '#1f4d2b' : '#a32020'; e.style.display = 'block'; clearTimeout(toast.t); toast.t = setTimeout(() => e.style.display = 'none', 5000); };

// ---------- exact decimal helpers ----------
const dec = (str, scale) => {                       // "12.50" -> 1250n ; null if invalid or too many decimals
  const s = String(str ?? '').trim(); if (s === '') return 0n;
  if (!/^\d+(\.\d+)?$/.test(s)) return null;
  const [i, f = ''] = s.split('.'); if (f.length > scale) return null;
  return BigInt(i + f.padEnd(scale, '0'));
};
function lineCalc(l) {                              // same rounding as the SQL: round(qty*price,2), round(taxable*rate/100,2)
  const q = dec(l.qty, 3), p = dec(l.price, 2), d = dec(l.disc, 2), r = dec(l.rate, 2);
  if (q === null || p === null || d === null || r === null) return { err: 'use numbers only (quantity up to 3 decimals, amounts up to 2).' };
  if (q <= 0n) return { err: 'quantity must be greater than 0.' };
  if (r > 10000n) return { err: 'tax rate must be between 0 and 100.' };
  const gross = (q * p + 500n) / 1000n;
  if (d > gross) return { err: 'discount cannot be more than the line amount.' };
  const taxable = gross - d, tax = (taxable * r + 5000n) / 10000n;
  return { taxable, tax, total: taxable + tax };
}
function calc() {
  let sub = 0n, tax = 0n, bad = false;
  for (const l of ed.lines) { if (!l.product) continue; const r = lineCalc(l); if (r.err) { bad = true; continue; } sub += r.taxable; tax += r.tax; }
  const disc = dec($('edisc').value, 2), add = dec($('eadd').value, 2), paid = dec($('epaid').value, 2);
  const numsOk = disc !== null && add !== null && paid !== null;
  const D = disc ?? 0n, A = add ?? 0n, P = paid ?? 0n;
  const grand = sub - D + tax + A;
  return { sub, tax, disc: D, add: A, paid: P, grand, due: grand - P, bad, numsOk, status: P >= grand ? 'paid' : P === 0n ? 'unpaid' : 'partial' };
}

// ---------- errors ----------
const ERR = {
  NOT_ALLOWED: 'You do not have permission for this action.', SUPPLIER_NOT_FOUND: 'Please select a valid supplier from your shop.',
  SUPPLIER_INACTIVE: 'This supplier is inactive. Activate it first or choose another supplier.', PRODUCT_NOT_FOUND: 'A selected product was not found in your shop.',
  PRODUCT_INACTIVE: 'A selected product is inactive.', NO_ITEMS: 'Add at least one item.', INVALID_QUANTITY: 'Quantity must be greater than 0 (up to 3 decimals).',
  INVALID_AMOUNT: 'An amount is not valid (up to 2 decimals, not negative).', INVALID_DATE: 'A date is not valid.', DISCOUNT_TOO_HIGH: 'A discount is larger than the amount it applies to.',
  PAID_EXCEEDS_TOTAL: 'Amount paid cannot be more than the grand total.', PURCHASE_CANCELLED: 'This purchase is cancelled and cannot be changed.',
  ALREADY_CANCELLED: 'This purchase is already cancelled.', CANNOT_REVERT_TO_DRAFT: 'A completed purchase cannot go back to draft. Cancel it instead.',
  INSUFFICIENT_STOCK: 'Part of this stock has already been sold or used, so it cannot be reduced that far.', BATCH_DATE_MISMATCH: 'That batch number already exists with different manufacturing/expiry dates.',
  TOO_MANY_ITEMS: 'A purchase can have at most 200 items.', INVALID_STATUS: 'Invalid purchase status.'
};
function friendly(e) {
  const m = e?.message || '', low = (m + ' ' + (e?.details || '')).toLowerCase();
  if (ERR[m]) return { text: ERR[m] };
  if (/jwt|expired|not authenticated/.test(low) || e?.code === 'PGRST301') return { text: 'Your session has expired. Please sign in again.', auth: true };
  if (/failed to fetch|network|load failed/.test(low)) return { text: 'Network problem. Please check your connection and try again.' };
  if (e?.code === '23505' && /invoice/.test(low)) return { text: 'This supplier already has a purchase with that invoice number.' };
  if (e?.code === '22P02') return { text: 'Some values are not valid numbers or dates.' };
  return { text: 'Something went wrong. Please try again.' };
}
function fail(e, ctx, prefix = '') {
  console.error('[purchases]', ctx, e);
  const f = friendly(e); toast((prefix ? prefix + ' ' : '') + f.text, false);
  if (f.auth) setTimeout(() => location.replace('login.html'), 1500);
  return f;
}

// ---------- shell ----------
function shell() {
  $('app').innerHTML = `
  <section id="listView">
    <div class="top"><div><h2>Purchases</h2><p class="sub">Manage supplier purchases, purchase invoices, stock additions, and outstanding supplier balances.</p><small id="who"></small></div><button id="new" hidden>+ New Purchase</button></div>
    <div class="bar" style="margin-top:16px">
      <input id="q" type="search" placeholder="Search purchase # or invoice number…" aria-label="Search purchases" autocomplete="off">
      <select id="fsup" aria-label="Supplier"><option value="">All suppliers</option></select>
      <select id="fdate" aria-label="Date range"><option value="">Any date</option><option value="today">Today</option><option value="week">This week</option><option value="month">This month</option><option value="custom">Custom range…</option></select>
      <input id="dfrom" type="date" aria-label="From date" hidden><input id="dto" type="date" aria-label="To date" hidden>
      <select id="fpay" aria-label="Payment status"><option value="">Any payment</option><option value="paid">Paid</option><option value="partial">Partially paid</option><option value="unpaid">Unpaid</option></select>
      <select id="fst" aria-label="Purchase status"><option value="">Any status</option><option value="draft">Draft</option><option value="completed">Completed</option><option value="cancelled">Cancelled</option></select>
    </div>
    <div class="tw" id="tw"><table><thead><tr><th>Purchase #</th><th>Invoice number</th><th>Supplier</th><th>Purchase date</th><th>Items</th><th>Total</th><th>Paid</th><th>Balance</th><th>Payment</th><th>Status</th><th>Actions</th></tr></thead><tbody id="rows"></tbody></table></div>
    <div id="state"></div>
    <div class="pg"><button class="ghost" id="prev" aria-label="Previous page">‹</button><span id="pn"></span><button class="ghost" id="next" aria-label="Next page">›</button></div>
  </section>
  <section id="editView" hidden></section>

  <dialog id="vdlg"><div id="vbody"></div></dialog>
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

// ---------- list ----------
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
  $('rows').innerHTML = '<tr><td colspan="11"><div class="sk"></div></td></tr>'.repeat(4);
  let q = db.from('purchases').select('id,purchase_no,invoice_number,purchase_date,grand_total,amount_paid,balance_due,payment_status,status,supplier_id,suppliers(supplier_name),purchase_items(count)', { count: 'exact' }).eq('company_id', cid);
  const s = $('q').value.trim().replace(/[,()%\\*"]/g, ' ').replace(/\s+/g, ' ').trim();
  if (s) q = q.or(`purchase_no.ilike.%${s}%,invoice_number.ilike.%${s}%`);
  if ($('fsup').value) q = q.eq('supplier_id', $('fsup').value);
  if ($('fpay').value) q = q.eq('payment_status', $('fpay').value);
  if ($('fst').value) q = q.eq('status', $('fst').value);
  const [from, to] = dateRange(); if (from) q = q.gte('purchase_date', from); if (to) q = q.lte('purchase_date', to);
  const { data, count, error } = await q.order('purchase_date', { ascending: false }).order('created_at', { ascending: false }).order('id').range(page * PAGE, page * PAGE + PAGE - 1);
  if (my !== reqId) return;
  if (error) {
    const f = fail(error, 'load'); $('rows').innerHTML = ''; $('pn').textContent = ''; $('prev').disabled = $('next').disabled = true;
    return setState(`<div class="st"><h3>Unable to load purchases.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="retry">Try again</button></div>`);
  }
  total = count || 0;
  if (!data.length && page > 0) { page = Math.max(0, Math.ceil(total / PAGE) - 1); return load(); }
  rows = data;
  $('pn').textContent = total ? `${page * PAGE + 1}–${Math.min(total, (page + 1) * PAGE)} of ${total}` : '0';
  $('prev').disabled = page === 0; $('next').disabled = (page + 1) * PAGE >= total;
  if (!data.length) {
    $('rows').innerHTML = '';
    const filtered = s || $('fsup').value || $('fpay').value || $('fst').value || $('fdate').value;
    return setState(filtered ? '<div class="st"><h3>No purchases match your filters</h3><p>Try changing or clearing the filters.</p></div>'
      : `<div class="st"><h3>No purchases yet</h3><p>Record your first purchase to add stock and track what you owe suppliers.</p>${canWrite() ? '<button id="empty-new">+ New Purchase</button>' : '<p>Ask the owner or a manager to add one.</p>'}</div>`);
  }
  $('rows').innerHTML = data.map(r => {
    const st = ST[r.status], py = PY[r.payment_status], items = r.purchase_items?.[0]?.count ?? 0, live = r.status !== 'cancelled';
    return `<tr><td><b>${esc(r.purchase_no)}</b></td><td>${esc(r.invoice_number || '—')}</td><td>${esc(r.suppliers?.supplier_name || '—')}</td><td>${fdate(r.purchase_date)}</td><td>${items}</td>
      <td class="amt">${money(r.grand_total)}</td><td class="amt">${money(r.amount_paid)}</td><td class="amt">${money(r.balance_due)}</td>
      <td><span class="b ${py[0]}">${py[1]}</span></td><td><span class="b ${st[0]}">${st[1]}</span></td>
      <td><div class="acts"><button class="ghost" data-act="view" data-id="${r.id}">View</button>${canWrite() && live ? `<button class="ghost" data-act="edit" data-id="${r.id}">Edit</button><button class="ghost" data-act="cancel" data-id="${r.id}">Cancel</button>` : ''}</div></td></tr>`;
  }).join('');
}

async function loadSuppliers() {
  const { data, error } = await db.from('suppliers').select('id,supplier_name,phone,is_active').eq('company_id', cid).order('supplier_name').limit(1000);
  if (error) { console.warn('suppliers', error); return; }
  suppliers = data;
  $('fsup').innerHTML = '<option value="">All suppliers</option>' + suppliers.map(s => `<option value="${s.id}">${esc(s.supplier_name)}${s.is_active ? '' : ' (inactive)'}</option>`).join('');
}

// ---------- full purchase (view / edit / print) ----------
async function fetchFull(id) {
  const { data, error } = await db.from('purchases').select('*,suppliers(supplier_name,phone,gst_number,address,city,state),purchase_items(line_no,product_id,quantity,unit_price,discount,tax_rate,tax,line_total,batch_number,manufacturing_date,expiry_date,products(product_name,unit,sku,product_code))').eq('id', id).eq('company_id', cid).single();
  if (error) throw error;
  data.purchase_items = (data.purchase_items || []).sort((a, b) => a.line_no - b.line_no);
  return data;
}
async function openView(id) {
  let p; try { p = await fetchFull(id); } catch (e) { return fail(e, 'view'); }
  viewing = p;
  let by = '—'; if (p.created_by) { const r = await db.from('profiles').select('full_name').eq('id', p.created_by).maybeSingle(); by = r.data?.full_name || '—'; }
  const st = ST[p.status], py = PY[p.payment_status];
  const impact = p.status === 'completed' ? `<ul class="imp">${p.purchase_items.map(i => `<li>${esc(i.products?.product_name)} <b>+${qtyTxt(i.quantity)} ${esc(i.products?.unit)}</b> <span class="hint">(batch ${esc(i.batch_number)})</span></li>`).join('')}</ul>`
    : `<p class="hint">${p.status === 'draft' ? 'No stock change yet. Stock is added when the purchase is completed.' : 'This purchase was cancelled; any stock it added has been reversed.'}</p>`;
  $('vbody').innerHTML = `<div class="top"><h2>${esc(p.purchase_no)} <span class="b ${st[0]}">${st[1]}</span></h2></div>
    <dl class="dl"><dt>Supplier</dt><dd>${esc(p.suppliers?.supplier_name)}</dd><dt>Invoice number</dt><dd>${esc(p.invoice_number || '—')}</dd><dt>Purchase date</dt><dd>${fdate(p.purchase_date)}</dd><dt>Created by</dt><dd>${esc(by)}</dd>${p.notes ? `<dt>Notes</dt><dd>${esc(p.notes)}</dd>` : ''}${p.cancel_reason ? `<dt>Cancel reason</dt><dd>${esc(p.cancel_reason)}</dd>` : ''}</dl>
    <div class="tw"><table><thead><tr><th>#</th><th>Product</th><th>Batch</th><th>Qty</th><th>Unit price</th><th>Disc</th><th>Tax</th><th>Line total</th></tr></thead><tbody>
    ${p.purchase_items.map(i => `<tr><td>${i.line_no}</td><td>${esc(i.products?.product_name)}</td><td>${esc(i.batch_number)}${i.expiry_date ? `<span class="sub2">exp ${fdate(i.expiry_date)}</span>` : ''}</td><td class="amt">${qtyTxt(i.quantity)} ${esc(i.products?.unit)}</td><td class="amt">${money(i.unit_price)}</td><td class="amt">${money(i.discount)}</td><td class="amt">${money(i.tax)} <span class="hint">(${Number(i.tax_rate)}%)</span></td><td class="amt">${money(i.line_total)}</td></tr>`).join('')}</tbody></table></div>
    <div class="totals" style="margin-top:12px"><div><h3 style="margin:0 0 4px">Inventory impact</h3>${impact}</div>
    <div class="sum"><span>Subtotal</span><span>${money(p.subtotal)}</span><span>Discount</span><span>- ${money(p.discount)}</span><span>Tax</span><span>${money(p.tax)}</span><span>Additional charges</span><span>${money(p.additional_charges)}</span>
    <span class="gt">Grand total</span><span class="gt">${money(p.grand_total)}</span><span>Amount paid</span><span>${money(p.amount_paid)}</span><span>Balance due</span><span><b>${money(p.balance_due)}</b></span><span>Payment status</span><span><span class="b ${py[0]}">${py[1]}</span></span></div></div>
    <div class="acts-row"><button type="button" class="ghost" id="vprint">Print</button>${canWrite() && p.status !== 'cancelled' ? '<button type="button" class="ghost" id="vedit">Edit</button><button type="button" class="danger" id="vcancel">Cancel purchase</button>' : ''}<button type="button" class="ghost" id="vclose">Close</button></div>`;
  $('vdlg').showModal();
}

async function printPurchase(p) {
  if (!shop) { const r = await db.from('company_settings').select('shop_name,address,phone,email,gst_number,invoice_footer').eq('company_id', cid).maybeSingle(); shop = r.data || {}; }
  const s = p.suppliers || {}, name = shop.shop_name || companyName;
  $('printArea').innerHTML = `<h1>${esc(name)}</h1><div>${esc([shop.address, shop.phone, shop.email].filter(Boolean).join(' · '))}${shop.gst_number ? `<br>GSTIN: ${esc(shop.gst_number)}` : ''}</div>
    <h2 style="margin:14px 0 4px">Purchase ${esc(p.purchase_no)}</h2>${p.status !== 'completed' ? `<div class="stamp">${esc(ST[p.status][1].toUpperCase())}</div>` : ''}
    <div class="meta"><div><b>Supplier</b><br>${esc(s.supplier_name)}<br>${esc(s.phone || '')}${s.gst_number ? `<br>GSTIN: ${esc(s.gst_number)}` : ''}${s.address ? `<br>${esc([s.address, s.city, s.state].filter(Boolean).join(', '))}` : ''}</div>
    <div><b>Invoice no:</b> ${esc(p.invoice_number || '—')}<br><b>Date:</b> ${fdate(p.purchase_date)}<br><b>Payment:</b> ${PY[p.payment_status][1]}</div></div>
    <table><thead><tr><th>#</th><th>Product</th><th>Batch</th><th class="r">Qty</th><th class="r">Rate</th><th class="r">Disc</th><th class="r">Tax %</th><th class="r">Amount</th></tr></thead><tbody>
    ${p.purchase_items.map(i => `<tr><td>${i.line_no}</td><td>${esc(i.products?.product_name)}</td><td>${esc(i.batch_number)}</td><td class="r">${qtyTxt(i.quantity)} ${esc(i.products?.unit)}</td><td class="r">${money(i.unit_price)}</td><td class="r">${money(i.discount)}</td><td class="r">${Number(i.tax_rate)}</td><td class="r">${money(i.line_total)}</td></tr>`).join('')}</tbody></table>
    <table class="tot"><tr><td>Subtotal</td><td class="r">${money(p.subtotal)}</td></tr><tr><td>Discount</td><td class="r">- ${money(p.discount)}</td></tr><tr><td>Tax</td><td class="r">${money(p.tax)}</td></tr><tr><td>Additional charges</td><td class="r">${money(p.additional_charges)}</td></tr>
    <tr><td><b>Grand total</b></td><td class="r"><b>${money(p.grand_total)}</b></td></tr><tr><td>Amount paid</td><td class="r">${money(p.amount_paid)}</td></tr><tr><td><b>Balance due</b></td><td class="r"><b>${money(p.balance_due)}</b></td></tr></table>
    ${p.notes ? `<p><b>Notes:</b> ${esc(p.notes)}</p>` : ''}${shop.invoice_footer ? `<p>${esc(shop.invoice_footer)}</p>` : ''}`;
  window.print();
}

// ---------- editor ----------
const newLine = (o = {}) => ({ k: ++lineSeq, product: null, qty: '', price: '', disc: '', rate: '', batch: '', mfg: '', exp: '', locked: false, ...o });
async function openEditor(id) {
  let p = null;
  if (id) { try { p = await fetchFull(id); } catch (e) { return fail(e, 'edit'); } if (p.status === 'cancelled') return toast(ERR.PURCHASE_CANCELLED, false); }
  ed = { id: p?.id || null, status: p?.status || null, no: p?.purchase_no || null, lines: [] };
  if (p) ed.lines = p.purchase_items.map(i => newLine({ product: { id: i.product_id, product_name: i.products?.product_name, unit: i.products?.unit, sku: i.products?.sku, product_code: i.products?.product_code },
    qty: String(Number(i.quantity)), price: String(i.unit_price), disc: String(i.discount), rate: String(Number(i.tax_rate)), batch: i.batch_number, mfg: i.manufacturing_date || '', exp: i.expiry_date || '', locked: p.status === 'completed' }));
  else ed.lines = [newLine()];
  const sups = suppliers.filter(s => s.is_active || s.id === p?.supplier_id);
  const completed = ed.status === 'completed';
  $('editView').innerHTML = `
    <div class="top"><div><h2>${p ? `Edit ${esc(p.purchase_no)}` : 'New purchase'}</h2><p class="sub">${completed ? 'This purchase is completed. Changing quantities adjusts stock by the difference only. Product and batch details of existing items are locked.' : 'Add the products you bought. Stock increases only when you complete the purchase.'}</p></div><button class="ghost" id="ebk">← Back to purchases</button></div>
    <div id="eerr" class="errbox" hidden></div>
    <div class="card2 g">
      <div><label for="esup">Supplier *</label><select id="esup"><option value="">Select supplier</option>${sups.map(s => `<option value="${s.id}">${esc(s.supplier_name)}${s.is_active ? '' : ' (inactive)'}${s.phone ? ' · ' + esc(s.phone) : ''}</option>`).join('')}</select><small class="hint" id="esupbal"></small></div>
      <div><label for="edate">Purchase date *</label><input id="edate" type="date" max="${today()}"></div>
      <div><label for="einv">Invoice number</label><input id="einv" maxlength="60" autocomplete="off" placeholder="Supplier's invoice no. (optional)"></div>
      <div><label for="enotes">Notes</label><input id="enotes" maxlength="1000" autocomplete="off"></div>
    </div>
    <div class="tw"><table class="items"><thead><tr><th>Product</th><th>Qty</th><th>Unit</th><th>Unit price (₹)</th><th>Disc (₹)</th><th>Tax %</th><th>Line total</th><th></th></tr></thead><tbody id="items"></tbody></table></div>
    <div style="margin:10px 0"><button class="ghost" id="addline" type="button">+ Add item</button></div>
    <div class="card2 totals">
      <div class="g"><div><label for="edisc">Purchase discount (₹)</label><input id="edisc" inputmode="decimal" placeholder="0.00"></div><div><label for="eadd">Additional charges (₹)</label><input id="eadd" inputmode="decimal" placeholder="0.00"></div>
        <div><label for="epaid">Amount paid (₹)</label><input id="epaid" inputmode="decimal" placeholder="0.00"></div><div style="align-self:end"><button class="ghost" id="payfull" type="button">Mark fully paid</button></div></div>
      <div class="sum"><span>Subtotal</span><span id="tsub"></span><span>Discount</span><span id="tdisc"></span><span>Tax</span><span id="ttax"></span><span>Additional charges</span><span id="tadd"></span>
        <span class="gt">Grand total</span><span class="gt" id="tgrand"></span><span>Amount paid</span><span id="tpaid"></span><span>Balance due</span><span id="tdue"></span><span>Payment status</span><span id="tpay"></span></div>
    </div>
    <div class="acts-row">${completed ? '<button id="esave" type="button">Save changes</button>' : '<button class="ghost" id="edraft" type="button">Save as draft</button><button id="ecomplete" type="button">Complete purchase</button>'}</div>`;
  $('esup').value = p?.supplier_id || ''; $('edate').value = p?.purchase_date || today(); $('einv').value = p?.invoice_number || ''; $('enotes').value = p?.notes || '';
  $('edisc').value = p && Number(p.discount) ? p.discount : ''; $('eadd').value = p && Number(p.additional_charges) ? p.additional_charges : ''; $('epaid').value = p && Number(p.amount_paid) ? p.amount_paid : '';
  $('listView').hidden = true; $('editView').hidden = false; window.scrollTo(0, 0);
  renderItems(); showSupBal();
}
function closeEditor() { ed = null; $('editView').hidden = true; $('editView').innerHTML = ''; $('listView').hidden = false; }

function renderItems() {
  $('items').innerHTML = ed.lines.map(l => {
    const pc = l.product ? `<div><b>${esc(l.product.product_name)}</b><span class="sub2">${esc([l.product.sku || l.product.product_code].filter(Boolean).join(''))}</span>${l.locked ? '' : `<button type="button" class="ghost" data-chg="${l.k}" style="margin-top:4px">Change</button>`}</div>`
      : `<div class="ps"><input class="pq" data-k="${l.k}" placeholder="Search product, SKU or code…" autocomplete="off" aria-label="Product"><div class="pl" hidden></div></div>`;
    const inp = (f, ph) => `<input data-k="${l.k}" data-f="${f}" inputmode="decimal" value="${esc(l[f])}" placeholder="${ph}" aria-label="${f}">`;
    return `<tr data-row="${l.k}"><td class="pc">${pc}</td><td>${inp('qty', '0')}</td><td>${esc(l.product?.unit || '—')}</td><td>${inp('price', '0.00')}</td><td>${inp('disc', '0.00')}</td><td>${inp('rate', '0')}</td>
      <td class="nm"><span id="lt-${l.k}">—</span><small class="fe" id="le-${l.k}"></small></td><td><button type="button" class="ghost" data-rm="${l.k}" title="Remove item" aria-label="Remove item">✕</button></td></tr>
      <tr class="sub"><td colspan="8"><div class="g3"><div><label>Batch no. (blank = purchase no.)</label><input data-k="${l.k}" data-f="batch" maxlength="60" value="${esc(l.batch)}" ${l.locked ? 'disabled' : ''}></div>
      <div><label>Mfg date</label><input type="date" data-k="${l.k}" data-f="mfg" value="${esc(l.mfg)}" ${l.locked ? 'disabled' : ''}></div><div><label>Expiry date</label><input type="date" data-k="${l.k}" data-f="exp" value="${esc(l.exp)}" ${l.locked ? 'disabled' : ''}></div></div></td></tr>`;
  }).join('');
  recalc();
}
function recalc() {
  if (!ed) return;
  for (const l of ed.lines) {
    const t = $('lt-' + l.k), e = $('le-' + l.k); if (!t) continue;
    if (!l.product) { t.textContent = '—'; e.textContent = ''; continue; }
    const r = lineCalc(l); t.textContent = r.err ? '—' : moneyP(r.total); e.textContent = r.err ? r.err : '';
  }
  const c = calc();
  $('tsub').textContent = moneyP(c.sub); $('tdisc').textContent = '- ' + moneyP(c.disc); $('ttax').textContent = moneyP(c.tax); $('tadd').textContent = moneyP(c.add);
  $('tgrand').textContent = moneyP(c.grand); $('tpaid').textContent = moneyP(c.paid); $('tdue').textContent = moneyP(c.due);
  $('tpay').innerHTML = `<span class="b ${PY[c.status][0]}">${PY[c.status][1]}</span>`;
  return c;
}
async function showSupBal() {
  const id = $('esup')?.value, el = $('esupbal'); if (!el) return; el.textContent = '';
  if (!id) return;
  const { data, error } = await db.rpc('supplier_outstanding', { p_company: cid, p_ids: [id] });
  if (error || !data?.length || $('esup').value !== id) return;
  const n = Number(data[0].outstanding); el.textContent = !n ? 'Nothing outstanding right now.' : n > 0 ? `You currently owe this supplier ${money(n)}.` : `This supplier currently owes you ${money(-n)} (advance).`;
}

// product search (server-side, debounced, 10 results)
const searchT = {};
async function searchProducts(k, term, box) {
  const s = term.trim().replace(/[,()%\\*"]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!s) { box.hidden = true; return; }
  const { data, error } = await db.from('products').select('id,product_name,sku,product_code,unit,purchase_price,tax_rate').eq('company_id', cid).eq('is_active', true)
    .or(`product_name.ilike.%${s}%,sku.ilike.%${s}%,product_code.ilike.%${s}%`).order('product_name').limit(10);
  if (error) { console.warn(error); box.innerHTML = '<div class="none">Search failed. Try again.</div>'; box.hidden = false; return; }
  box._res = data;
  box.innerHTML = data.length ? data.map((p, i) => `<button type="button" data-pick="${i}"><b>${esc(p.product_name)}</b> <span class="hint">${esc([p.sku || p.product_code, p.unit].filter(Boolean).join(' · '))}</span></button>`).join('') : '<div class="none">No active product found.</div>';
  box.hidden = false;
}
function pick(k, p) {
  const l = ed.lines.find(x => x.k === k); if (!l) return;
  l.product = p; if (l.price === '') l.price = String(p.purchase_price ?? ''); if (l.rate === '') l.rate = String(Number(p.tax_rate ?? 0));
  renderItems(); document.querySelector(`#items [data-k="${k}"][data-f="qty"]`)?.focus();
}

// validation + save
function validate() {
  const errs = [], c = calc();
  if (!$('esup').value) errs.push('Select a supplier.');
  const d = $('edate').value; if (!d || isNaN(Date.parse(d))) errs.push('Enter a valid purchase date.'); else if (d > today()) errs.push('Purchase date cannot be in the future.');
  const used = ed.lines.filter(l => l.product || l.qty !== '' || l.price !== '');
  if (!used.length) errs.push('Add at least one item.');
  used.forEach((l, i) => { const n = i + 1; if (!l.product) { errs.push(`Item ${n}: select a product.`); return; } const r = lineCalc(l); if (r.err) errs.push(`Item ${n}: ${r.err}`);
    if (l.mfg && l.exp && l.exp < l.mfg) errs.push(`Item ${n}: expiry date is before the manufacturing date.`); });
  if (!c.numsOk) errs.push('Discount, additional charges and amount paid must be numbers with up to 2 decimals.');
  else { if (c.disc > c.sub) errs.push('Purchase discount cannot be more than the subtotal.'); if (c.grand < 0n) errs.push('Grand total cannot be negative.'); else if (c.paid > c.grand) errs.push('Amount paid cannot be more than the grand total.'); }
  const box = $('eerr'); box.hidden = !errs.length; box.innerHTML = errs.length ? `<b>Please fix the following:</b><ul>${errs.map(e => `<li>${esc(e)}</li>`).join('')}</ul>` : '';
  if (errs.length) box.scrollIntoView({ behavior: 'smooth', block: 'center' });
  return errs;
}
const nz = id => ($(id).value || '').trim() || '0';
function payload(status) {
  const lines = ed.lines.filter(l => l.product);
  return { ...(ed.id ? {} : { company_id: cid }), supplier_id: $('esup').value, invoice_number: $('einv').value.trim() || null, purchase_date: $('edate').value, discount: nz('edisc'), additional_charges: nz('eadd'),
    amount_paid: nz('epaid'), notes: $('enotes').value.trim() || null, status,
    items: lines.map(l => ({ product_id: l.product.id, quantity: l.qty.trim(), unit_price: l.price.trim() || '0', discount: l.disc.trim() || '0', tax_rate: l.rate.trim() || '0', batch_number: l.batch.trim() || null, manufacturing_date: l.mfg || null, expiry_date: l.exp || null })) };
}
async function submit(kind) {
  if (busy || !canWrite()) return;
  if (validate().length) return;
  const c = calc(), nItems = ed.lines.filter(l => l.product).length, supName = $('esup').selectedOptions[0]?.textContent.split(' · ')[0] || 'the supplier';
  if (ed.status === 'completed') { if (!await ask({ title: 'Save changes?', msg: 'Stock will be adjusted by the difference between the old and new quantities, and the supplier balance will be recalculated.', ok: 'Save changes' })) return; }
  else if (kind === 'completed') { if (!await ask({ title: 'Complete this purchase?', msg: `This adds stock for ${nItems} item(s) and ${c.due > 0n ? `adds ${moneyP(c.due)} to what you owe ${supName}` : 'is fully paid'}. You can edit or cancel it later.`, ok: 'Complete purchase' })) return; }
  busy = true; document.querySelectorAll('#editView .acts-row button').forEach(b => b.disabled = true); toast('Saving purchase…');
  try {
    const status = ed.status === 'completed' ? 'completed' : kind;
    const res = ed.id ? await db.rpc('update_purchase', { p_id: ed.id, p: payload(status) }) : await db.rpc('create_purchase', { p: payload(status) });
    if (res.error) { fail(res.error, 'save', status === 'completed' ? 'Purchase could not be completed. No inventory changes were made.' : 'Purchase could not be saved.'); return; }
    toast(ed.status === 'completed' ? 'Purchase updated. Inventory adjusted.' : status === 'completed' ? `Purchase ${res.data.purchase_no} completed successfully. Inventory updated.` : `Draft ${res.data.purchase_no} saved.`);
    closeEditor(); page = 0; load();
  } catch (e) { fail(e, 'save', 'Purchase could not be saved. No inventory changes were made.'); }
  finally { busy = false; document.querySelectorAll('#editView .acts-row button').forEach(b => b.disabled = false); }
}

async function cancelPurchase(id) {
  const r = rows.find(x => x.id === id) || viewing; if (!r || busy) return;
  const completed = r.status === 'completed';
  const a = await ask({ title: `Cancel ${r.purchase_no}?`, msg: completed ? 'The stock added by this purchase will be taken back out and it will stop counting toward what you owe the supplier. The record is kept. This cannot be undone.' : 'This draft will be marked as cancelled.', ok: 'Cancel purchase', back: 'Keep purchase', danger: true, reason: true });
  if (!a) return;
  busy = true;
  try {
    const res = await db.rpc('cancel_purchase', { p_id: id, p_reason: a.reason || null });
    if (res.error) { fail(res.error, 'cancel', 'Purchase was not cancelled. Nothing was changed.'); return; }
    toast(completed ? `${r.purchase_no} cancelled. Inventory reversed.` : `${r.purchase_no} cancelled.`); load();
  } catch (e) { fail(e, 'cancel', 'Purchase was not cancelled. Nothing was changed.'); } finally { busy = false; }
}

// ---------- wiring ----------
function wire() {
  const reload = () => { page = 0; load(); };
  $('q').oninput = () => { clearTimeout(timer); timer = setTimeout(reload, 300); };
  ['fsup', 'fpay', 'fst', 'dfrom', 'dto'].forEach(i => $(i).onchange = reload);
  $('fdate').onchange = () => { const c = $('fdate').value === 'custom'; $('dfrom').hidden = $('dto').hidden = !c; reload(); };
  $('prev').onclick = () => { page--; load(); }; $('next').onclick = () => { page++; load(); };
  $('new').onclick = () => openEditor(null);
  $('state').onclick = e => { if (e.target.id === 'retry') load(); if (e.target.id === 'empty-new') openEditor(null); };
  $('rows').onclick = e => {
    const b = e.target.closest('button[data-act]'); if (!b) return;
    if (b.dataset.act === 'view') openView(b.dataset.id); else if (!canWrite()) return;
    else if (b.dataset.act === 'edit') openEditor(b.dataset.id); else if (b.dataset.act === 'cancel') cancelPurchase(b.dataset.id);
  };
  $('vbody').onclick = e => {
    const id = e.target.id; if (!id) return;
    if (id === 'vclose') $('vdlg').close(); else if (id === 'vprint') printPurchase(viewing);
    else if (id === 'vedit') { $('vdlg').close(); openEditor(viewing.id); } else if (id === 'vcancel') { $('vdlg').close(); cancelPurchase(viewing.id); }
  };
  const ev = $('editView');
  ev.onclick = e => {
    const t = e.target;
    if (t.id === 'ebk') return closeEditor();
    if (t.id === 'addline') { ed.lines.push(newLine()); renderItems(); return; }
    if (t.id === 'payfull') { const c = calc(); $('epaid').value = c.grand > 0n ? `${c.grand / 100n}.${String(c.grand % 100n).padStart(2, '0')}` : ''; recalc(); return; }
    if (t.id === 'edraft') return submit('draft'); if (t.id === 'ecomplete') return submit('completed'); if (t.id === 'esave') return submit('completed');
    const rm = t.closest('[data-rm]'); if (rm) { const k = +rm.dataset.rm; ed.lines = ed.lines.filter(l => l.k !== k); if (!ed.lines.length) ed.lines.push(newLine()); renderItems(); return; }
    const chg = t.closest('[data-chg]'); if (chg) { const l = ed.lines.find(x => x.k === +chg.dataset.chg); if (l) { l.product = null; renderItems(); } return; }
  };
  ev.addEventListener('mousedown', e => {
    const b = e.target.closest('[data-pick]'); if (!b) return; e.preventDefault();
    const box = b.parentElement, inp = box.parentElement.querySelector('.pq'); pick(+inp.dataset.k, box._res[+b.dataset.pick]);
  });
  ev.addEventListener('input', e => {
    const t = e.target;
    if (t.classList.contains('pq')) { const k = t.dataset.k; clearTimeout(searchT[k]); searchT[k] = setTimeout(() => searchProducts(k, t.value, t.nextElementSibling), 250); return; }
    if (t.dataset.f) { const l = ed.lines.find(x => x.k === +t.dataset.k); if (l) l[t.dataset.f] = t.value; }
    recalc();
  });
  ev.addEventListener('keydown', e => { if (e.key === 'Enter' && e.target.classList.contains('pq')) { e.preventDefault(); const box = e.target.nextElementSibling; if (box._res?.length) pick(+e.target.dataset.k, box._res[0]); } });
  ev.addEventListener('change', e => { if (e.target.id === 'esup') showSupBal(); if (e.target.type === 'date') { const l = ed.lines.find(x => x.k === +e.target.dataset.k); if (l) l[e.target.dataset.f] = e.target.value; } });
  document.addEventListener('click', e => { if (!e.target.closest('.ps')) document.querySelectorAll('.pl').forEach(b => b.hidden = true); });
  $('out').onclick = async e => { e.preventDefault(); await db.auth.signOut(); location.replace('login.html'); };
  db.auth.onAuthStateChange(evt => { if (evt === 'SIGNED_OUT') location.replace('login.html'); });
}

function init() { shell(); wire(); return boot(); }
async function boot() {
  $('state').innerHTML = ''; $('tw').hidden = false;
  $('rows').innerHTML = '<tr><td colspan="11"><div class="sk"></div></td></tr>'.repeat(3);
  const { data: { session } } = await db.auth.getSession();
  if (!session) return location.replace('login.html');
  const { data: m, error } = await db.from('company_members').select('company_id,role,companies(name)').eq('user_id', session.user.id).limit(1);
  if (error) {
    const f = fail(error, 'membership'); $('rows').innerHTML = '';
    return setState(`<div class="st"><h3>Unable to load purchases.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="retry-init">Try again</button></div>`);
  }
  if (!m.length) return location.replace('login.html');
  cid = m[0].company_id; role = m[0].role; companyName = m[0].companies?.name || '';
  $('who').textContent = `${companyName} · ${role}`; $('new').hidden = !canWrite();
  await Promise.all([loadSuppliers(), load()]);
}
document.addEventListener('click', e => { if (e.target.id === 'retry-init') boot().catch(x => fail(x, 'retry')); });
init().catch(e => { console.error(e); toast('Something went wrong. Please refresh the page.', false); });
})();
