import { query, str } from '@/lib/db';
import { embedQuery, answer } from '@/lib/bedrock';
import { auth } from '@/lib/auth';
import { userIdFromEmail } from '@/lib/identity';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// POST /api/ask { question } — RAG over the user's notes:
// Titan embeds the question → pgvector retrieves the closest notes (Aurora) →
// Nova answers using only those notes, with citations.
export async function POST(req: Request) {
  const session = await auth();
  if (!session?.user?.email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const uid = userIdFromEmail(session.user.email);

  let question = '';
  try { ({ question } = await req.json()); } catch { /* ignore */ }
  question = String(question ?? '').trim();
  if (!question) return Response.json({ error: 'question required' }, { status: 400 });

  try {
    const vec = await embedQuery(question);
    const hits = await query(
      `SELECT id::text AS id, title, ocr_text, (embedding <=> :v::vector) AS distance
         FROM notes
        WHERE space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid)
          AND embedding IS NOT NULL AND COALESCE(ocr_text, '') <> ''
          AND (embedding <=> :v::vector) < 1.0
        ORDER BY distance ASC LIMIT 6`,
      [str('v', `[${vec.join(',')}]`), str('uid', uid)],
    );

    if (!hits.length) {
      return Response.json({ answer: "I couldn't find anything in your notes about that.", sources: [] });
    }

    const context = hits
      .map((h, i) => `[${i + 1}] ${h.title || 'Untitled'}: ${h.ocr_text}`)
      .join('\n');
    const system =
      'You answer questions using ONLY the user\'s handwritten notes provided. ' +
      'Be concise (1–3 sentences). Cite the notes you used like [1], [2]. ' +
      "If the notes don't contain the answer, say so plainly.";
    const reply = await answer(system, `Notes:\n${context}\n\nQuestion: ${question}`);

    return Response.json({
      answer: reply,
      sources: hits.map((h) => ({ id: h.id, title: h.title })),
    });
  } catch (err) {
    console.error('ask failed', err);
    return Response.json({ error: 'ask failed' }, { status: 500 });
  }
}
