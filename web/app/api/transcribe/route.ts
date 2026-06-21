import { query, str } from '@/lib/db';
import { auth } from '@/lib/auth';
import { userIdFromEmail } from '@/lib/identity';
import { SQSClient, SendMessageCommand } from '@aws-sdk/client-sqs';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const sqs = new SQSClient({ region: process.env.AWS_REGION ?? 'us-east-1' });

// POST /api/transcribe { id } — re-runs the intelligent pipeline (rasterize →
// Bedrock Claude OCR + title + category → Titan embed) on a note. Returns 202;
// the client polls /api/note until status becomes 'processed'.
export async function POST(req: Request) {
  const session = await auth();
  if (!session?.user?.email) return Response.json({ error: 'unauthorized' }, { status: 401 });
  const uid = userIdFromEmail(session.user.email);

  let id: string | undefined;
  try {
    ({ id } = await req.json());
  } catch {
    /* ignore */
  }
  if (!id) return Response.json({ error: 'id required' }, { status: 400 });
  if (!process.env.NOTES_QUEUE_URL) return Response.json({ error: 'queue not configured' }, { status: 500 });

  // Ownership check.
  const owned = await query(
    `SELECT 1 FROM notes WHERE id = :id::uuid AND space_id IN (SELECT id FROM spaces WHERE user_id = :uid::uuid)`,
    [str('id', id), str('uid', uid)],
  );
  if (!owned.length) return Response.json({ error: 'not found' }, { status: 404 });

  await query(`UPDATE notes SET status = 'pending' WHERE id = :id::uuid`, [str('id', id)]);
  // manual: re-OCR/split this note in place, but don't auto-merge it into others.
  await sqs.send(new SendMessageCommand({ QueueUrl: process.env.NOTES_QUEUE_URL, MessageBody: JSON.stringify({ noteId: id, manual: true }) }));

  return Response.json({ status: 'queued' }, { status: 202 });
}
