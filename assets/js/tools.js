// Small helpers shared by the Phase 7 pages (stock, statement, reports). Older pages keep their own copies and are not affected.
window.Tools = (() => {
  const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const money = v => '₹' + Number(v || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const num = (v, d = 3) => Number(v ?? 0).toLocaleString('en-IN', { maximumFractionDigits: d });
  const pad = n => String(n).padStart(2, '0');
  const iso = d => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
  const today = () => iso(new Date());
  const fdate = s => s ? new Date(String(s).slice(0, 10) + 'T00:00:00').toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '—';
  const fdt = s => s ? new Date(s).toLocaleString('en-IN', { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '—';
  const uuid = () => (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random() * 16 | 0; return (c === 'x' ? r : (r & 3 | 8)).toString(16); });
  const dec = (str, scale) => { const s = String(str ?? '').trim(); if (s === '') return 0n; if (!/^\d+(\.\d+)?$/.test(s)) return null; const [i, f = ''] = s.split('.'); if (f.length > scale) return null; return BigInt(i + f.padEnd(scale, '0')); };
  const toast = (t, ok = true) => { const e = document.getElementById('toast'); e.textContent = t; e.style.background = ok ? '#1f4d2b' : '#a32020'; e.style.display = 'block'; clearTimeout(toast.t); toast.t = setTimeout(() => e.style.display = 'none', 5000); };
  // Financial year runs April - March. "This financial year" ends today; "Last financial year" is the full previous April-March.
  const fyStart = d => new Date(d.getMonth() >= 3 ? d.getFullYear() : d.getFullYear() - 1, 3, 1);
  const PRESETS = [['', 'Any date'], ['today', 'Today'], ['week', 'This week'], ['month', 'This month'], ['lastmonth', 'Last month'], ['fy', 'This financial year (Apr–Mar)'], ['lastfy', 'Last financial year'], ['custom', 'Custom range…']];
  const range = (v, from, to, now = new Date()) => {
    if (v === 'today') return [iso(now), iso(now)];
    if (v === 'week') { const d = new Date(now); d.setDate(d.getDate() - ((d.getDay() + 6) % 7)); return [iso(d), iso(now)]; }
    if (v === 'month') return [iso(new Date(now.getFullYear(), now.getMonth(), 1)), iso(now)];
    if (v === 'lastmonth') return [iso(new Date(now.getFullYear(), now.getMonth() - 1, 1)), iso(new Date(now.getFullYear(), now.getMonth(), 0))];
    if (v === 'fy') return [iso(fyStart(now)), iso(now)];
    if (v === 'lastfy') { const s = fyStart(now); return [iso(new Date(s.getFullYear() - 1, 3, 1)), iso(new Date(s.getFullYear(), 2, 31))]; }
    if (v === 'custom') return [from || null, to || null];
    return [null, null];
  };
  const presetOptions = sel => PRESETS.map(([k, l]) => `<option value="${k}"${k === sel ? ' selected' : ''}>${l}</option>`).join('');
  const csv = (name, head, rows) => {
    const q = v => { const s = String(v ?? ''); return /[",\n]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
    const blob = new Blob(['\ufeff' + [head, ...rows].map(r => r.map(q).join(',')).join('\r\n')], { type: 'text/csv;charset=utf-8' });
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name; document.body.appendChild(a); a.click(); a.remove(); setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  };
  // Confirmation dialog: expects <dialog id="cdlg"> with #ct #cm #cno #cyes in the page.
  const ask = ({ title, msg, ok = 'Confirm', danger = false, back = 'Go back' }) => new Promise(res => {
    const d = document.getElementById('cdlg'), $ = id => document.getElementById(id);
    $('ct').textContent = title; $('cm').textContent = msg; $('cno').textContent = back;
    const y = $('cyes'); y.textContent = ok; y.className = danger ? 'danger' : '';
    let done = false; const fin = v => { if (done) return; done = true; d.onclose = null; if (d.open) d.close(); res(v); };
    y.onclick = () => fin(true); $('cno').onclick = () => fin(false); d.onclose = () => fin(false); d.showModal();
  });
  return { esc, money, num, pad, iso, today, fdate, fdt, uuid, dec, toast, range, presetOptions, csv, ask, fyStart };
})();
