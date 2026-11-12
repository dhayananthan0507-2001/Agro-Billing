// Reports & analytics (Phase 7, Step 2).
// Every figure is calculated by a read-only database function (sql/phase7_step2_reports.sql) for the logged-in user's shop. Financial reports are refused by
// the DATABASE for anyone but an owner or manager; a cashier is only offered Low stock and Expiry (no costs). This page just displays what the database returns.
(() => {
const db = client(), T = Tools, { esc, money, num, fdate } = T, $$ = id => document.getElementById(id);
const FIN = [['overview', 'Overview'], ['sales', 'Sales'], ['purchases', 'Purchases'], ['products', 'Profit & margin'], ['stock', 'Stock value'], ['low', 'Low stock'], ['expiry', 'Expiry'], ['out', 'Outstanding'], ['expenses', 'Expenses'], ['gst', 'GST summary']];
const STOCKONLY = [['low', 'Low stock'], ['expiry', 'Expiry']];
const NOPERIOD = ['stock', 'low', 'expiry', 'out'], GROUPED = ['sales', 'purchases', 'expenses'];
const FN = { overview: 'report_overview', sales: 'report_sales', purchases: 'report_purchases', products: 'report_products', stock: 'report_stock_value', low: 'report_low_stock', expiry: 'report_expiry', out: 'report_outstanding', expenses: 'report_expenses', gst: 'report_gst' };
let cid, role, tabs = FIN, tab = 'overview', per = 'month', group = 'day', okind = 'customer', xdays = '', ex = null, reqId = 0;
const ERR = { NOT_ALLOWED: 'You do not have access to this report.', INVALID_RANGE: 'Choose a start date that is not after the end date.', RANGE_TOO_LARGE: 'Please choose a period of about 3 years or less.', INVALID_DAYS: 'Choose a number of days between 0 and 365.' };
function fail(e, ctx) { console.error('[reports]', ctx, e); const m = e?.message || '', t = ERR[m] || (/jwt|expired/i.test(m) ? 'Your session has expired. Please sign in again.' : /failed to fetch|network/i.test(m) ? 'Network problem. Please check your connection and try again.' : 'Something went wrong. Please try again.'); T.toast(t, false); if (/jwt|expired/i.test(m)) setTimeout(() => location.replace('login.html'), 1500); return t; }
const label = (p, g) => g === 'month' ? new Date(p + 'T00:00:00').toLocaleDateString('en-IN', { month: 'short', year: 'numeric' }) : g === 'week' ? 'Week of ' + fdate(p) : fdate(p);
const tbl = (head, rows, foot) => `<div class="tw"><table><thead><tr>${head.map(h => `<th${h.startsWith('>') ? ' class="rt"' : ''}>${esc(h.replace(/^>/, ''))}</th>`).join('')}</tr></thead><tbody>${rows.length ? rows.join('') : `<tr><td colspan="${head.length}" class="hint">No data for this period.</td></tr>`}${foot || ''}</tbody></table></div>`;
const cell = c => `<td${typeof c === 'object' && c !== null && c.r ? ' class="rt"' : ''}>${typeof c === 'object' && c !== null ? c.h : esc(c)}</td>`;
const tr = cells => `<tr>${cells.map(cell).join('')}</tr>`, foot = cells => `<tr class="tot-row">${cells.map(cell).join('')}</tr>`;
const R = v => ({ r: 1, h: esc(money(v)) }), N = (v, u) => ({ r: 1, h: esc(num(v) + (u ? ' ' + u : '')) }), H = h => ({ r: 1, h });
const card = (k, v, h) => `<div class="card"><small>${esc(k)}</small><b>${esc(v)}</b>${h ? `<span class="hint">${esc(h)}</span>` : ''}</div>`;
const section = (title, body) => `<div class="sec"><h3>${esc(title)}</h3>${body}</div>`;
const periodRows = d => d.rows.map(r => [label(r.period, group), r.bills]);

function shell() {
  const fin = tabs === FIN;
  $$('app').innerHTML = `
  <div class="top"><div><h2>Reports</h2><p class="sub">${fin ? 'Sales, purchases, margin, stock, outstanding amounts, expenses and GST for your shop.' : 'Low stock and expiry reports for your shop.'}</p><small id="who"></small></div><div class="acts noprint"><button id="print" class="ghost">Print</button><button id="csv" class="ghost" disabled>Export CSV</button></div></div>
  <div class="tabs noprint" role="tablist">${tabs.map(([k, l]) => `<button data-tab="${k}"${k === tab ? ' class="on"' : ''}>${l}</button>`).join('')}</div>
  <div class="bar noprint" id="pbar"><select id="per" aria-label="Period">${T.presetOptions(per).replace('<option value="">Any date</option>', '')}</select>
    <input id="from" type="date" aria-label="From date" hidden><input id="to" type="date" aria-label="To date" hidden>
    <select id="grp" aria-label="Group by"><option value="day">Daily</option><option value="week">Weekly</option><option value="month">Monthly</option></select>
    <select id="okind" aria-label="Customers or suppliers"><option value="customer">Customers who owe you</option><option value="supplier">Suppliers you are owed to pay</option></select>
    <select id="xdays" aria-label="Expiry window"><option value="">Expiry window: shop setting</option><option value="15">Next 15 days</option><option value="30">Next 30 days</option><option value="60">Next 60 days</option><option value="90">Next 90 days</option><option value="180">Next 180 days</option></select></div>
  <div id="body"></div>`;
  $$('okind').options[1].textContent = 'Suppliers you owe';
  syncBar();
}
function syncBar() {
  const dated = !NOPERIOD.includes(tab);
  $$('per').hidden = !dated; $$('from').hidden = $$('to').hidden = !dated || per !== 'custom';
  $$('grp').hidden = !GROUPED.includes(tab); $$('okind').hidden = tab !== 'out'; $$('xdays').hidden = tab !== 'expiry';
  $$('pbar').hidden = !(dated || tab === 'out' || tab === 'expiry');
}
function args() {
  const [from, to] = T.range(per, $$('from').value, $$('to').value), a = { p_company: cid };
  if (!NOPERIOD.includes(tab)) { a.p_from = from; a.p_to = to; }
  if (GROUPED.includes(tab)) a.p_group = group;
  if (tab === 'out') a.p_kind = okind;
  if (tab === 'products') a.p_limit = 300;
  if (tab === 'expiry') a.p_days = xdays === '' ? null : Number(xdays);
  return a;
}
function noteMargin(m) {
  const rev = Number(m.revenue), unc = Number(m.revenue_uncosted), costed = Number(m.revenue_costed);
  return (rev === 0 ? '<div class="infobox">There are no sales in this period.</div>'
    : costed === 0 ? `<div class="warnbox"><b>Margin not available.</b> None of the ${money(rev)} in sales has a recorded purchase cost, so no margin is shown. Nothing is guessed.</div>`
    : unc > 0 ? `<div class="warnbox"><b>Estimate.</b> The margin covers ${money(costed)} of ${money(rev)} in sales. ${money(unc)} (${m.products_cost_missing} product${m.products_cost_missing === 1 ? '' : 's'}) is left out because the stock sold has no recorded purchase cost. No cost is guessed.</div>`
    : '<div class="infobox"><b>Estimate.</b> Every sale in this period has a recorded purchase cost.</div>')
    + '<p class="hint">Estimated gross margin = sales (excluding GST, after discounts) − the purchase cost of the batches the stock was actually taken from. It is <b>not net profit</b>: expenses and other costs are not deducted.</p>';
}
const mismatchNote = n => n > 0 ? `<div class="warnbox"><b>Check needed.</b> ${n} invoice${n === 1 ? '' : 's'} show a due amount that differs from its payment records. The figures here follow the payment records.</div>` : '';
const RENDER = {
  overview(d) {
    const s = d.sales, p = d.purchases, m = d.margin, sv = d.stock_value, lo = d.low_stock, xp = d.expiry, cov = Number(m.revenue) > 0 ? Math.round(Number(m.revenue_costed) / Number(m.revenue) * 100) : null;
    ex = { name: 'overview', head: ['Measure', 'Amount'], rows: [['Sales incl. GST', s.total], ['Net sales excl. GST', s.net], ['GST on sales', s.gst], ['Money received', d.received], ['Purchases incl. GST', p.total], ['Expenses', d.expenses_total], ['Estimated gross margin', m.margin], ['Customers owe you (today)', d.receivable], ['You owe suppliers (today)', d.payable], ['Stock value at batch cost (today)', sv.value], ['Low stock products (today)', lo.low], ['Out of stock products (today)', lo.out], ['Expired batches (today)', xp.expired]] };
    return `<div class="cards s5" style="margin-top:14px">${[card('Sales (incl. GST)', money(s.total), `${s.bills} bill${s.bills === 1 ? '' : 's'}`), card('Net sales (excl. GST)', money(s.net), 'after bill discounts'), card('GST on sales', money(s.gst)), card('Money received', money(d.received), 'from payment records'),
      card('Purchases (incl. GST)', money(p.total), `${p.bills} bill${p.bills === 1 ? '' : 's'}`), card('Expenses', money(d.expenses_total)), card('Estimated gross margin', Number(m.revenue_costed) > 0 ? money(m.margin) : 'Not available', cov === null ? 'no sales' : `estimate · ${cov}% of sales costed · not profit`),
      card('Customers owe you', money(d.receivable), 'as of today'), card('You owe suppliers', money(d.payable), 'as of today'), card('Stock value', money(sv.value), sv.products_cost_missing > 0 ? `${sv.products_cost_missing} product(s) without cost` : 'at batch purchase cost'),
      card('Low / out of stock', `${lo.low} / ${lo.out}`, 'products, as of today'), card('Expired / expiring', `${xp.expired} / ${xp.expiring_soon}`, `batches, next ${d.expiry_days} days`)].join('')}</div>
      ${noteMargin(m)}${mismatchNote(d.ledger_mismatch)}<p class="hint">Sales, purchases, expenses, money received and margin follow the period above. Owed amounts, stock value and stock alerts are as of today. Open a tab for the detail.</p>`;
  },
  sales(d) {
    const t = d.totals; ex = { name: 'sales', head: ['Period', 'Bills', 'Net (excl. GST)', 'GST', 'Total', 'Paid', 'Due'], rows: d.rows.map(r => [label(r.period, group), r.bills, r.net, r.gst, r.total, r.paid, r.due]) };
    return `<div class="cards s5" style="margin-top:14px">${[card('Total sales', money(t.total), 'incl. GST'), card('Bills', num(t.bills, 0)), card('Net sales', money(t.net), 'excl. GST'), card('Money received', money(d.received.total), 'payments in this period'), card('Still due', money(t.due), 'on these bills')].join('')}</div>`
      + tbl(['Period', '>Bills', '>Net (excl. GST)', '>GST', '>Total', '>Paid', '>Due'], d.rows.map(r => tr([label(r.period, group), N(r.bills), R(r.net), R(r.gst), R(r.total), R(r.paid), R(r.due)])), foot(['Total', N(t.bills), R(t.net), R(t.gst), R(t.total), R(t.paid), R(t.due)]))
      + `<p class="hint">Cancelled bills are left out (${d.cancelled.bills} bill${d.cancelled.bills === 1 ? '' : 's'}, ${money(d.cancelled.total)}).</p>`
      + section('Bills by payment method', tbl(['Method', '>Bills', '>Total'], d.by_method.map(r => tr([r.method.toUpperCase(), N(r.bills), R(r.total)]))))
      + section('Money received in this period (payment records)', tbl(['Method', '>Payments', '>Amount'], d.received.rows.map(r => tr([r.method.replace('_', ' ').toUpperCase(), N(r.payments), R(r.total)])), d.received.rows.length ? foot(['Total', '', R(d.received.total)]) : '')
        + '<p class="hint">Includes later payments on older bills, by the date each payment was recorded. Voided payments and payments on cancelled bills are left out.</p>');
  },
  purchases(d) {
    const t = d.totals; ex = { name: 'purchases', head: ['Period', 'Bills', 'Net (excl. GST)', 'GST', 'Total', 'Paid', 'Due'], rows: d.rows.map(r => [label(r.period, group), r.bills, r.net, r.gst, r.total, r.paid, r.due]) };
    return `<div class="cards s5" style="margin-top:14px">${[card('Total purchases', money(t.total), 'incl. GST'), card('Bills', num(t.bills, 0)), card('Net purchases', money(t.net), 'excl. GST, incl. extra charges'), card('Paid', money(t.paid)), card('Still due to suppliers', money(t.due), 'on these bills')].join('')}</div>`
      + tbl(['Period', '>Bills', '>Net (excl. GST)', '>GST', '>Total', '>Paid', '>Due'], d.rows.map(r => tr([label(r.period, group), N(r.bills), R(r.net), R(r.gst), R(r.total), R(r.paid), R(r.due)])), foot(['Total', N(t.bills), R(t.net), R(t.gst), R(t.total), R(t.paid), R(t.due)]))
      + `<p class="hint">Drafts and cancelled purchases are left out (${d.cancelled.bills} cancelled, ${money(d.cancelled.total)}).</p>`
      + section('By supplier', tbl(['Supplier', '>Bills', '>Total', '>Paid', '>Due'], d.by_supplier.map(r => tr([r.name, N(r.bills), R(r.total), R(r.paid), R(r.due)]))));
  },
  products(d) {
    const t = d.totals; ex = { name: 'profit-margin', head: ['Product', 'Qty sold', 'Sales (excl. GST)', 'Cost of stock sold', 'Estimated margin', 'Margin %', 'Cost recorded'], rows: d.rows.map(r => [r.product_name, r.quantity, r.revenue, r.cost ?? '', r.margin ?? '', r.margin_pct ?? '', r.cost_missing ? 'no' : 'yes']) };
    const dash = { r: 1, h: '<span class="hint">—</span>' };
    return `<div class="cards s5" style="margin-top:14px">${[card('Sales (excl. GST)', money(t.revenue)), card('Sales with a recorded cost', money(t.revenue_costed)), card('Cost of that stock', money(t.cost)), card('Estimated gross margin', Number(t.revenue_costed) > 0 ? money(t.margin) : 'Not available', 'estimate · not net profit')].join('')}</div>`
      + noteMargin(t) + tbl(['Product', '>Qty sold', '>Sales (excl. GST)', '>Cost of stock sold', '>Estimated margin', '>Margin %'],
        d.rows.map(r => tr([r.product_name + (r.cost_missing ? '  ⚠ cost not recorded' : ''), N(r.quantity, r.unit), R(r.revenue), r.cost == null ? dash : R(r.cost), r.margin == null ? dash : H(`<span class="${Number(r.margin) >= 0 ? 'up' : 'down'}">${esc(money(r.margin))}</span>`), r.margin_pct == null ? dash : H(esc(r.margin_pct + '%'))])),
        foot(['Total (products with a recorded cost)', '', R(t.revenue_costed), R(t.cost), R(t.margin), Number(t.revenue_costed) > 0 ? H(esc(Math.round(Number(t.margin) / Number(t.revenue_costed) * 1000) / 10 + '%')) : '']))
      + `<p class="hint">Sales are shown excluding GST, with each bill's discount shared across its lines in proportion. Showing the top ${d.rows.length} of ${t.products} products by sales.</p>`;
  },
  stock(d) {
    const t = d.totals; ex = { name: 'stock-value', head: ['Product', 'Quantity', 'Value at batch cost', 'Average cost', 'Quantity with no recorded cost'], rows: d.rows.map(r => [r.product_name, r.quantity, r.value, r.avg_cost ?? '', r.cost_missing_qty]) };
    return `<div class="cards s5" style="margin-top:14px">${[card('Stock value', money(t.value), 'at batch purchase cost'), card('Products in stock', num(t.products, 0)), card('Products with no recorded cost', num(t.products_cost_missing, 0), 'not valued')].join('')}</div>`
      + (t.products_cost_missing > 0 ? `<div class="warnbox"><b>Incomplete.</b> ${t.products_cost_missing} product${t.products_cost_missing === 1 ? ' has' : 's have'} stock in batches with no recorded cost. That stock is counted in the quantity but given <b>no value</b>; nothing is guessed.</div>` : '')
      + tbl(['Product', '>Quantity', '>Average cost', '>Value', '>Quantity with no recorded cost'], d.rows.map(r => tr([r.product_name + (r.active ? '' : ' (archived)'), N(r.quantity, r.unit), r.avg_cost == null ? H('—') : R(r.avg_cost), R(r.value), N(r.cost_missing_qty)])), foot(['Total value', '', '', R(t.value), '']))
      + '<p class="hint">Every batch is valued at its own recorded purchase price, never at the selling price. The "Stock value" card on the Products page uses each product\'s current purchase price instead, so the two can differ.</p>';
  },
  low(d) {
    ex = { name: 'low-stock', head: ['Product', 'In stock', 'Alert level', 'Level from', 'Status'], rows: d.rows.map(r => [r.product_name, r.quantity, r.threshold, r.uses_default ? 'shop default' : 'product minimum', r.status === 'out' ? 'Out of stock' : 'Low stock']) };
    return `<div class="cards s5" style="margin-top:14px">${[card('Low stock', num(d.counts.low, 0), 'products at or below their level'), card('Out of stock', num(d.counts.out, 0), 'products with none left'), card('Shop default level', num(d.low_default, 0), d.low_default > 0 ? 'used when a product has no minimum' : 'no default: only products with a minimum are checked')].join('')}</div>`
      + tbl(['Product', '>In stock', '>Alert level', 'Level from', 'Status'], d.rows.map(r => tr([r.product_name, N(r.quantity, r.unit), N(r.threshold, r.unit), r.uses_default ? 'shop default' : 'product minimum', H(`<span class="b ${r.status === 'out' ? 'out' : 'low'}">${r.status === 'out' ? 'Out of stock' : 'Low stock'}</span>`)])))
      + '<p class="hint">A product is low when its quantity is at or below its own minimum stock; when the product has no minimum (0), the shop default level applies. Only active products are listed.</p>';
  },
  expiry(d) {
    const cost = d.show_cost, list = (title, rows, soon) => section(`${title} (${rows.length})`, tbl(['Product', 'Batch', 'Expiry date', '>Days', '>Quantity', ...(cost ? ['>Cost value'] : [])],
      rows.map(r => tr([r.product_name, r.batch_number, fdate(r.expiry_date), H(`<span class="${r.days < 0 ? 'down' : ''}">${soon ? (r.days === 0 ? 'today' : r.days + ' d') : 'expired ' + (-r.days) + ' d ago'}</span>`), N(r.quantity, r.unit), ...(cost ? [Number(r.cost) > 0 ? R(r.value) : H('<span class="hint">cost not recorded</span>')] : [])]))));
    ex = { name: 'expiry', head: ['Status', 'Product', 'Batch', 'Expiry date', 'Days', 'Quantity', ...(cost ? ['Cost value'] : [])], rows: [...d.expired.map(r => ['Expired', r.product_name, r.batch_number, r.expiry_date, r.days, r.quantity, ...(cost ? [r.value ?? ''] : [])]), ...d.expiring_soon.map(r => ['Expiring soon', r.product_name, r.batch_number, r.expiry_date, r.days, r.quantity, ...(cost ? [r.value ?? ''] : [])])] };
    return `<div class="cards s5" style="margin-top:14px">${[card('Expired batches', num(d.counts.expired, 0), 'with stock still on the shelf'), card(`Expiring in ${d.days} days`, num(d.counts.expiring_soon, 0), 'batches')].join('')}</div>`
      + list('Expired', d.expired, false) + list(`Expiring within ${d.days} days`, d.expiring_soon, true)
      + `<p class="hint">Only batches that still have stock are listed. ${cost ? 'Cost value is the batch quantity at its recorded purchase price.' : 'Cost values are visible to owners and managers only.'}</p>`;
  },
  out(d) {
    const t = d.totals, cust = okind === 'customer'; ex = { name: cust ? 'customers-outstanding' : 'suppliers-outstanding', head: ['Name', 'Phone', 'Opening balance', 'Unpaid invoices', 'Outstanding', '0-30 days', '31-60 days', '61-90 days', '90+ days'], rows: d.rows.map(r => [r.name, r.phone, r.opening, r.invoices, r.outstanding, r.d0_30, r.d31_60, r.d61_90, r.d90_plus]) };
    return `<div class="cards s5" style="margin-top:14px">${[card(cust ? 'Customers owe you' : 'You owe suppliers', money(t.outstanding), 'in total'), card(cust ? 'Customers with a balance' : 'Suppliers with a balance', num(t.parties, 0)), card('Opening balances', money(t.opening)), card('Unpaid invoices', money(t.invoices))].join('')}</div>`
      + mismatchNote(d.ledger_mismatch)
      + tbl([cust ? 'Customer' : 'Supplier', 'Phone', '>Opening balance', '>Unpaid invoices', '>Outstanding', '>0–30 days', '>31–60', '>61–90', '>90+'],
        d.rows.map(r => tr([r.name, r.phone || '', R(r.opening), R(r.invoices), R(r.outstanding), R(r.d0_30), R(r.d31_60), R(r.d61_90), R(r.d90_plus)])), foot(['Total (' + t.parties + ')', '', R(t.opening), R(t.invoices), R(t.outstanding), '', '', '', '']))
      + `<p class="hint">${cust ? 'Amounts customers owe you' : 'Amounts you owe suppliers'}: opening balance plus each invoice's total minus its recorded payments (cancelled invoices and voided payments excluded). Ageing counts the days since each unpaid invoice date; the opening balance is not aged. A negative amount means an advance in the other direction.</p>`;
  },
  expenses(d) {
    ex = { name: 'expenses', head: ['Category', 'Entries', 'Total'], rows: d.by_category.map(r => [r.category, r.count, r.total]) };
    return `<div class="cards s5" style="margin-top:14px">${[card('Total expenses', money(d.total)), card('Entries', num(d.count, 0)), card('Cancelled (left out)', money(d.cancelled.total), `${d.cancelled.count} entr${d.cancelled.count === 1 ? 'y' : 'ies'}`)].join('')}</div>`
      + section('By category', tbl(['Category', '>Entries', '>Total', '>Share'], d.by_category.map(r => tr([r.category, N(r.count), R(r.total), H(esc(Number(d.total) > 0 ? Math.round(Number(r.total) / Number(d.total) * 100) + '%' : ''))])), foot(['Total', N(d.count), R(d.total), ''])))
      + section('By period', tbl(['Period', '>Entries', '>Total'], d.rows.map(r => tr([label(r.period, group), N(r.count), R(r.total)])), foot(['Total', N(d.count), R(d.total)])));
  },
  gst(d) {
    const t = d.totals; ex = { name: 'gst-sales', head: ['GST rate %', 'Lines', 'Taxable value', 'GST'], rows: d.rows.map(r => [Number(r.rate), r.lines, r.taxable, r.tax]) };
    return `<div class="cards s5" style="margin-top:14px">${[card('GST on sales', money(t.tax)), card('Taxable value', money(t.taxable), 'before bill-level discounts'), card('Bills', num(t.bills, 0)), card('Bill discounts', money(d.bill_discount), 'reported apart')].join('')}</div>`
      + tbl(['GST rate', '>Lines', '>Taxable value', '>GST'], d.rows.map(r => tr([Number(r.rate) + '%', N(r.lines), R(r.taxable), R(r.tax)])), foot(['Total', '', R(t.taxable), R(t.tax)]))
      + '<div class="warnbox"><b>Read this first.</b> This is a rate-wise summary of the GST recorded on <b>sales</b> lines. It is not a GST return: there is no HSN breakdown and no CGST / SGST / IGST split. Taxable value is each line before any bill-level discount (GST is not recomputed after a bill discount), so bill discounts are shown separately.</div>';
  }
};
async function load() {
  const my = ++reqId, body = $$('body'); ex = null; $$('csv').disabled = true;
  if (per === 'custom' && !NOPERIOD.includes(tab) && (!$$('from').value || !$$('to').value)) { body.innerHTML = '<div class="st"><h3>Choose both dates</h3><p>Pick a start and an end date.</p></div>'; return; }
  body.innerHTML = '<div class="sk" style="margin-top:14px"></div><div class="sk"></div>';
  const { data, error } = await db.rpc(FN[tab], args());
  if (my !== reqId) return;
  if (error) { const t = fail(error, tab); body.innerHTML = `<div class="st"><h3>Unable to load this report.</h3><p>${esc(t)}</p><button id="retry">Try again</button></div>`; return; }
  const [from, to] = T.range(per, $$('from').value, $$('to').value);
  body.innerHTML = (NOPERIOD.includes(tab) ? `<p class="hint" style="margin:10px 0 0">As of today, ${fdate(T.today())}</p>` : `<p class="hint" style="margin:10px 0 0">${fdate(from)} – ${fdate(to)} · cancelled and draft documents excluded</p>`) + RENDER[tab](data);
  $$('csv').disabled = !ex;
}
function wire() {
  $$('app').querySelector('.tabs').onclick = e => { const b = e.target.closest('button[data-tab]'); if (!b) return; tab = b.dataset.tab; document.querySelectorAll('.tabs button').forEach(x => x.classList.toggle('on', x === b)); syncBar(); load(); };
  $$('per').onchange = () => { per = $$('per').value; syncBar(); load(); };      // for a custom range load() shows "Choose both dates" until both are filled in
  $$('from').onchange = $$('to').onchange = () => { if (per === 'custom') load(); };
  $$('grp').onchange = () => { group = $$('grp').value; load(); }; $$('okind').onchange = () => { okind = $$('okind').value; load(); }; $$('xdays').onchange = () => { xdays = $$('xdays').value; load(); };
  $$('print').onclick = () => window.print();
  $$('csv').onclick = () => { if (!ex) return; const [f, t] = NOPERIOD.includes(tab) ? [T.today(), ''] : T.range(per, $$('from').value, $$('to').value); T.csv(`report-${ex.name}-${f}${t ? '-to-' + t : ''}.csv`, ex.head, ex.rows); };
  $$('body').onclick = e => { if (e.target.id === 'retry') load(); };
  $$('out').onclick = async e => { e.preventDefault(); await db.auth.signOut(); location.replace('login.html'); };
  db.auth.onAuthStateChange(evt => { if (evt === 'SIGNED_OUT') location.replace('login.html'); });
}
async function boot() {
  const { data: { session } } = await db.auth.getSession();
  if (!session) return location.replace('login.html');
  const { data: m, error } = await db.from('company_members').select('company_id,role,companies(name)').eq('user_id', session.user.id).limit(1);
  if (error) { const t = fail(error, 'membership'); $$('app').innerHTML = `<div class="st" style="margin-top:20px"><h3>Unable to load reports.</h3><p>${esc(t)}</p><button id="retry-init">Try again</button></div>`; return; }
  if (!m.length) return location.replace('login.html');
  cid = m[0].company_id; role = m[0].role;
  if (role === 'owner' || role === 'manager') { tabs = FIN; tab = 'overview'; } else { tabs = STOCKONLY; tab = 'low'; }   // the database enforces this too
  shell(); wire(); $$('who').textContent = `${m[0].companies?.name || ''} · ${role}`; $$('grp').value = group; await load();
}
document.addEventListener('click', e => { if (e.target.id === 'retry-init') boot().catch(x => fail(x, 'retry')); });
boot().catch(e => { console.error(e); T.toast('Something went wrong. Please refresh the page.', false); });
})();
