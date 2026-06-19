import { query, str } from '@/lib/db';
import { embedQuery } from '@/lib/bedrock';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// GET /api/notes?space=<uuid>&q=<query>&mode=keyword|semantic
export async function GET(req: Request) {
  const { searchParams } = new URL(req.url);
  const space = searchParams.get('space');
  const q = searchParams.get('q')?.trim();
  const mode = searchParams.get('mode') ?? 'keyword';
  if (!space) return Response.json([], { status: 200 });

  const cols = `id::text AS id, title, category, ocr_text, status, updated_at::text AS updated_at`;

  try {
    if (q && mode === 'semantic') {
      const vec = await embedQuery(q);
      const rows = await query(
        `SELECT ${cols}, (embedding <=> :v::vector) AS distance
           FROM notes
          WHERE space_id = :s::uuid AND embedding IS NOT NULL
          ORDER BY distance ASC LIMIT 30`,
        [str('v', `[${vec.join(',')}]`), str('s', space)],
      );
      return Response.json(rows);
    }

    if (q) {
      const rows = await query(
        `SELECT ${cols}
           FROM notes
          WHERE space_id = :s::uuid AND search_vector @@ plainto_tsquery('english', :q)
          ORDER BY updated_at DESC LIMIT 50`,
        [str('s', space), str('q', q)],
      );
      return Response.json(rows);
    }

    const rows = await query(
      `SELECT ${cols} FROM notes WHERE space_id = :s::uuid ORDER BY updated_at DESC LIMIT 100`,
      [str('s', space)],
    );
    return Response.json(rows);
  } catch (err) {
    console.error('notes query failed', err);
    return Response.json({ error: 'query failed' }, { status: 500 });
  }
}
