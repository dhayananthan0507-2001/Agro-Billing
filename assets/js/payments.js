// Payments page (Phase 6). Reuses auth.js's single Supabase client (client()).
// Every payment is a row in the `payments` ledger. Payments taken when a bill is made ("At billing") are written automatically by the
// database; later payments are made ONLY through record_payments() and reversed ONLY through void_payment(), each in one transaction
// that also updates the invoice's paid/due amounts. Amounts here are checked for convenience; the database enforces every rule.
(() => {
const db = client();
const PAGE = 25;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = v => '₹' + Number(v || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
const moneyP = b => (b < 0n ? '-' : '') + money(Math.abs(Number(b)) / 100);
const pad = n => String(n).padStart(2, '0');
const iso = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const today = () => iso(new Date());
const fdate = s => s ? new Date(s + 'T00:00:00').toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '—';
const PM = { cash: 'Cash', upi: 'UPI', card: 'Card', bank_transfer: 'Bank transfer', other: 'Other' };

let cid, role, page = 0, total = 0, reqId = 0, timer, rows = [], names = {}, ed = null, busy = false, searchSeq = 0;
const canWrite = () => role === 'owner' || role === 'manager';       // pay suppliers, void
const toast = (t, ok = true) => { const e = $('toast'); e.textContent = t; e.style.background = ok ? '#1f4d2b' : '#a32020'; e.style.display = 'block'; clearTimeout(toast.t); toast.t = setTimeout(() => e.style.display = 'none', 5000); };
const dec = (str, scale) => { const s = String(str ?? '').trim(); if (s === '') return 0n; if (!/^\d+(\.\d+)?$/.test(s)) return null; const [i, f = ''] = s.split('.'); if (f.length > scale) return null; return BigInt(i + f.padEnd(scale, '0')); };
const toInput = b => `${b / 100n}.${String(b % 100n).padStart(2, '0')}`;

const ERR = {
  NOT_ALLOWED: 'You do not have permission for this action.', INVALID_AMOUNT: 'An amount is not valid (more than 0, up to 2 decimals).', INVALID_DATE: 'The payment date is not valid.',
  INVALID_PAYMENT_METHOD: 'Choose a payment method.', INVALID_DIRECTION: 'Invalid payment type.', PARTY_NOT_FOUND: 'Please select a valid customer or supplier from your shop.',
  DOCUMENT_NOT_FOUND: 'One of the invoices was not found for this customer or supplier.', DOCUMENT_CANCELLED: 'One of the invoices is cancelled, so it cannot be paid.',
  DOCUMENT_NOT_COMPLETED: 'One of the purchases is still a draft. Complete it before paying.', DUPLICATE_ALLOCATION: 'The same invoice appears twice.', NO_ALLOCATIONS: 'Enter an amount for at least one invoice.',
  TOO_MANY_ALLOCATIONS: 'Too many invoices in one payment (max 100).', TEXT_TOO_LONG: 'Reference or notes are too long.', ALREADY_CANCELLED: 'This payment is already cancelled.',
  CANNOT_VOID_INITIAL: 'The amount taken when the bill was made cannot be voided here. Change it by editing the invoice.'
};
function friendly(e) {
  const m = e?.message || '', low = (m + ' ' + (e?.details || '')).toLowerCase();
  if (m === 'PAYMENT_EXCEEDS_DUE') { const [no, due] = String(e.details || '').split(':'); return { text: due !== undefined ? `Payment is more than what is due on ${no}. Only ${money(due)} is due.` : 'A payment is more than what is due on its invoice.' }; }
  if (ERR[m]) return { text: ERR[m] };
  if (/jwt|expired|not authenticated/.test(low) || e?.code === 'PGRST301') return { text: 'Your session has expired. Please sign in again.', auth: true };
  if (/failed to fetch|network|load failed/.test(low)) return { text: 'Network problem. Please check your connection and try again.' };
  if (e?.code === '40P01' || e?.code === '40001') return { text: 'Another change was happening at the same moment. Please try again.' };
  if (e?.code === '22P02') return { text: 'Some values are not valid numbers or dates.' };
  return { text: 'Something went wrong. Please try again.' };
}
function fail(e, ctx, prefix = '') {
  console.error('[payments]', ctx, e);
  const f = friendly(e); toast((prefix ? prefix + ' ' : '') + f.text, false);
  if (f.auth) setTimeout(() => location.replace('login.html'), 1500);
  return f;
}

function shell() {
  $('app').innerHTML = `
  <section id="listView">
    <div class="top"><div><h2>Payments</h2><p class="sub">Every payment received from customers and paid to suppliers, including what was paid when each bill was made.</p><small id="who"></small></div>
      <div class="acts"><button id="recv">+ Receive payment</button><button id="payout" class="ghost" hidden>+ Pay supplier</button></div></div>
    <div class="cards s4" id="pcards" style="margin-top:14px"></div>
    <div class="bar">
      <input id="q" type="search" placeholder="Search receipt, invoice, reference or name…" aria-label="Search payments" autocomplete="off">
      <select id="ftype" aria-label="Type"><option value="">All payments</option><option value="in">Received from customers</option><option value="out">Paid to suppliers</option></select>
      <select id="fkind" aria-label="Entry"><option value="">Billing + later</option><option value="initial">At billing only</option><option value="payment">Later payments only</option></select>
      <select id="fmeth" aria-label="Method"><option value="">Any method</option>${Object.entries(PM).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}</select>
      <select id="fdate" aria-label="Date range"><option value="">Any date</option><option value="today">Today</option><option value="week">This week</option><option value="month">This month</option><option value="custom">Custom range…</option></select>
      <input id="dfrom" type="date" aria-label="From date" hidden><input id="dto" type="date" aria-label="To date" hidden>
      <select id="fst" aria-label="Status"><option value="">Any status</option><option value="completed">Completed</option><option value="cancelled">Cancelled</option></select>
    </div>
    <div class="tw" id="tw"><table><thead><tr><th>Date</th><th>Receipt</th><th>Invoice / reference</th><th>Customer / supplier</th><th>Amount</th><th>Method</th><th>Created by</th><th>Status</th><th>Actions</th></tr></thead><tbody id="rows"></tbody></table></div>
    <div id="state"></div>
    <div class="pg"><button class="ghost" id="prev" aria-label="Previous page">‹</button><span id="pn"></span><button class="ghost" id="next" aria-label="Next page">›</button></div>
  </section>
  <section id="editView" hidden></section>
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
  const { data, error } = await db.rpc('finance_stats', { p_company: cid, p_date: today() });
  if (error) { console.warn('finance_stats unavailable', error); $('pcards').innerHTML = ''; return; }
  $('pcards').innerHTML = [['Received today', money(data.money_in_today), ''], ['Paid out today', money(data.money_out_today), ''],
    ['Customers owe you', money(data.receivable), 'incl. opening balances'], ['You owe suppliers', money(data.payable), 'incl. opening balances']]
    .map(([k, v, h]) => `<div class="card"><small>${k}</small><b>${esc(v)}</b>${h ? `<span class="hint">${esc(h)}</span>` : ''}</div>`).join('');
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
  $('rows').innerHTML = '<tr><td colspan="9"><div class="sk"></div></td></tr>'.repeat(4);
  let q = db.from('payments').select('id,direction,kind,receipt_no,party_name,doc_no,payment_method,amount,payment_date,reference_number,notes,status,cancel_reason,created_by,sales(status),purchases(status)', { count: 'exact' }).eq('company_id', cid);
  const s = $('q').value.trim().replace(/[,()%\\*"]/g, ' ').replace(/\s+/g, ' ').trim();
  if (s) q = q.or(`receipt_no.ilike.%${s}%,reference_number.ilike.%${s}%,party_name.ilike.%${s}%,doc_no.ilike.%${s}%`);
  if ($('ftype').value) q = q.eq('direction', $('ftype').value);
  if ($('fkind').value) q = q.eq('kind', $('fkind').value);
  if ($('fmeth').value) q = q.eq('payment_method', $('fmeth').value);
  if ($('fst').value) q = q.eq('status', $('fst').value);
  const [from, to] = dateRange(); if (from) q = q.gte('payment_date', from); if (to) q = q.lte('payment_date', to);
  const { data, count, error } = await q.order('payment_date', { ascending: false }).order('created_at', { ascending: false }).order('id').range(page * PAGE, page * PAGE + PAGE - 1);
  if (my !== reqId) return;
  if (error) {
    const f = fail(error, 'load'); $('rows').innerHTML = ''; $('pn').textContent = ''; $('prev').disabled = $('next').disabled = true;
    return setState(`<div class="st"><h3>Unable to load payments.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="retry">Try again</button></div>`);
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
    const filtered = s || $('ftype').value || $('fkind').value || $('fmeth').value || $('fst').value || $('fdate').value;
    return setState(filtered ? '<div class="st"><h3>No payments match your filters</h3><p>Try changing or clearing the filters.</p></div>'
      : '<div class="st"><h3>No payments yet</h3><p>Payments appear here when you bill a customer, pay a supplier, or collect money against an unpaid invoice.</p><button id="empty-recv">+ Receive payment</button></div>');
  }
  $('rows').innerHTML = data.map(r => {
    const inn = r.direction === 'in', docSt = (r.sales || r.purchases)?.status, cancelledDoc = docSt === 'cancelled';
    const stBadge = r.status === 'cancelled' ? '<span class="b out">Voided</span>' : '<span class="b in">Completed</span>';
    return `<tr><td>${fdate(r.payment_date)}</td><td>${r.receipt_no ? `<b>${esc(r.receipt_no)}</b>` : '<span class="hint">At billing</span>'}</td>
      <td>${esc(r.doc_no)}${r.reference_number ? `<span class="sub2">Ref: ${esc(r.reference_number)}</span>` : ''}</td><td>${esc(r.party_name)}</td>
      <td class="amt ${inn ? 'amt-in' : 'amt-out'}">${inn ? '+' : '−'} ${money(r.amount)}<span class="dirtag">${inn ? 'Received' : 'Paid out'}</span></td><td>${esc(PM[r.payment_method] || r.payment_method)}</td><td>${esc(names[r.created_by] || '—')}</td>
      <td>${stBadge}${cancelledDoc ? '<span class="b low" title="The invoice this payment belongs to was cancelled">Invoice cancelled</span>' : ''}${r.cancel_reason ? `<span class="sub2">${esc(r.cancel_reason)}</span>` : ''}</td>
      <td>${canWrite() && r.kind === 'payment' && r.status === 'completed' ? `<button class="ghost" data-act="void" data-id="${r.id}">Void</button>` : ''}</td></tr>`;
  }).join('');
}

// ---------- record a payment (receive from a customer / pay a supplier) ----------
async function openForm(dir) {
  PopList.hide();
  ed = { dir, party: null, docs: [] };
  const inn = dir === 'in';
  $('editView').innerHTML = `
    <div class="top"><div><h2>${inn ? 'Receive payment from a customer' : 'Pay a supplier'}</h2><p class="sub">${inn ? 'Choose the customer, then enter how much is paid against each unpaid invoice.' : 'Choose the supplier, then enter how much you are paying against each unpaid purchase.'}</p></div><button class="ghost" id="ebk">← Back to payments</button></div>
    <div id="eerr" class="errbox" hidden></div>
    <div class="card2"><div id="partywrap"></div></div>
    <div id="docswrap"></div>
    <div class="card2 g" id="payfields" hidden>
      <div><label for="epm">Payment method</label><select id="epm">${Object.entries(PM).map(([k, v]) => `<option value="${k}">${v}</option>`).join('')}</select></div>
      <div><label for="edate">Payment date</label><input id="edate" type="date" max="${today()}"></div>
      <div><label for="eref">Reference (UPI / cheque / transaction no.)</label><input id="eref" maxlength="100" autocomplete="off"></div>
      <div><label for="enotes">Notes</label><input id="enotes" maxlength="500" autocomplete="off"></div></div>
    <div class="acts-row"><button id="esave" type="button" hidden>${inn ? 'Save receipt' : 'Save payment'}</button></div>`;
  $('edate').value = today();
  $('listView').hidden = true; $('editView').hidden = false; window.scrollTo(0, 0);
  renderParty();
}
function closeForm() { PopList.hide(); ed = null; $('editView').hidden = true; $('editView').innerHTML = ''; $('listView').hidden = false; }
function renderParty() {
  PopList.hide();
  const inn = ed.dir === 'in';
  $('partywrap').innerHTML = ed.party
    ? `<div class="custbox"><b>${inn ? 'Customer' : 'Supplier'}:</b><span class="cn">${esc(ed.party.name)}</span><span class="hint">${esc(ed.party.phone || '')}</span><button type="button" class="ghost" id="pchg">Change</button></div><small class="hint" id="pbal"></small>`
    : `<label for="pq">${inn ? 'Customer' : 'Supplier'}</label><input id="pq" placeholder="Search by name or phone…" autocomplete="off">`;
  if (!ed.party) { $('docswrap').innerHTML = ''; $('payfields').hidden = true; $('esave').hidden = true; }
}
async function searchParty(input) {
  const inn = ed.dir === 'in', tbl = inn ? 'customers' : 'suppliers', nm = inn ? 'customer_name' : 'supplier_name';
  const s = input.value.trim().replace(/[,()%\\*"]/g, ' ').replace(/\s+/g, ' ').trim();
  if (!s) { PopList.hide(); return; }
  const my = ++searchSeq;
  const { data, error } = await db.from(tbl).select(`id,${nm},phone`).eq('company_id', cid).eq('is_active', true).or(`${nm}.ilike.%${s}%,phone.ilike.%${s.replace(/[\s-]/g, '')}%`).order(nm).limit(10);
  if (my !== searchSeq || !input.isConnected) return;
  if (error) { console.warn(error); PopList.show(input, '<div class="none">Search failed. Try again.</div>', null); return; }
  PopList.show(input, data.length ? data.map((c, i) => `<button type="button" data-i="${i}"><b>${esc(c[nm])}</b><span class="hint">${esc(c.phone)}</span></button>`).join('') : `<div class="none">No active ${inn ? 'customer' : 'supplier'} found.</div>`,
    i => { ed.party = { id: data[i].id, name: data[i][nm], phone: data[i].phone }; renderParty(); loadDocs(); });
}
async function loadDocs() {
  const inn = ed.dir === 'in', id = ed.party.id;
  $('docswrap').innerHTML = '<div class="sk"></div>';
  const q = inn ? db.from('sales').select('id,invoice_no,sale_date,grand_total,balance_due').eq('company_id', cid).eq('customer_id', id).eq('status', 'completed').gt('balance_due', 0).order('sale_date').order('created_at').limit(200)
    : db.from('purchases').select('id,purchase_no,invoice_number,purchase_date,grand_total,balance_due').eq('company_id', cid).eq('supplier_id', id).eq('status', 'completed').gt('balance_due', 0).order('purchase_date').order('created_at').limit(200);
  const [d, o] = await Promise.all([q, db.rpc(inn ? 'customer_outstanding' : 'supplier_outstanding', { p_company: cid, p_ids: [id] })]);
  if (!ed || ed.party?.id !== id) return;
  if (d.error) { fail(d.error, 'docs'); $('docswrap').innerHTML = '<div class="st"><h3>Unable to load invoices.</h3><p>Please try again.</p></div>'; return; }
  ed.docs = d.data.map(r => ({ id: r.id, no: inn ? r.invoice_no : r.purchase_no, ref: inn ? null : r.invoice_number, date: inn ? r.sale_date : r.purchase_date, total: r.grand_total, due: r.balance_due, amt: '' }));
  const sumDue = ed.docs.reduce((a, x) => a + (dec(x.due, 2) ?? 0n), 0n), out = o.error || !o.data?.length ? null : dec(Number(o.data[0].outstanding).toFixed(2).replace('-', ''), 2) * (Number(o.data[0].outstanding) < 0 ? -1n : 1n);
  const opening = out === null ? 0n : out - sumDue;
  $('pbal').textContent = out === null ? '' : out > 0n ? (inn ? `This customer owes you ${moneyP(out)} in total.` : `You owe this supplier ${moneyP(out)} in total.`) : out < 0n ? `Advance of ${moneyP(-out)} on account.` : 'Nothing outstanding.';
  if (!ed.docs.length) {
    $('docswrap').innerHTML = `<div class="st"><h3>No unpaid invoices</h3><p>${inn ? 'This customer has no unpaid invoices.' : 'There are no unpaid purchases for this supplier.'}</p></div>${opening > 0n ? `<div class="note">${inn ? 'Their' : 'Your'} outstanding amount of ${moneyP(opening)} is an <b>opening balance</b>. Opening balances are not tied to an invoice, so they cannot be paid here. Update the opening balance on the ${inn ? 'Customers' : 'Suppliers'} page instead.</div>` : ''}`;
    $('payfields').hidden = true; $('esave').hidden = true; return;
  }
  $('docswrap').innerHTML = `${opening > 0n ? `<div class="note">${moneyP(opening)} of ${inn ? 'their' : 'your'} balance is an <b>opening balance</b> (not tied to an invoice), so it is not listed below and cannot be paid here.</div>` : ''}
    <div class="card2"><div class="top" style="margin:0 0 8px"><b>Unpaid invoices (oldest first)</b><div class="acts"><input id="alloc" inputmode="decimal" placeholder="Amount ${inn ? 'received' : 'paying'}" aria-label="Amount to allocate" style="width:150px"><button class="ghost" id="allocgo" type="button">Allocate oldest first</button><button class="ghost" id="payall" type="button">Pay all due</button></div></div>
    <div class="tw"><table class="pay"><thead><tr><th>${inn ? 'Invoice' : 'Purchase'}</th><th>Date</th><th class="r">Total</th><th class="r">Due</th><th class="r">Pay now (₹)</th></tr></thead><tbody>
    ${ed.docs.map((x, i) => `<tr><td><b>${esc(x.no)}</b>${x.ref ? `<span class="sub2">Inv: ${esc(x.ref)}</span>` : ''}</td><td>${fdate(x.date)}</td><td class="r">${money(x.total)}</td><td class="r">${money(x.due)}</td>
      <td class="r"><input data-i="${i}" inputmode="decimal" placeholder="0.00" aria-label="Pay now"> <button type="button" class="ghost" data-full="${i}" title="Pay the full due amount">Full</button></td></tr>`).join('')}</tbody></table></div>
    <div class="sum" style="margin-top:10px;max-width:340px;margin-left:auto"><span class="gt">Total ${inn ? 'received' : 'paid'}</span><span class="gt" id="ptotal">₹0.00</span></div></div>`;
  $('payfields').hidden = false; $('esave').hidden = false;
}
function sumAmounts() { return ed.docs.reduce((a, x) => a + (dec(x.amt, 2) ?? 0n), 0n); }
function refreshTotal() { const t = $('ptotal'); if (t) t.textContent = moneyP(sumAmounts()); }
function setAmt(i, b) { ed.docs[i].amt = b > 0n ? toInput(b) : ''; const el = document.querySelector(`#docswrap [data-i="${i}"]`); if (el) el.value = ed.docs[i].amt; }
function allocate(total) {
  let left = total;
  ed.docs.forEach((x, i) => { const due = dec(x.due, 2) ?? 0n, pay = left < due ? left : due; setAmt(i, pay); left -= pay; });
  refreshTotal();
  if (left > 0n) toast(`${moneyP(left)} is more than the total due, so it was not allocated.`, false);
}
function validate() {
  const errs = [];
  if (!ed.party) errs.push(`Select a ${ed.dir === 'in' ? 'customer' : 'supplier'}.`);
  let any = false;
  ed.docs.forEach(x => {
    if (String(x.amt).trim() === '') return;
    const a = dec(x.amt, 2), due = dec(x.due, 2);
    if (a === null) errs.push(`${x.no}: enter a valid amount (up to 2 decimals).`);
    else if (a > due) errs.push(`${x.no}: only ${money(x.due)} is due.`);
    else if (a > 0n) any = true;
    else errs.push(`${x.no}: amount must be more than 0.`);
  });
  if (!any && !errs.length) errs.push('Enter an amount for at least one invoice.');
  const d = $('edate').value; if (!d || isNaN(Date.parse(d))) errs.push('Enter a valid payment date.'); else if (d > today()) errs.push('Payment date cannot be in the future.');
  const box = $('eerr'); box.hidden = !errs.length; box.innerHTML = errs.length ? `<b>Please fix the following:</b><ul>${errs.map(e => `<li>${esc(e)}</li>`).join('')}</ul>` : '';
  if (errs.length) box.scrollIntoView({ behavior: 'smooth', block: 'center' });
  return errs;
}
async function submit() {
  if (busy || !ed?.party) return;
  if (ed.dir === 'out' && !canWrite()) return toast(ERR.NOT_ALLOWED, false);
  if (validate().length) return;
  const allocations = ed.docs.filter(x => (dec(x.amt, 2) ?? 0n) > 0n).map(x => ({ doc_id: x.id, amount: x.amt.trim() }));
  const payload = { company_id: cid, direction: ed.dir, party_id: ed.party.id, payment_method: $('epm').value, payment_date: $('edate').value, reference_number: $('eref').value.trim() || null, notes: $('enotes').value.trim() || null, allocations };
  busy = true; $('esave').disabled = true; toast('Saving payment…');
  try {
    const res = await db.rpc('record_payments', { p: payload });
    if (res.error) { fail(res.error, 'save', 'Payment was not saved. Nothing was changed.'); return; }
    const inn = ed.dir === 'in', who = ed.party.name;
    toast(`${res.data.receipt_no} saved. ${money(res.data.total)} ${inn ? 'received from' : 'paid to'} ${who}.`);
    closeForm(); page = 0; load(); loadStats();
  } catch (e) { fail(e, 'save', 'Payment was not saved. Nothing was changed.'); }
  finally { busy = false; const b = $('esave'); if (b) b.disabled = false; }
}
async function voidPayment(id) {
  const r = rows.find(x => x.id === id); if (!r || busy) return;
  const a = await ask({ title: `Void ${r.receipt_no}?`, msg: `${money(r.amount)} ${r.direction === 'in' ? 'received' : 'paid'} against ${r.doc_no} will be reversed: the invoice becomes unpaid by that amount again. The payment stays in the history marked as voided.`, ok: 'Void payment', back: 'Keep payment', danger: true, reason: true });
  if (!a) return;
  busy = true;
  try {
    const res = await db.rpc('void_payment', { p_id: id, p_reason: a.reason || null });
    if (res.error) { fail(res.error, 'void', 'Payment was not voided. Nothing was changed.'); return; }
    toast(`${r.receipt_no} voided. ${r.doc_no} is unpaid by ${money(r.amount)} again.`); load(); loadStats();
  } catch (e) { fail(e, 'void', 'Payment was not voided. Nothing was changed.'); } finally { busy = false; }
}

function wire() {
  const reload = () => { page = 0; load(); };
  $('q').oninput = () => { clearTimeout(timer); timer = setTimeout(reload, 300); };
  ['ftype', 'fkind', 'fmeth', 'fst', 'dfrom', 'dto'].forEach(i => $(i).onchange = reload);
  $('fdate').onchange = () => { const c = $('fdate').value === 'custom'; $('dfrom').hidden = $('dto').hidden = !c; reload(); };
  $('prev').onclick = () => { page--; load(); }; $('next').onclick = () => { page++; load(); };
  $('recv').onclick = () => openForm('in'); $('payout').onclick = () => openForm('out');
  $('state').onclick = e => { if (e.target.id === 'retry') load(); if (e.target.id === 'empty-recv') openForm('in'); };
  $('rows').onclick = e => { const b = e.target.closest('button[data-act]'); if (b && b.dataset.act === 'void' && canWrite()) voidPayment(b.dataset.id); };
  const ev = $('editView');
  ev.onclick = e => {
    const t = e.target;
    if (t.id === 'ebk') return closeForm();
    if (t.id === 'esave') return submit();
    if (t.id === 'pchg') { ed.party = null; ed.docs = []; renderParty(); return; }
    if (t.id === 'allocgo') { const a = dec($('alloc').value, 2); if (a === null || a <= 0n) return toast('Enter an amount greater than 0 to allocate.', false); return allocate(a); }
    if (t.id === 'payall') { ed.docs.forEach((x, i) => setAmt(i, dec(x.due, 2) ?? 0n)); refreshTotal(); return; }
    const full = t.closest('[data-full]'); if (full) { const i = +full.dataset.full; setAmt(i, dec(ed.docs[i].due, 2) ?? 0n); refreshTotal(); }
  };
  ev.addEventListener('input', e => {
    const t = e.target;
    if (t.id === 'pq') { clearTimeout(timer); timer = setTimeout(() => searchParty(t), 250); return; }
    if (t.dataset.i !== undefined && t.closest('table.pay')) { ed.docs[+t.dataset.i].amt = t.value; refreshTotal(); }
  });
  ev.addEventListener('keydown', e => { if (e.target.id === 'pq') PopList.key(e); });
  $('out').onclick = async e => { e.preventDefault(); await db.auth.signOut(); location.replace('login.html'); };
  db.auth.onAuthStateChange(evt => { if (evt === 'SIGNED_OUT') location.replace('login.html'); });
}

function init() { shell(); wire(); return boot(); }
async function boot() {
  $('state').innerHTML = ''; $('tw').hidden = false;
  $('rows').innerHTML = '<tr><td colspan="9"><div class="sk"></div></td></tr>'.repeat(3);
  const { data: { session } } = await db.auth.getSession();
  if (!session) return location.replace('login.html');
  const { data: m, error } = await db.from('company_members').select('company_id,role,companies(name)').eq('user_id', session.user.id).limit(1);
  if (error) {
    const f = fail(error, 'membership'); $('rows').innerHTML = '';
    return setState(`<div class="st"><h3>Unable to load payments.</h3><p>${esc(f.auth ? f.text : 'Please check your connection and try again.')}</p><button id="retry-init">Try again</button></div>`);
  }
  if (!m.length) return location.replace('login.html');
  cid = m[0].company_id; role = m[0].role;
  $('who').textContent = `${m[0].companies?.name || ''} · ${role}`; $('payout').hidden = !canWrite();
  await Promise.all([load(), loadStats()]);
}
document.addEventListener('click', e => { if (e.target.id === 'retry-init') boot().catch(x => fail(x, 'retry')); });
init().catch(e => { console.error(e); toast('Something went wrong. Please refresh the page.', false); });
})();
