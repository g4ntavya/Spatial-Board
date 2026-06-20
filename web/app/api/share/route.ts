import { query, str } from '@/lib/db';
import { auth } from '@/lib/auth';
import { userIdFromEmail } from '@/lib/identity';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// POST /api/share { noteId, email, mode } — share a note with another user by
// email. mode: 'strokes' | 'text' | 'both'. The recipient is keyed by email, so
// it works even before they've created an account (deterministic user id).
export async function POST(req: Request) {
  const session = await auth();
  if (!session?.user?.email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const ownerId = userIdFromEmail(session.user.email);

  let body: { noteId?: string; email?: string; mode?: string } = {};
  try { body = await req.json(); } catch { /* ignore */ }
  const noteId = body.noteId;
  const email = String(body.email ?? '').trim().toLowerCase();
  const mode = ['strokes', 'text', 'both'].includes(body.mode ?? '') ? body.mode! : 'both';
  if (!noteId) return Response.json({ error: 'noteId required' }, { status: 400 });
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return Response.json({ error: 'valid email required' }, { status: 400 });
  if (email === session.user.email.toLowerCase()) return Response.json({ error: "you can't share with yourself" }, { status: 400 });

  try {
    // Must own the note.
    const owns = await query(
      `SELECT 1 FROM notes WHERE id = :id::uuid AND space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid)`,
      [str('id', noteId), str('uid', ownerId)],
    );
    if (!owns.length) return Response.json({ error: 'not found' }, { status: 404 });

    const recipientId = userIdFromEmail(email);
    // Ensure the recipient exists as a user (they may not have signed up yet).
    await query(
      `INSERT INTO users (id, email) VALUES (:rid::uuid, :email) ON CONFLICT (id) DO NOTHING`,
      [str('rid', recipientId), str('email', email)],
    );
    await query(
      `INSERT INTO note_shares (note_id, owner_id, recipient_id, mode)
       VALUES (:nid::uuid, :oid::uuid, :rid::uuid, :mode)
       ON CONFLICT (note_id, recipient_id) DO UPDATE SET mode = EXCLUDED.mode`,
      [str('nid', noteId), str('oid', ownerId), str('rid', recipientId), str('mode', mode)],
    );
    return Response.json({ ok: true });
  } catch (err) {
    console.error('share failed', err);
    return Response.json({ error: 'share failed' }, { status: 500 });
  }
}
