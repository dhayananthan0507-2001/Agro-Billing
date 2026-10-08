// Sales & Billing page (Phase 5). Reuses auth.js's single Supabase client (client()).
// All writes go through the database functions create_sale / update_sale / cancel_sale, which save the invoice, its items, the
// stock (batches + inventory + stock history) and the audit log in ONE transaction. Totals and GST shown here are previews;
// the database recomputes everything. Money maths uses BigInt (exact) and mirrors the database's rounding.
(() => {
const db = client();
const PAGE = 25;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = v => '₹' + Number(v || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const moneyP = b => (b < 0n ? '-' : '') + money(Math.abs(Number(b)) / 100);
const qtyTxt = v => Number(v).toLocaleString('en-IN', { maximumFractionDigits: 3 });
const pad = n => String(n).padStart(2, '0');
const iso = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const today = () => iso(new Date());
const fdate = s => s ? new Date(s + 'T00:00:00').toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '—';
const fdt = s => s ? new Date(s).toLocaleString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—';
const ST = { completed: ['in', 'Completed'], cancelled: ['out', 'Cancelled'] };
const PY = { paid: ['in', 'Paid'], partial: ['low', 'Partial'], pending: ['out', 'Pending'] };
const PM = { cash: 'Cash', upi: 'UPI', card: 'Card', credit: 'Credit' };

let cid, role, companyName = '', shop = null, page = 0, total = 0, reqId = 0, timer, rows = [], names = {}, ed = null, lineSeq = 0, viewing = null, busy = false;
const canWrite = () => role === 'owner' || role === 'manager';       // edit / cancel
const toast = (t, ok = true) => { const e = $('toast'); e.textContent = t; e.style.background = ok ? '#1f4d2b' : '#a32020'; e.style.display = 'block'; clearTimeout(toast.t); toast.t = setTimeout(() => e.style.display = 'none', 5000); };

// ---------- exact decimal helpers ----------
const dec = (str, scale) => {
  const s = String(str ?? '').trim(); if (s === '') return 0n;
  if (!/^\d+(\.\d+)?$/.test(s)) return null;
  const [i, f = ''] = s.split('.'); if (f.length > scale) return null;
  return BigInt(i + f.padEnd(scale, '0'));
};
const toInput = b => `${b / 100n}.${String(b % 100n).padStart(2, '0')}`;
function lineCalc(l) {                              // same rounding as the SQL
  const q = dec(l.qty, 3), p = dec(l.price, 2), d = dec(l.disc, 2), r = dec(l.rate, 2);
  if (q === null || p === null || d === null || r === null) return { err: 'use numbers only (quantity up to 3 decimals, amounts up to 2).' };
  if (q <= 0n) return { err: 'quantity must be greater than 0.' };
  const gross = (q * p + 500n) / 1000n;
  if (d > gross) return { err: 'discount cannot be more than the line amount.' };
  const taxable = gross - d, tax = (taxable * r + 5000n) / 10000n;
  return { taxable, tax, total: taxable + tax };
}
function calc() {
  let sub = 0n, tax = 0n;
  for (const l of ed.lines) { if (!l.product) continue; const r = lineCalc(l); if (!r.err) { sub += r.taxable; tax += r.tax; } }
  const disc = dec($('edisc').value, 2), paid = dec($('epaid').value, 2);
  const numsOk = disc !== null && paid !== null, D = disc ?? 0n, P = paid ?? 0n, grand = sub - D + tax;
  return { sub, tax, disc: D, paid: P, grand, due: grand - P, numsOk, status: P >= grand ? 'paid' : P === 0n ? 'pending' : 'partial' };
}

// ---------- errors ----------
const ERR = {
  NOT_ALLOWED: 'You do not have permission for this action.', CUSTOMER_NOT_FOUND: 'Please select a valid customer from your shop.', CUSTOMER_INACTIVE: 'This customer is inactive. Activate them first or sell as a walk-in.',
  PRODUCT_NOT_FOUND: 'A selected product was not found in your shop.', PRODUCT_INACTIVE: 'A selected product is inactive.', NO_ITEMS: 'Add at least one item.',
  INVALID_QUANTITY: 'Quantity must be greater than 0 (up to 3 decimals).', INVALID_AMOUNT: 'An amount is not valid (up to 2 decimals, not negative).', INVALID_DATE: 'The sale date is not valid.',
  INVALID_TAX_RATE: 'A product has an invalid GST rate. Fix it on the Products page.', DISCOUNT_TOO_HIGH: 'A discount is larger than the amount it applies to.', PAID_EXCEEDS_TOTAL: 'Amount received cannot be more than the bill total.',
  CUSTOMER_REQUIRED_FOR_CREDIT: 'Select a saved customer to sell on credit or take a part payment.', INVALID_PAYMENT_METHOD: 'Choose Cash, UPI, Card or Credit.',
  SALE_CANCELLED: 'This sale is cancelled and cannot be changed.', ALREADY_CANCELLED: 'This sale is already cancelled.', TOO_MANY_ITEMS: 'A bill can have at most 200 items.',
  INSUFFICIENT_STOCK: 'Not enough stock for one of the products (expired batches cannot be sold).', ALLOCATION_MISMATCH: 'Stock records for this sale do not match. Please contact support before changing it.'
};
function friendly(e) {
  const m = e?.message || '', low = (m + ' ' + (e?.details || '')).toLowerCase();
  if (m === 'INSUFFICIENT_STOCK') {
    const [pid, av] = String(e.details || '').split(':'), l = ed?.lines.find(x => x.product?.id === pid);
    return { text: l && av !== undefined ? `Insufficient stock for ${l.product.product_name}. Only ${qtyTxt(av)} ${l.product.unit} is available.` : ERR.INSUFFICIENT_STOCK };
  }
  if (ERR[m]) return { text: ERR[m] };
  if (/jwt|expired|not authenticated/.test(low) || e?.code === 'PGRST301') return { text: 'Your session has expired. Please sign in again.', auth: true };
  if (/failed to fetch|network|load failed/.test(low)) return { text: 'Network problem. Please check your connection and try again.' };
  if (e?.code === '40P01' || e?.code === '40001') return { text: 'Another change was happening at the same moment. Please try again.' };
  if (e?.code === '23505') return { text: 'Could not generate a unique invoice number. Please try again.' };
  if (e?.code === '23514' || e?.code === '22P02') return { text: 'Some values are not valid. Please check the form and try again.' };
  return { text: 'Something went wrong. Please try again.' };
}
function fail(e, ctx, prefix = '') {
  console.error('[sales]', ctx, e);
  const f = friendly(e); toast((prefix ? prefix + ' ' : '') + f.text, false);
  if (f.auth) setTimeout(() => location.replace('login.html'), 1500);
  return f;
}

// ---------- shell ----------
function shell() {
  $('app').innerHTML = `
  <section id="listView">
    <div class="top"><div><h2>Sales &amp; Billing</h2><p class="sub">Create bills, track payments, print invoices and keep stock in step with every sale.</p><small id="who"></small></div><button id="new">+ New Sale</button></div>
    <div class="cards s4" id="scards" style="margin-top:14px"></div>
    <div class="bar">
      <input id="q" type="search" placeholder="Search invoice no., customer or product…" aria-label="Search sales" autocomplete="off">
      <select id="fdate" aria-label="Date range"><option value="">Any date</option><option value="today">Today</option><option value="week">This week</option><option value="month">This month</option><option value="custom">Custom range…</option></select>
      <input id="dfrom" type="date" aria-label="From date" hidden><input id="dto" type="date" aria-label="To date" hidden>
      <select id="fpay" aria-label="Payment status"><option value="">Any payment</option><option value="paid">Paid</option><option value="partial">Partial</option><option value="pending">Pending</option></select>
      <select id="fst" aria-label="Sale status"><option value="">Any status</option><option value="completed">Completed</option><option value="cancelled">Cancelled</option></select>
    </div>
    <div class="tw" id="tw"><table><thead><tr><th>Invoice no.</th><th>Date</th><th>Customer</th><th>Items</th><th>Total</th><th>Payment method</th><th>Payment status</th><th>Created by</th><th>Status</th><th>Actions</th></tr></thead><tbody id="rows"></tbody></table></div>
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

// ---------- summary cards ----------
async function loadStats() {
  const { data, error } = await db.rpc('sale_stats', { p_company: cid, p_date: today() });
  if (error) { console.warn('sale_stats unavailable', error); $('scards').innerHTML = ''; return; }
  $('scards').innerHTML = [["Today's sales", money(data.today_total), ''], ['Number of bills', data.today_count, 'today'], ['Paid amount', money(data.today_paid), 'received today'],
    ['Pending amount', money(data.today_pending), `${money(data.pending_total)} pending overall`]].map(([k, v, h]) => `<div class="card"><small>${k}</small><b>${esc(v)}</b>${h ? `<span class="hint">${esc(h)}</span>` : ''}</div>`).join('');
}

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
  $('rows').innerHTML = '<tr><td colspan="10"><div class="sk"></div></td></tr>'.repeat(4);
  let q = db.from('sales').select('id,invoice_no,sale_date,customer_name,customer_id,grand_total,amount_paid,balance_due,payment_method,payment_status,status,created_by,sale_items(count)', { count: 'exact' }).eq('company_id', cid);
  const s = $('q').value.trim().replace(/[,()%\\*"]/g, ' ').replace(/\s+/g, ' ').trim();
  if (s) {
    // product search: find invoices containing a matching product (names are copied onto each line), then OR with invoice / customer
    const it = await db.from('sale_items').select('sale_id').eq('company_id', cid).ilike('product_name_snapshot', `%${s}%`).limit(200);
    if (my !== reqId) return;
    const ids = (it.data || []).map(r => r.sale_id);
    q = q.or(`invoice_no.ilike.%${s}%,customer_name.ilike.%${s}%${ids.length ? `,id.in.(${ids.join(',')})` : ''}`);
  }
  if ($('fpay').value) q = q.eq('payment_status', $('fpay').value);
  if ($('fst').value) q = q.eq('status', $('fst').value);
  const [from, to] = dateRange(); if (from) q = q.gte('sale_date', from); if (to) q = q.lte('sale_date', to);
  const { data, count, error } = await q.order('sale_date', { ascending: false }).order('created_at', { ascending: false }).order('id').range(page * PAGE, page * PAGE + PAGE - 1);
  if (my !== reqId) return;
  if (error) {
    const f = fail(error, 'load'); $('rows').innerHTML = ''; $('pn').textContent = ''; $('prev').disabled = $('next').disabled = true;
    return setState(`<div class="st"><h3>Unable to load sales.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="retry">Try again</button></div>`);
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
    const filtered = s || $('fpay').value || $('fst').value || $('fdate').value;
    return setState(filtered ? '<div class="st"><h3>No sales match your filters</h3><p>Try changing or clearing the filters.</p></div>'
      : '<div class="st"><h3>No sales yet</h3><p>Create your first bill to start tracking sales, payments and stock.</p><button id="empty-new">+ New Sale</button></div>');
  }
  $('rows').innerHTML = data.map(r => {
    const st = ST[r.status], py = PY[r.payment_status], items = r.sale_items?.[0]?.count ?? 0, live = r.status === 'completed';
    return `<tr><td><b>${esc(r.invoice_no)}</b></td><td>${fdate(r.sale_date)}</td><td>${esc(r.customer_name)}</td><td>${items}</td><td class="amt">${money(r.grand_total)}</td>
      <td>${esc(PM[r.payment_method])}</td><td><span class="b ${py[0]}">${py[1]}</span>${Number(r.balance_due) > 0 ? `<span class="sub2">${money(r.balance_due)} due</span>` : ''}</td><td>${esc(names[r.created_by] || '—')}</td>
      <td><span class="b ${st[0]}">${st[1]}</span></td>
      <td><div class="acts"><button class="ghost" data-act="view" data-id="${r.id}">View</button><button class="ghost" data-act="print" data-id="${r.id}">Print</button>${canWrite() && live ? `<button class="ghost" data-act="edit" data-id="${r.id}">Edit</button><button class="ghost" data-act="cancel" data-id="${r.id}">Cancel</button>` : ''}</div></td></tr>`;
  }).join('');
}

// ---------- invoice (view + print) ----------
async function fetchFull(id) {
  const { data, error } = await db.from('sales').select('*,sale_items(line_no,product_id,product_name_snapshot,unit_snapshot,sku_snapshot,quantity,unit_price,discount,tax_rate,tax,line_total)').eq('id', id).eq('company_id', cid).single();
  if (error) throw error;
  data.sale_items = (data.sale_items || []).sort((a, b) => a.line_no - b.line_no);
  const ids = [data.created_by, data.cancelled_by].filter(u => u && !(u in names));
  if (ids.length) { const r = await db.from('profiles').select('id,full_name').in('id', ids); (r.data || []).forEach(p => { names[p.id] = p.full_name; }); ids.forEach(u => { if (!(u in names)) names[u] = '—'; }); }
  if (data.customer_id) { const c = await db.from('customers').select('gst_number,address,city,state').eq('id', data.customer_id).maybeSingle(); data._cust = c.data || {}; } else data._cust = {};
  return data;
}
async function loadShop() {
  if (shop) return shop;
  const r = await db.from('company_settings').select('shop_name,address,phone,email,gst_number,invoice_footer').eq('company_id', cid).maybeSingle();
  return (shop = r.data || {});
}
function invoiceHtml(p, sh) {
  const c = p._cust || {}, py = PY[p.payment_status], st = ST[p.status];
  const gstTotal = p.sale_items.some(i => Number(i.tax_rate) > 0);
  return `<div class="inv"><div class="inv-h"><div><h1>${esc(sh.shop_name || companyName)}</h1><div>${esc([sh.address, sh.phone, sh.email].filter(Boolean).join(' · '))}${sh.gst_number ? `<br>GSTIN: ${esc(sh.gst_number)}` : ''}</div></div>
    <div style="text-align:right"><h2 style="margin:0">${gstTotal ? 'Tax Invoice' : 'Invoice'}</h2><b>${esc(p.invoice_no)}</b><br>Date: ${fdate(p.sale_date)}<br>Cashier: ${esc(names[p.created_by] || '—')}</div></div>
    ${p.status === 'cancelled' ? '<div class="stamp">CANCELLED</div>' : ''}
    <div class="meta"><div><b>Bill to</b><br>${esc(p.customer_name)}${p.customer_phone ? `<br>${esc(p.customer_phone)}` : ''}${c.gst_number ? `<br>GSTIN: ${esc(c.gst_number)}` : ''}${c.address ? `<br>${esc([c.address, c.city, c.state].filter(Boolean).join(', '))}` : ''}</div>
    <div><b>Payment</b><br>Method: ${esc(PM[p.payment_method])}<br>Status: ${py[1]}${p.status === 'cancelled' ? `<br>Sale status: ${st[1]}` : ''}</div></div>
    <div class="tw"><table><thead><tr><th>#</th><th>Product</th><th class="r">Qty</th><th class="r">Unit price</th><th class="r">Disc</th><th class="r">GST</th><th class="r">Total</th></tr></thead><tbody>
    ${p.sale_items.map(i => `<tr><td>${i.line_no}</td><td>${esc(i.product_name_snapshot)}</td><td class="r">${qtyTxt(i.quantity)} ${esc(i.unit_snapshot)}</td><td class="r">${money(i.unit_price)}</td><td class="r">${money(i.discount)}</td><td class="r">${Number(i.tax_rate)}%</td><td class="r">${money(i.line_total)}</td></tr>`).join('')}</tbody></table></div>
    <table class="tot"><tr><td>Subtotal</td><td class="r">${money(p.subtotal)}</td></tr><tr><td>Discount</td><td class="r">- ${money(p.discount)}</td></tr><tr><td>GST</td><td class="r">${money(p.tax)}</td></tr>
    <tr><td><b>Grand total</b></td><td class="r"><b>${money(p.grand_total)}</b></td></tr><tr><td>Amount paid</td><td class="r">${money(p.amount_paid)}</td></tr><tr><td><b>Balance due</b></td><td class="r"><b>${money(p.balance_due)}</b></td></tr></table>
    ${p.notes ? `<p><b>Notes:</b> ${esc(p.notes)}</p>` : ''}${p.status === 'cancelled' ? `<p><b>Cancelled</b> ${fdt(p.cancelled_at)}${p.cancelled_by ? ` by ${esc(names[p.cancelled_by] || '—')}` : ''}${p.cancel_reason ? ` — ${esc(p.cancel_reason)}` : ''}</p>` : ''}
    ${sh.invoice_footer ? `<p style="text-align:center">${esc(sh.invoice_footer)}</p>` : ''}</div>`;
}
async function openView(id) {
  let p, sh; try { [p, sh] = await Promise.all([fetchFull(id), loadShop()]); } catch (e) { return fail(e, 'view'); }
  viewing = p;
  $('vbody').innerHTML = invoiceHtml(p, sh) + `<div class="acts-row"><button type="button" class="ghost" id="vprint">Print invoice</button>${canWrite() && p.status === 'completed' ? '<button type="button" class="ghost" id="vedit">Edit</button><button type="button" class="danger" id="vcancel">Cancel sale</button>' : ''}<button type="button" class="ghost" id="vclose">Close</button></div>`;
  $('vdlg').showModal();
}
async function printInvoice(p) {
  const sh = await loadShop();
  $('printArea').innerHTML = invoiceHtml(p, sh);
  window.print();
}

// ---------- billing screen ----------
const newLine = (o = {}) => ({ k: ++lineSeq, product: null, avail: 0, qty: '', price: '', disc: '', rate: '', ...o });
async function openEditor(id) {
  let p = null;
  if (id) { try { p = await fetchFull(id); } catch (e) { return fail(e, 'edit'); } if (p.status === 'cancelled') return toast(ERR.SALE_CANCELLED, false); }
  ed = { id: p?.id || null, no: p?.invoice_no || null, lines: [], customer: null, wname: p?.customer_id ? '' : (p && p.customer_name !== 'Walk-in Customer' ? p.customer_name : ''), wphone: p?.customer_phone && !p.customer_id ? p.customer_phone : '', paidTouched: !!p };
  if (p?.customer_id) ed.customer = { id: p.customer_id, customer_name: p.customer_name, phone: p.customer_phone };
  if (p) {
    const ids = [...new Set(p.sale_items.map(i => i.product_id))], orig = {};
    p.sale_items.forEach(i => { orig[i.product_id] = (orig[i.product_id] || 0) + Number(i.quantity); });
    const st = await db.rpc('product_sellable_stock', { p_company: cid, p_ids: ids }), sell = {};
    (st.data || []).forEach(r => { sell[r.product_id] = Number(r.sellable); });
    ed.lines = p.sale_items.map(i => newLine({ product: { id: i.product_id, product_name: i.product_name_snapshot, unit: i.unit_snapshot, sku: i.sku_snapshot }, avail: (sell[i.product_id] ?? Infinity) + (orig[i.product_id] || 0),   // unknown stock => let the database decide
     
      qty: String(Number(i.quantity)), price: String(i.unit_price), disc: String(i.discount), rate: String(Number(i.tax_rate)) }));
  } else ed.lines = [newLine()];
  $('editView').innerHTML = `
    <div class="top"><div><h2>${p ? `Edit ${esc(p.invoice_no)}` : 'New sale'}</h2><p class="sub">${p ? 'Changing quantities returns or takes only the difference in stock.' : 'Search products, enter quantities and take payment. Stock is reduced when you complete the sale.'}</p></div><button class="ghost" id="ebk">← Back to sales</button></div>
    <div id="eerr" class="errbox" hidden></div>
    <div class="card2"><div id="custwrap"></div><div class="g" style="margin-top:10px"><div><label for="edate">Sale date</label><input id="edate" type="date" max="${today()}"></div><div><label for="enotes">Notes</label><input id="enotes" maxlength="1000" autocomplete="off"></div></div></div>
    <div class="tw"><table class="items"><thead><tr><th>Product</th><th>Qty</th><th>Unit</th><th>Unit price (₹)</th><th>Disc (₹)</th><th>GST %</th><th>Line total</th><th></th></tr></thead><tbody id="items"></tbody></table></div>
    <div style="margin:10px 0"><button class="ghost" id="addline" type="button">+ Add item</button></div>
    <div class="card2 totals">
      <div class="g"><div><label for="edisc">Bill discount (₹)</label><input id="edisc" inputmode="decimal" placeholder="0.00"></div>
        <div><label for="epm">Payment method</label><select id="epm"><option value="cash">Cash</option><option value="upi">UPI</option><option value="card">Card</option><option value="credit">Credit (pay later)</option></select></div>
        <div><label for="epaid">Amount received (₹)</label><input id="epaid" inputmode="decimal" placeholder="0.00"></div><div style="align-self:end"><button class="ghost" id="payfull" type="button">Received in full</button></div></div>
      <div class="sum"><span>Subtotal</span><span id="tsub"></span><span>Discount</span><span id="tdisc"></span><span>GST</span><span id="ttax"></span>
        <span class="gt">Grand total</span><span class="gt" id="tgrand"></span><span>Amount received</span><span id="tpaid"></span><span>Balance due</span><span id="tdue"></span><span>Payment status</span><span id="tpay"></span></div>
    </div>
    <div class="acts-row"><button id="esave" type="button">${p ? 'Save changes' : 'Complete sale'}</button></div>`;
  $('edate').value = p?.sale_date || today(); $('enotes').value = p?.notes || '';
  $('edisc').value = p && Number(p.discount) ? p.discount : ''; $('epm').value = p?.payment_method || 'cash'; $('epaid').value = p ? (Number(p.amount_paid) ? p.amount_paid : '') : '';
  $('listView').hidden = true; $('editView').hidden = false; window.scrollTo(0, 0);
  renderCust(); renderItems();
}
function closeEditor() { ed = null; $('editView').hidden = true; $('editView').innerHTML = ''; $('listView').hidden = false; }

function renderCust() {
  $('custwrap').innerHTML = ed.customer
    ? `<div class="custbox"><b>Customer:</b><span class="cn">${esc(ed.customer.customer_name)}</span><span class="hint">${esc(ed.customer.phone || '')}</span><button type="button" class="ghost" id="cchg">Change</button></div><small class="hint" id="ecbal"></small>`
    : `<div class="g"><div class="f"><label for="ecq">Saved customer <span class="hint">(optional — leave empty for a walk-in)</span></label><div class="ps"><input id="ecq" placeholder="Search by name or phone…" autocomplete="off"><div class="pl" id="ecl" hidden></div></div></div>
       <div><label for="ecname">Walk-in name</label><input id="ecname" maxlength="150" value="${esc(ed.wname)}" placeholder="Walk-in Customer"></div><div><label for="ecphone">Walk-in phone</label><input id="ecphone" inputmode="tel" maxlength="20" value="${esc(ed.wphone)}"></div></div>`;
  if (ed.customer) showCustBal();
}
async function showCustBal() {
  const el = $('ecbal'), id = ed.customer?.id; if (!el || !id) return;
  const { data, error } = await db.rpc('customer_outstanding', { p_company: cid, p_ids: [id] });
  if (error || !data?.length || ed?.customer?.id !== id) return;
  const n = Number(data[0].outstanding); el.textContent = !n ? 'Nothing outstanding right now.' : n > 0 ? `This customer currently owes you ${money(n)}.` : `You currently owe this customer ${money(-n)} (advance).`;
}
async function searchCustomers(term, box) {
  const s = term.trim().replace(/[,()%\\*"]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!s) { box.hidden = true; return; }
  const { data, error } = await db.from('customers').select('id,customer_name,phone').eq('company_id', cid).eq('is_active', true)
    .or(`customer_name.ilike.%${s}%,phone.ilike.%${s.replace(/[\s-]/g, '')}%`).order('customer_name').limit(10);
  if (error) { console.warn(error); box.innerHTML = '<div class="none">Search failed. Try again.</div>'; box.hidden = false; return; }
  box._res = data;
  box.innerHTML = data.length ? data.map((c, i) => `<button type="button" data-cpick="${i}"><b>${esc(c.customer_name)}</b> <span class="hint">${esc(c.phone)}</span></button>`).join('') : '<div class="none">No active customer found. Leave empty for a walk-in.</div>';
  box.hidden = false;
}

function renderItems() {
  $('items').innerHTML = ed.lines.map(l => {
    const pc = l.product ? `<div><b>${esc(l.product.product_name)}</b><span class="sub2">${esc(l.product.sku || l.product.product_code || '')}</span><span class="stk" id="sk-${l.k}"></span><button type="button" class="ghost" data-chg="${l.k}" style="margin-top:4px">Change</button></div>`
      : `<div class="ps"><input class="pq" data-k="${l.k}" placeholder="Search product, SKU or code…" autocomplete="off" aria-label="Product"><div class="pl" hidden></div></div>`;
    const inp = (f, ph) => `<input data-k="${l.k}" data-f="${f}" inputmode="decimal" value="${esc(l[f])}" placeholder="${ph}" aria-label="${f}">`;
    return `<tr><td class="pc">${pc}</td><td>${inp('qty', '0')}</td><td>${esc(l.product?.unit || '—')}</td><td>${inp('price', '0.00')}</td><td>${inp('disc', '0.00')}</td><td class="gst">${l.product ? esc(String(Number(l.rate || 0))) + '%' : '—'}</td>
      <td class="nm"><span id="lt-${l.k}">—</span><small class="fe" id="le-${l.k}"></small></td><td><button type="button" class="ghost" data-rm="${l.k}" title="Remove item" aria-label="Remove item">✕</button></td></tr>`;
  }).join('');
  recalc();
}
function recalc() {
  if (!ed) return;
  const used = {};
  ed.lines.forEach(l => { if (l.product) { const q = dec(l.qty, 3); used[l.product.id] = (used[l.product.id] || 0) + (q ? Number(q) / 1000 : 0); } });
  for (const l of ed.lines) {
    const t = $('lt-' + l.k), e = $('le-' + l.k); if (!t) continue;
    if (!l.product) { t.textContent = '—'; e.textContent = ''; continue; }
    const r = lineCalc(l); t.textContent = r.err ? '—' : moneyP(r.total);
    const over = used[l.product.id] > l.avail + 1e-9;
    e.textContent = r.err ? r.err : over ? `Insufficient stock. Only ${qtyTxt(l.avail)} ${l.product.unit} is available.` : '';
    const sk = $('sk-' + l.k); if (sk) { sk.textContent = isFinite(l.avail) ? `Available: ${qtyTxt(l.avail)} ${l.product.unit}` : ''; sk.className = 'stk' + (over ? ' low' : ''); }
  }
  if (!ed.paidTouched) {            // until the user types an amount, "received" follows the bill (nothing for credit sales)
    const g = ed.lines.reduce((a, l) => { if (!l.product) return a; const r = lineCalc(l); return r.err ? a : a + r.total; }, 0n) - (dec($('edisc').value, 2) ?? 0n);
    $('epaid').value = $('epm').value === 'credit' || g <= 0n ? '' : toInput(g + 0n);
  }
  const c = calc();
  $('tsub').textContent = moneyP(c.sub); $('tdisc').textContent = '- ' + moneyP(c.disc); $('ttax').textContent = moneyP(c.tax); $('tgrand').textContent = moneyP(c.grand);
  $('tpaid').textContent = moneyP(c.paid); $('tdue').textContent = moneyP(c.due); $('tpay').innerHTML = `<span class="b ${PY[c.status][0]}">${PY[c.status][1]}</span>`;
  return c;
}

// product search (server-side, debounced, 10 results, with live stock)
const searchT = {};
async function searchProducts(term, box) {
  const s = term.trim().replace(/[,()%\\*"]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!s) { box.hidden = true; return; }
  const { data, error } = await db.from('products').select('id,product_name,sku,product_code,unit,selling_price,tax_rate').eq('company_id', cid).eq('is_active', true)
    .or(`product_name.ilike.%${s}%,sku.ilike.%${s}%,product_code.ilike.%${s}%`).order('product_name').limit(10);
  if (error) { console.warn(error); box.innerHTML = '<div class="none">Search failed. Try again.</div>'; box.hidden = false; return; }
  const st = data.length ? await db.rpc('product_sellable_stock', { p_company: cid, p_ids: data.map(p => p.id) }) : { data: [] };
  const sell = {}; (st.data || []).forEach(r => { sell[r.product_id] = Number(r.sellable); });
  data.forEach(p => { p.sellable = sell[p.id]; });
  box._res = data;
  box.innerHTML = data.length ? data.map((p, i) => `<button type="button" data-pick="${i}"><b>${esc(p.product_name)}</b> <span class="hint">${esc([p.sku || p.product_code, money(p.selling_price) + '/' + p.unit].filter(Boolean).join(' · '))} · ${p.sellable === undefined ? 'stock ?' : `Stock: ${qtyTxt(p.sellable)}`}</span></button>`).join('') : '<div class="none">No active product found.</div>';
  box.hidden = false;
}
function pick(k, p) {
  const l = ed.lines.find(x => x.k === k); if (!l) return;
  const had = ed.lines.filter(x => x.product?.id === p.id && x.k !== k)[0];
  l.product = { id: p.id, product_name: p.product_name, unit: p.unit, sku: p.sku, product_code: p.product_code };
  l.avail = had ? had.avail : (p.sellable ?? Infinity);   // unknown stock => let the database decide
  l.price = String(p.selling_price ?? ''); l.rate = String(Number(p.tax_rate ?? 0)); if (l.qty === '') l.qty = '1';
  renderItems(); document.querySelector(`#items [data-k="${k}"][data-f="qty"]`)?.focus();
}

// validation + save
function validate() {
  const errs = [], c = calc();
  const used = ed.lines.filter(l => l.product || l.qty !== '' || l.price !== '');
  if (!used.length) errs.push('Add at least one item.');
  const sums = {};
  used.forEach((l, i) => {
    const n = i + 1; if (!l.product) { errs.push(`Item ${n}: select a product.`); return; }
    const r = lineCalc(l); if (r.err) errs.push(`Item ${n}: ${r.err}`);
    const q = dec(l.qty, 3); if (q) sums[l.product.id] = { name: l.product.product_name, unit: l.product.unit, avail: l.avail, q: (sums[l.product.id]?.q || 0) + Number(q) / 1000 };
  });
  Object.values(sums).forEach(s => { if (s.q > s.avail + 1e-9) errs.push(`Insufficient stock for ${s.name}. Only ${qtyTxt(s.avail)} ${s.unit} is available.`); });
  const d = $('edate').value; if (!d || isNaN(Date.parse(d))) errs.push('Enter a valid sale date.'); else if (d > today()) errs.push('Sale date cannot be in the future.');
  if (!c.numsOk) errs.push('Discount and amount received must be numbers with up to 2 decimals.');
  else {
    if (c.disc > c.sub) errs.push('Bill discount cannot be more than the subtotal.');
    if (c.paid > c.grand) errs.push('Amount received cannot be more than the bill total.');
    else if (c.due > 0n && !ed.customer) errs.push('Select a saved customer to sell on credit or take a part payment. Walk-in customers must pay in full.');
  }
  if (!ed.customer && ed.wphone && !/^\+?[0-9]{10,13}$/.test(ed.wphone.replace(/[\s()-]/g, ''))) errs.push('Walk-in phone number is not valid (10–13 digits).');
  const box = $('eerr'); box.hidden = !errs.length; box.innerHTML = errs.length ? `<b>Please fix the following:</b><ul>${errs.map(e => `<li>${esc(e)}</li>`).join('')}</ul>` : '';
  if (errs.length) box.scrollIntoView({ behavior: 'smooth', block: 'center' });
  return errs;
}
const nz = id => ($(id).value || '').trim() || '0';
function payload() {
  return { ...(ed.id ? {} : { company_id: cid }), customer_id: ed.customer?.id || null, customer_name: ed.customer ? null : (ed.wname.trim() || null), customer_phone: ed.customer ? null : (ed.wphone.trim() || null),
    sale_date: $('edate').value, discount: nz('edisc'), payment_method: $('epm').value, amount_paid: nz('epaid'), notes: $('enotes').value.trim() || null,
    items: ed.lines.filter(l => l.product).map(l => ({ product_id: l.product.id, quantity: l.qty.trim(), unit_price: l.price.trim() || '0', discount: l.disc.trim() || '0' })) };
}
async function submit() {
  if (busy) return;
  if (validate().length) return;
  if (ed.id && !await ask({ title: 'Save changes?', msg: 'Stock will be adjusted by the difference between the old and new quantities, and the customer balance will be recalculated.', ok: 'Save changes' })) return;
  busy = true; $('esave').disabled = true; toast(ed.id ? 'Saving changes…' : 'Completing sale…');
  try {
    const res = ed.id ? await db.rpc('update_sale', { p_id: ed.id, p: payload() }) : await db.rpc('create_sale', { p: payload() });
    if (res.error) { fail(res.error, 'save', ed.id ? 'Changes were not saved. No stock was changed.' : 'Sale could not be completed. No stock was changed.'); return; }
    const wasEdit = !!ed.id, r = res.data;
    toast(wasEdit ? `${r.invoice_no} updated. Stock adjusted.` : `Sale ${r.invoice_no} completed. Stock updated.`);
    closeEditor(); page = 0; load(); loadStats(); openView(r.id);
  } catch (e) { fail(e, 'save', 'Nothing was saved. No stock was changed.'); }
  finally { busy = false; const b = $('esave'); if (b) b.disabled = false; }
}
async function cancelSale(id) {
  const r = rows.find(x => x.id === id) || viewing; if (!r || busy) return;
  const a = await ask({ title: `Cancel ${r.invoice_no}?`, msg: 'The stock sold on this invoice goes back to inventory and the invoice is marked CANCELLED. The record is kept. This cannot be undone.', ok: 'Cancel sale', back: 'Keep sale', danger: true, reason: true });
  if (!a) return;
  busy = true;
  try {
    const res = await db.rpc('cancel_sale', { p_id: id, p_reason: a.reason || null });
    if (res.error) { fail(res.error, 'cancel', 'Sale was not cancelled. Nothing was changed.'); return; }
    toast(`${r.invoice_no} cancelled. Stock returned to inventory.`); load(); loadStats();
  } catch (e) { fail(e, 'cancel', 'Sale was not cancelled. Nothing was changed.'); } finally { busy = false; }
}

// ---------- wiring ----------
function wire() {
  const reload = () => { page = 0; load(); };
  $('q').oninput = () => { clearTimeout(timer); timer = setTimeout(reload, 300); };
  ['fpay', 'fst', 'dfrom', 'dto'].forEach(i => $(i).onchange = reload);
  $('fdate').onchange = () => { const c = $('fdate').value === 'custom'; $('dfrom').hidden = $('dto').hidden = !c; reload(); };
  $('prev').onclick = () => { page--; load(); }; $('next').onclick = () => { page++; load(); };
  $('new').onclick = () => openEditor(null);
  $('state').onclick = e => { if (e.target.id === 'retry') load(); if (e.target.id === 'empty-new') openEditor(null); };
  $('rows').onclick = async e => {
    const b = e.target.closest('button[data-act]'); if (!b) return; const id = b.dataset.id;
    if (b.dataset.act === 'view') openView(id);
    else if (b.dataset.act === 'print') { try { const p = await fetchFull(id); await printInvoice(p); } catch (x) { fail(x, 'print'); } }
    else if (!canWrite()) return;
    else if (b.dataset.act === 'edit') openEditor(id); else if (b.dataset.act === 'cancel') cancelSale(id);
  };
  $('vbody').onclick = e => {
    const id = e.target.id; if (!id) return;
    if (id === 'vclose') $('vdlg').close(); else if (id === 'vprint') printInvoice(viewing);
    else if (id === 'vedit') { $('vdlg').close(); openEditor(viewing.id); } else if (id === 'vcancel') { $('vdlg').close(); cancelSale(viewing.id); }
  };
  const ev = $('editView');
  ev.onclick = e => {
    const t = e.target;
    if (t.id === 'ebk') return closeEditor();
    if (t.id === 'addline') { ed.lines.push(newLine()); renderItems(); return; }
    if (t.id === 'esave') return submit();
    if (t.id === 'cchg') { ed.customer = null; renderCust(); recalc(); return; }
    if (t.id === 'payfull') { ed.paidTouched = true; const c = calc(); $('epaid').value = c.grand > 0n ? toInput(c.grand) : ''; recalc(); return; }
    const rm = t.closest('[data-rm]'); if (rm) { const k = +rm.dataset.rm; ed.lines = ed.lines.filter(l => l.k !== k); if (!ed.lines.length) ed.lines.push(newLine()); renderItems(); return; }
    const chg = t.closest('[data-chg]'); if (chg) { const l = ed.lines.find(x => x.k === +chg.dataset.chg); if (l) { l.product = null; l.avail = 0; renderItems(); } return; }
  };
  ev.addEventListener('mousedown', e => {
    const b = e.target.closest('[data-pick],[data-cpick]'); if (!b) return; e.preventDefault();
    const box = b.parentElement;
    if (b.dataset.pick !== undefined) pick(+box.parentElement.querySelector('.pq').dataset.k, box._res[+b.dataset.pick]);
    else { ed.customer = box._res[+b.dataset.cpick]; renderCust(); recalc(); }
  });
  ev.addEventListener('input', e => {
    const t = e.target;
    if (t.classList.contains('pq')) { const k = t.dataset.k; clearTimeout(searchT[k]); searchT[k] = setTimeout(() => searchProducts(t.value, t.nextElementSibling), 250); return; }
    if (t.id === 'ecq') { clearTimeout(searchT.c); searchT.c = setTimeout(() => searchCustomers(t.value, $('ecl')), 250); return; }
    if (t.id === 'ecname') { ed.wname = t.value; return; } if (t.id === 'ecphone') { ed.wphone = t.value; return; }
    if (t.id === 'epaid') ed.paidTouched = true;
    if (t.dataset.f) { const l = ed.lines.find(x => x.k === +t.dataset.k); if (l) l[t.dataset.f] = t.value; }
    recalc();
  });
  ev.addEventListener('change', e => { if (e.target.id === 'epm') recalc(); });
  ev.addEventListener('keydown', e => {
    if (e.key !== 'Enter') return;
    if (e.target.classList.contains('pq')) { e.preventDefault(); const box = e.target.nextElementSibling; if (box._res?.length) pick(+e.target.dataset.k, box._res[0]); }
    else if (e.target.id === 'ecq') { e.preventDefault(); const box = $('ecl'); if (box._res?.length) { ed.customer = box._res[0]; renderCust(); recalc(); } }
  });
  document.addEventListener('click', e => { if (!e.target.closest('.ps')) document.querySelectorAll('.pl').forEach(b => b.hidden = true); });
  $('out').onclick = async e => { e.preventDefault(); await db.auth.signOut(); location.replace('login.html'); };
  db.auth.onAuthStateChange(evt => { if (evt === 'SIGNED_OUT') location.replace('login.html'); });
}

function init() { shell(); wire(); return boot(); }
async function boot() {
  $('state').innerHTML = ''; $('tw').hidden = false;
  $('rows').innerHTML = '<tr><td colspan="10"><div class="sk"></div></td></tr>'.repeat(3);
  const { data: { session } } = await db.auth.getSession();
  if (!session) return location.replace('login.html');
  const { data: m, error } = await db.from('company_members').select('company_id,role,companies(name)').eq('user_id', session.user.id).limit(1);
  if (error) {
    const f = fail(error, 'membership'); $('rows').innerHTML = '';
    return setState(`<div class="st"><h3>Unable to load sales.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="retry-init">Try again</button></div>`);
  }
  if (!m.length) return location.replace('login.html');
  cid = m[0].company_id; role = m[0].role; companyName = m[0].companies?.name || '';
  $('who').textContent = `${companyName} · ${role}`;
  await Promise.all([load(), loadStats()]);
}
document.addEventListener('click', e => { if (e.target.id === 'retry-init') boot().catch(x => fail(x, 'retry')); });
init().catch(e => { console.error(e); toast('Something went wrong. Please refresh the page.', false); });
})();
