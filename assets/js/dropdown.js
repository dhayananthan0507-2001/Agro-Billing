// Shared pop-up list for search-as-you-type pickers (products, customers, suppliers).
// WHY: a list rendered inside a table cell or card is clipped by any ancestor with overflow:auto/hidden (the item tables
// sit inside .tw { overflow-x:auto }, which also forces overflow-y:auto), and z-index cannot escape that. So the list is
// lifted out of the layout: appended to <body> (or to the enclosing <dialog>, so it also shows inside a modal) and placed
// with position:fixed from the input's on-screen rectangle. It opens downward when there is room, otherwise upward, never
// leaves the viewport, scrolls when long, and follows the input on scroll/resize.
window.PopList = (() => {
  let el = null, anchor = null, onPick = null, active = -1;
  const CSS = `#poplist{position:fixed;z-index:2147483000;background:#fff;border:1px solid #cfd8c7;border-radius:10px;box-shadow:0 8px 24px #0004;overflow-y:auto;overscroll-behavior:contain;font:14px system-ui,sans-serif;box-sizing:border-box}
#poplist[hidden]{display:none}
#poplist button{display:block;width:100%;text-align:left;background:none;color:#222;border:0;border-bottom:1px solid #eef2ea;border-radius:0;padding:9px 12px;font:500 14px system-ui,sans-serif;cursor:pointer}
#poplist button:last-child{border-bottom:0}#poplist button:hover,#poplist button.act{background:#eef5e9}
#poplist b{display:block;font-weight:700}#poplist .hint{display:block;color:#6b7a63;font-size:.82rem;font-weight:400}
#poplist .row2{display:flex;justify-content:space-between;gap:14px;color:#6b7a63;font-size:.85rem;font-weight:400}#poplist .none{padding:10px 12px;color:#6b7a63}`;
  function ensure(host) {
    if (!el) {
      const st = document.createElement('style'); st.textContent = CSS; document.head.appendChild(st);
      el = document.createElement('div'); el.id = 'poplist'; el.setAttribute('role', 'listbox'); el.hidden = true;
      el.addEventListener('mousedown', e => {                 // mousedown (not click) so the input keeps focus and the list isn't closed first
        e.preventDefault(); const b = e.target.closest('[data-i]'); if (!b || !onPick) return;
        const cb = onPick, i = +b.dataset.i; hide(); cb(i);
      });
      document.addEventListener('mousedown', e => { if (el && !el.hidden && !el.contains(e.target) && e.target !== anchor) hide(); }, true);
      document.addEventListener('focusin', e => { if (el && !el.hidden && e.target !== anchor && !el.contains(e.target)) hide(); });
      window.addEventListener('resize', place);
      window.addEventListener('scroll', e => { if (e.target !== el) place(); }, true);   // ignore scrolling inside the list itself
    }
    if (el.parentNode !== host) host.appendChild(el);
  }
  function place() {
    if (!el || el.hidden || !anchor) return;
    if (!anchor.isConnected) return hide();
    const r = anchor.getBoundingClientRect(), vw = window.innerWidth, vh = window.innerHeight, gap = 4, m = 8;
    if (r.bottom < 0 || r.top > vh) return hide();           // input scrolled out of view
    const width = Math.min(Math.max(r.width, 300), vw - 2 * m);
    el.style.width = width + 'px'; el.style.left = Math.max(m, Math.min(r.left, vw - width - m)) + 'px';
    const below = vh - r.bottom - gap - m, above = r.top - gap - m, want = Math.min(el.scrollHeight, 320);
    if (below >= want || below >= above) { el.style.top = (r.bottom + gap) + 'px'; el.style.bottom = 'auto'; el.style.maxHeight = Math.max(100, Math.min(320, below)) + 'px'; }
    else { el.style.bottom = (vh - r.top + gap) + 'px'; el.style.top = 'auto'; el.style.maxHeight = Math.max(100, Math.min(320, above)) + 'px'; }   // not enough room below: open upward
  }
  function show(a, html, cb) {
    anchor = a; onPick = cb || null; active = -1;
    ensure(a.closest('dialog') || document.body);
    el.innerHTML = html; el.hidden = false; el.scrollTop = 0; place();
  }
  function hide() { if (el) el.hidden = true; anchor = null; onPick = null; active = -1; }
  // keyboard support for the input that owns the list: ↑ ↓ move, Enter picks (first item if none highlighted), Esc closes. Returns true if handled.
  function key(e) {
    if (!el || el.hidden) return false;
    const items = [...el.querySelectorAll('[data-i]')];
    if (e.key === 'ArrowDown' || e.key === 'ArrowUp') {
      e.preventDefault(); if (!items.length) return true;
      active = (active + (e.key === 'ArrowDown' ? 1 : -1) + items.length) % items.length;
      items.forEach((b, i) => b.classList.toggle('act', i === active)); items[active].scrollIntoView({ block: 'nearest' }); return true;
    }
    if (e.key === 'Enter') { e.preventDefault(); const b = items[active >= 0 ? active : 0]; if (b && onPick) { const cb = onPick, i = +b.dataset.i; hide(); cb(i); } return true; }
    if (e.key === 'Escape') { hide(); return true; }
    return false;
  }
  return { show, hide, key, place };
})();
