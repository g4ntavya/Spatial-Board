import { query, str } from '@/lib/db';
import { auth } from '@/lib/auth';
import { userIdFromEmail } from '@/lib/identity';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// GET /api/positions?space=<uuid> — the (x, y) the notes were written at, from
// each note's world_origin centroid. Used to draw the "where you wrote it" map:
// coordinates are meaningless on their own, so the UI plots them *relative to
// each other* within the space.
export async function GET(req: Request) {
  const session = await auth();
  if (!session?.user?.email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const uid = userIdFromEmail(session.user.email);
  const space = new URL(req.url).searchParams.get('space');
  if (!space) return Response.json([]);

  try {
    const rows = await query(
      `SELECT id::text AS id,
              (world_origin->'centroid'->>0)::float8 AS x,
              (world_origin->'centroid'->>1)::float8 AS y
         FROM notes
        WHERE space_id = :s::uuid
          AND space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid)
          AND world_origin ? 'centroid'`,
      [str('s', space), str('uid', uid)],
    );
    return Response.json(rows);
  } catch (err) {
    console.error('positions query failed', err);
    return Response.json([], { status: 200 });
  }
}
