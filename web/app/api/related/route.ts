import { query, str } from '@/lib/db';
import { auth } from '@/lib/auth';
import { userIdFromEmail } from '@/lib/identity';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// GET /api/related?id=<uuid> — nearest notes by meaning, via pgvector cosine
// distance against the note's own embedding. Showcases Aurora + pgvector.
export async function GET(req: Request) {
  const session = await auth();
  if (!session?.user?.email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const uid = userIdFromEmail(session.user.email);
  const id = new URL(req.url).searchParams.get('id');
  if (!id) return Response.json([], { status: 200 });

  try {
    const rows = await query(
      `SELECT n.id::text AS id, n.title, n.category
         FROM notes n,
              (SELECT embedding FROM notes WHERE id = :id::uuid) src
        WHERE n.id <> :id::uuid
          AND n.embedding IS NOT NULL AND src.embedding IS NOT NULL
          AND n.space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid)
          AND (n.embedding <=> src.embedding) < 0.8   -- only meaningfully related
        ORDER BY n.embedding <=> src.embedding
        LIMIT 4`,
      [str('id', id), str('uid', uid)],
    );
    return Response.json(rows);
  } catch (err) {
    console.error('related query failed', err);
    return Response.json([], { status: 200 });
  }
}
