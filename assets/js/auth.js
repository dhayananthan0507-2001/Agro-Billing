// Single auth module for login.html and register.html.
const SUPABASE_URL = 'https://mavbmnkyiyjbacftbkvj.supabase.co';        // Project Settings → API
const SUPABASE_ANON_KEY = 'sb_publishable_NfCdSavarg5HYEotRuYriA_rf3YGVl3'; // anon/publishable key only — never the service-role key
const DASHBOARD_URL = 'dashboard.html';
const $ = id => document.getElementById(id);

function makeClient() {
  // "Remember me" decides whether the session survives closing the browser.
  const store = localStorage.getItem('agro_remember') === '0' ? sessionStorage : localStorage;
  return supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, { auth: { persistSession: true, autoRefreshToken: true, storage: store } });
}
let sb = null; // created once, on first use, so only one Supabase client ever exists on the page
const client = () => sb || (sb = makeClient());
const msg = (t, type) => { const m = $('msg'); m.textContent = t; m.className = type; };
const busy = (b, on, label) => { b.disabled = on; b.textContent = on ? label : b.dataset.label; };
const validEmail = e => /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(e);
const friendly = m => { m = (m || '').toLowerCase();
  if (m.includes('invalid login')) return 'Email or password is incorrect.';
  if (m.includes('not confirmed')) return 'Please verify your email, then sign in.';
  if (m.includes('already registered')) return 'An account with this email already exists. Try signing in.';
  if (m.includes('rate limit')) return 'Too many attempts. Please wait a few minutes and try again.';
  return 'Something went wrong. Please try again.'; };

// Creates company + owner membership from signup metadata. Safe to call repeatedly.
async function ensureWorkspace(user) {
  const { data: mem, error } = await client().from('company_members').select('company_id').eq('user_id', user.id).limit(1);
  if (error) throw error;
  if (mem.length) return true;
  const m = user.user_metadata || {};
  if (!m.company_name) return false;
  const { error: e2 } = await client().rpc('create_company_and_owner', { p_company_name: m.company_name, p_owner_name: m.owner_name || '', p_mobile: m.mobile || '' });
  if (e2) throw e2;
  return true;
}

$('loginForm')?.addEventListener('submit', async e => {
  e.preventDefault(); const btn = $('btn'); msg('', '');
  const email = $('email').value.trim().toLowerCase(), password = $('password').value;
  if (!validEmail(email)) return msg('Enter a valid email address.', 'error');
  if (!password) return msg('Enter your password.', 'error');
  localStorage.setItem('agro_remember', $('remember').checked ? '1' : '0');
  busy(btn, true, 'Signing in…');
  try {
    const { data, error } = await client().auth.signInWithPassword({ email, password }); if (error) throw error;
    if (!(await ensureWorkspace(data.user))) throw new Error('Your account is not linked to a shop. Ask the owner to add you.');
    location.replace(DASHBOARD_URL);
  } catch (err) { console.error('Login failed:', err); msg(err.message.startsWith('Your account') ? err.message : friendly(err.message), 'error'); busy(btn, false); }
});

$('registerForm')?.addEventListener('submit', async e => {
  e.preventDefault(); const btn = $('btn'); msg('', '');
  const v = id => $(id).value.trim(), email = v('email').toLowerCase(), password = $('password').value;
  if (!v('company')) return msg('Enter your shop name.', 'error');
  if (!v('owner')) return msg('Enter the owner name.', 'error');
  if (!validEmail(email)) return msg('Enter a valid email address.', 'error');
  if (!/^[0-9+\s-]{10,15}$/.test(v('mobile'))) return msg('Enter a valid mobile number.', 'error');
  if (password.length < 8) return msg('Password must be at least 8 characters.', 'error');
  if (password !== $('confirm').value) return msg('Passwords do not match.', 'error');
  busy(btn, true, 'Creating account…');
  try {
    const { data, error } = await client().auth.signUp({ email, password, options: { data: { company_name: v('company'), owner_name: v('owner'), mobile: v('mobile') } } });
    if (error) throw error;
    if (data.session) { await ensureWorkspace(data.user); location.replace(DASHBOARD_URL); return; }
    // Email confirmation is on: the shop is created automatically at first sign-in after verifying.
    msg('Account created. Check your email to verify it, then sign in.', 'ok'); busy(btn, false);
  } catch (err) { console.error('Registration failed:', err); msg(friendly(err.message), 'error'); busy(btn, false); }
});

$('forgot')?.addEventListener('click', async ev => {
  ev.preventDefault(); const email = $('email').value.trim().toLowerCase();
  if (!validEmail(email)) return msg('Enter your email above first.', 'error');
  const { error } = await client().auth.resetPasswordForEmail(email, { redirectTo: location.origin + location.pathname });
  if (error) console.error(error);
  msg('If an account exists for this email, a reset link has been sent.', 'ok');
});
