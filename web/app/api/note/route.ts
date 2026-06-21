import { query, str } from '@/lib/db';
import { auth } from '@/lib/auth';
import { userIdFromEmail } from '@/lib/identity';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// GET /api/note?id=<uuid> — full note incl. the projected SVG (owner only).
export async function GET(req: Request) {
  const session = await auth();
  if (!session?.user?.email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const uid = userIdFromEmail(session.user.email);

  const id = new URL(req.url).searchParams.get('id');
  if (!id) return Response.json({ error: 'id required' }, { status: 400 });

  try {
    const rows = await query(
      `SELECT n.id::text AS id, n.title, n.category, n.note_type, n.ocr_text, n.svg, n.status, n.updated_at::text AS updated_at,
              (n.space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid)) AS owned,
              sh.mode AS share_mode
         FROM notes n
         LEFT JOIN note_shares sh ON sh.note_id = n.id AND sh.recipient_id = :uid::uuid
        WHERE n.id = :id::uuid
          AND (n.space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid) OR sh.recipient_id = :uid::uuid)
        LIMIT 1`,
      [str('id', id), str('uid', uid)],
    );
    const n = rows[0];
    if (!n) return Response.json(null);
    // Shared (not owned): only expose what the share mode permits.
    if (!n.owned) {
      const mode = (n.share_mode as string) || 'both';
      if (mode === 'text') n.svg = null;
      if (mode === 'strokes') n.ocr_text = null;
    }
    return Response.json(n);
  } catch (err) {
    console.error('note query failed', err);
    return Response.json({ error: 'query failed' }, { status: 500 });
  }
}

// PATCH /api/note  { id, category?, title?, pinned?, ocr_text? } — move/rename/pin/edit.
export async function PATCH(req: Request) {
  const session = await auth();
  if (!session?.user?.email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const uid = userIdFromEmail(session.user.email);

  let body: { id?: string; category?: string; title?: string; pinned?: boolean; ocr_text?: string } = {};
  try { body = await req.json(); } catch { /* ignore */ }
  if (!body.id) return Response.json({ error: 'id required' }, { status: 400 });

  const sets: string[] = [];
  const params = [str('id', body.id), str('uid', uid)];
  if (typeof body.category === 'string') { sets.push('category = :category'); params.push(str('category', body.category)); }
  if (typeof body.title === 'string') { sets.push('title = :title'); params.push(str('title', body.title)); }
  if (typeof body.pinned === 'boolean') { sets.push('pinned = :pinned'); params.push({ name: 'pinned', value: { booleanValue: body.pinned } }); }
  // Checkbox toggles persist by rewriting the markdown checklist in ocr_text.
  if (typeof body.ocr_text === 'string') { sets.push('ocr_text = :ocr_text'); params.push(str('ocr_text', body.ocr_text)); }
  if (!sets.length) return Response.json({ error: 'nothing to update' }, { status: 400 });

  try {
    await query(
      `UPDATE notes SET ${sets.join(', ')}, updated_at = now()
        WHERE id = :id::uuid AND space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid)`,
      params,
    );
    return Response.json({ ok: true });
  } catch (err) {
    console.error('note patch failed', err);
    return Response.json({ error: 'update failed' }, { status: 500 });
  }
}

// DELETE /api/note?id=<uuid> — owner only. Strokes cascade via the FK.
export async function DELETE(req: Request) {
  const session = await auth();
  if (!session?.user?.email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const uid = userIdFromEmail(session.user.email);

  const id = new URL(req.url).searchParams.get('id');
  if (!id) return Response.json({ error: 'id required' }, { status: 400 });

  try {
    await query(
      `DELETE FROM notes WHERE id = :id::uuid AND space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid)`,
      [str('id', id), str('uid', uid)],
    );
    return Response.json({ ok: true });
  } catch (err) {
    console.error('note delete failed', err);
    return Response.json({ error: 'delete failed' }, { status: 500 });
  }
}
