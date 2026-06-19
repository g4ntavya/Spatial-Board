import { query, str } from '@/lib/db';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// GET /api/note?id=<uuid> — full note incl. the projected SVG.
export async function GET(req: Request) {
  const id = new URL(req.url).searchParams.get('id');
  if (!id) return Response.json({ error: 'id required' }, { status: 400 });

  try {
    const rows = await query(
      `SELECT id::text AS id, title, category, ocr_text, svg, status, updated_at::text AS updated_at
         FROM notes WHERE id = :id::uuid LIMIT 1`,
      [str('id', id)],
    );
    return Response.json(rows[0] ?? null);
  } catch (err) {
    console.error('note query failed', err);
    return Response.json({ error: 'query failed' }, { status: 500 });
  }
}
