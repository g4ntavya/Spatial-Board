import { query, str } from '@/lib/db';
import { hashPassword } from '@/lib/password';
import { userIdFromEmail } from '@/lib/identity';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// POST /api/signup { email, password } — create an email/password account.
// Identity is the deterministic sha1 user id shared with the auth Lambda + iOS,
// so this account works everywhere. After this, the client signs in normally.
export async function POST(req: Request) {
  let body: { email?: string; password?: string } = {};
  try { body = await req.json(); } catch { /* ignore */ }

  const email = String(body.email ?? '').trim().toLowerCase();
  const password = String(body.password ?? '');
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return Response.json({ error: 'Enter a valid email.' }, { status: 400 });
  if (password.length < 8) return Response.json({ error: 'Password must be at least 8 characters.' }, { status: 400 });

  const uid = userIdFromEmail(email);
  try {
    const rows = await query(`SELECT password_hash FROM users WHERE id = :id::uuid`, [str('id', uid)]);
    if (rows[0]?.password_hash) return Response.json({ error: 'An account with this email already exists.' }, { status: 409 });

    await query(
      `INSERT INTO users (id, email, password_hash) VALUES (:id::uuid, :email, :ph)
       ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email, password_hash = EXCLUDED.password_hash`,
      [str('id', uid), str('email', email), str('ph', hashPassword(password))],
    );
    return Response.json({ ok: true });
  } catch (err) {
    console.error('signup failed', err);
    return Response.json({ error: 'Could not create the account. Try again.' }, { status: 500 });
  }
}
