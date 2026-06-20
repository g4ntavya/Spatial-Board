import { query, str } from '@/lib/db';
import { embedQuery } from '@/lib/bedrock';
import { auth } from '@/lib/auth';
import { userIdFromEmail } from '@/lib/identity';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// Build the keyword matchers from a raw query. Full-text alone only matches whole
// lexemes (so "ganta" misses "gantavya"); we add:
//  - tsq: a *prefix* tsquery ("ganta:*") so a term matches the start of a word, and
//  - like: an ILIKE '%…%' pattern so a term found anywhere inside a word still matches.
function buildKeyword(q: string) {
  const like = `%${q.replace(/[%_\\]/g, '\\$&')}%`; // escape LIKE wildcards
  const tokens = q.split(/\s+/).map((t) => t.replace(/[^\p{L}\p{N}]+/gu, '')).filter(Boolean);
  const tsq = tokens.length ? tokens.map((t) => `${t}:*`).join(' & ') : 'zzzznomatchzzzz';
  return { like, tsq };
}

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

  const cols = `id::text AS id, title, category, ocr_text, status, updated_at::text AS updated_at, pinned`;
  // Only notes in a space owned by the signed-in user.
  const owned = `space_id = :s::uuid AND space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid)`;

  try {
    // Hybrid: fuse keyword (tsvector) and semantic (pgvector) rankings with
    // Reciprocal Rank Fusion (RRF, k=60) in a single Aurora query. Each ranker
    // contributes 1/(k+rank); a note strong in either — or both — rises to the top.
    if (q && mode === 'hybrid') {
      const vec = await embedQuery(q);
      const { like, tsq } = buildKeyword(q);
      const rows = await query(
        `WITH sem AS (
           SELECT id, ROW_NUMBER() OVER (ORDER BY (embedding <=> :v::vector) ASC) AS rnk
             FROM notes
            WHERE ${owned} AND embedding IS NOT NULL AND (embedding <=> :v::vector) < 0.9
            ORDER BY (embedding <=> :v::vector) ASC LIMIT 40
         ),
         kw AS (
           SELECT id, ROW_NUMBER() OVER (
                    ORDER BY ts_rank_cd(search_vector, to_tsquery('english', :tsq)) DESC) AS rnk
             FROM notes
            WHERE ${owned} AND (search_vector @@ to_tsquery('english', :tsq)
                                OR title ILIKE :like OR ocr_text ILIKE :like)
            LIMIT 40
         ),
         fused AS (
           SELECT COALESCE(sem.id, kw.id) AS id,
                  COALESCE(1.0 / (60 + sem.rnk), 0) + COALESCE(1.0 / (60 + kw.rnk), 0) AS score
             FROM sem FULL OUTER JOIN kw ON sem.id = kw.id
         )
         SELECT n.id::text AS id, n.title, n.category, n.ocr_text, n.status,
                n.updated_at::text AS updated_at, n.pinned, f.score
           FROM fused f JOIN notes n ON n.id = f.id
          ORDER BY f.score DESC LIMIT 30`,
        [str('v', `[${vec.join(',')}]`), str('s', space), str('uid', uid), str('tsq', tsq), str('like', like)],
      );
      return Response.json(rows);
    }

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
      const { like, tsq } = buildKeyword(q);
      const rows = await query(
        `SELECT ${cols} FROM notes
          WHERE ${owned} AND (search_vector @@ to_tsquery('english', :tsq)
                              OR title ILIKE :like OR ocr_text ILIKE :like)
          ORDER BY ts_rank_cd(search_vector, to_tsquery('english', :tsq)) DESC, updated_at DESC LIMIT 50`,
        [str('s', space), str('uid', uid), str('tsq', tsq), str('like', like)],
      );
      return Response.json(rows);
    }

    const rows = await query(
      `SELECT ${cols} FROM notes WHERE ${owned} ORDER BY pinned DESC, updated_at DESC LIMIT 100`,
      [str('s', space), str('uid', uid)],
    );
    return Response.json(rows);
  } catch (err) {
    console.error('notes query failed', err);
    return Response.json({ error: 'query failed' }, { status: 500 });
  }
}
