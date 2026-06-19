import { query, str } from '@/lib/db';
import { embedQuery } from '@/lib/bedrock';
import { auth } from '@/lib/auth';
import { userIdFromEmail } from '@/lib/identity';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// GET /api/notes?space=<uuid>&q=<query>&mode=keyword|semantic
export async function GET(req: Request) {
  const session = await auth();
  if (!session?.user?.email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const uid = userIdFromEmail(session.user.email);

  const { searchParams } = new URL(req.url);
  const space = searchParams.get('space');
  const q = searchParams.get('q')?.trim();
  const mode = searchParams.get('mode') ?? 'keyword';
  if (!space) return Response.json([], { status: 200 });

  const cols = `id::text AS id, title, category, ocr_text, status, updated_at::text AS updated_at`;
  // Only notes in a space owned by the signed-in user.
  const owned = `space_id = :s::uuid AND space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid)`;

  try {
    if (q && mode === 'semantic') {
      const vec = await embedQuery(q);
      // Only return notes that are actually related — cosine distance below a
      // cutoff — otherwise pgvector ranks (and returns) the entire library.
      // Titan v2: relevant matches sit well under ~0.85; unrelated cluster above.
      const rows = await query(
        `SELECT ${cols}, (embedding <=> :v::vector) AS distance
           FROM notes WHERE ${owned} AND embedding IS NOT NULL
             AND (embedding <=> :v::vector) < 0.85
           ORDER BY distance ASC LIMIT 30`,
        [str('v', `[${vec.join(',')}]`), str('s', space), str('uid', uid)],
      );
      return Response.json(rows);
    }

    if (q) {
      const rows = await query(
        `SELECT ${cols} FROM notes
          WHERE ${owned} AND search_vector @@ plainto_tsquery('english', :q)
          ORDER BY updated_at DESC LIMIT 50`,
        [str('s', space), str('uid', uid), str('q', q)],
      );
      return Response.json(rows);
    }

    const rows = await query(
      `SELECT ${cols} FROM notes WHERE ${owned} ORDER BY updated_at DESC LIMIT 100`,
      [str('s', space), str('uid', uid)],
    );
    return Response.json(rows);
  } catch (err) {
    console.error('notes query failed', err);
    return Response.json({ error: 'query failed' }, { status: 500 });
  }
}
