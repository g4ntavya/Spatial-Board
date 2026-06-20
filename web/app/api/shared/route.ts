import { query, str } from '@/lib/db';
import { auth } from '@/lib/auth';
import { userIdFromEmail } from '@/lib/identity';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// GET /api/shared — notes other users have shared with me (detail via /api/note).
export async function GET() {
  const session = await auth();
  if (!session?.user?.email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const uid = userIdFromEmail(session.user.email);

  try {
    const rows = await query(
      `SELECT n.id::text AS id, n.title, n.category, n.status, n.updated_at::text AS updated_at,
              sh.mode, u.email AS owner,
              CASE WHEN sh.mode = 'strokes' THEN NULL ELSE n.ocr_text END AS ocr_text
         FROM note_shares sh
         JOIN notes n ON n.id = sh.note_id
         JOIN users u ON u.id = sh.owner_id
        WHERE sh.recipient_id = :uid::uuid
        ORDER BY sh.created_at DESC`,
      [str('uid', uid)],
    );
    return Response.json(rows);
  } catch (err) {
    console.error('shared query failed', err);
    return Response.json([], { status: 200 });
  }
}
