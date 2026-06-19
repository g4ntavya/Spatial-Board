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
      `SELECT id::text AS id, title, category, ocr_text, svg, status, updated_at::text AS updated_at
         FROM notes
        WHERE id = :id::uuid AND space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid)
        LIMIT 1`,
      [str('id', id), str('uid', uid)],
    );
    return Response.json(rows[0] ?? null);
  } catch (err) {
    console.error('note query failed', err);
    return Response.json({ error: 'query failed' }, { status: 500 });
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
