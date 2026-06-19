import { query, str } from '@/lib/db';
import { auth } from '@/lib/auth';
import { userIdFromEmail } from '@/lib/identity';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// GET /api/categories?space=<uuid> — auto-derived "folders" with counts (Aurora GROUP BY).
export async function GET(req: Request) {
  const session = await auth();
  if (!session?.user?.email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const uid = userIdFromEmail(session.user.email);
  const space = new URL(req.url).searchParams.get('space');
  if (!space) return Response.json([], { status: 200 });

  try {
    const rows = await query(
      `SELECT COALESCE(NULLIF(category, ''), 'Uncategorized') AS category, count(*)::int AS n
         FROM notes
        WHERE space_id = :s::uuid AND space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid)
        GROUP BY 1 ORDER BY n DESC, category ASC`,
      [str('s', space), str('uid', uid)],
    );
    return Response.json(rows);
  } catch (err) {
    console.error('categories query failed', err);
    return Response.json({ error: 'query failed' }, { status: 500 });
  }
}
