import { query, str } from '@/lib/db';
import { embedQuery, answerStream } from '@/lib/bedrock';
import { auth } from '@/lib/auth';
import { userIdFromEmail } from '@/lib/identity';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

// POST /api/ask { question } — RAG over the user's notes, STREAMED:
// Titan embeds the question → pgvector retrieves the closest notes (Aurora) →
// Nova streams the answer token-by-token. Citations come back in the `x-sources`
// header (base64 JSON) so the client has them before the body finishes.
export async function POST(req: Request) {
  const session = await auth();
  if (!session?.user?.email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const uid = userIdFromEmail(session.user.email);

  let question = '';
  try { ({ question } = await req.json()); } catch { /* ignore */ }
  question = String(question ?? '').trim();
  if (!question) return Response.json({ error: 'question required' }, { status: 400 });

  const enc = new TextEncoder();
  const streamText = (text: string, sources: { id: string; title: string | null }[]) =>
    new Response(
      new ReadableStream({ start(c) { c.enqueue(enc.encode(text)); c.close(); } }),
      { headers: hdrs(sources) },
    );
  const hdrs = (sources: { id: string; title: string | null }[]) => ({
    'content-type': 'text/plain; charset=utf-8',
    'cache-control': 'no-store',
    'x-sources': Buffer.from(JSON.stringify(sources)).toString('base64'),
  });

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
      return streamText("I couldn't find anything in your notes about that.", []);
    }

    const sources = hits.map((h) => ({ id: h.id as string, title: (h.title ?? null) as string | null }));
    const context = hits.map((h, i) => `[${i + 1}] ${h.title || 'Untitled'}: ${h.ocr_text}`).join('\n');
    const system =
      'You answer questions using ONLY the user\'s handwritten notes provided. ' +
      'Be concise (1–3 sentences). Cite the notes you used like [1], [2]. ' +
      "If the notes don't contain the answer, say so plainly.";

    const stream = new ReadableStream({
      async start(controller) {
        try {
          for await (const chunk of answerStream(system, `Notes:\n${context}\n\nQuestion: ${question}`)) {
            controller.enqueue(enc.encode(chunk));
          }
        } catch (err) {
          console.error('ask stream failed', err);
          controller.enqueue(enc.encode('\n(Answer interrupted.)'));
        }
        controller.close();
      },
    });
    return new Response(stream, { headers: hdrs(sources) });
  } catch (err) {
    console.error('ask failed', err);
    return Response.json({ error: 'ask failed' }, { status: 500 });
  }
}
