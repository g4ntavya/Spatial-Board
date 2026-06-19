// Ingest Lambda — receives a stroke batch from the iOS app, clusters strokes
// into notes, upserts everything to Aurora over the RDS Data API, and enqueues
// changed note IDs for the Process worker. Idempotent: everything is UUID-keyed.
//
// Uses only @aws-sdk/* packages that ship with the Node 20 Lambda runtime, so
// there is nothing to bundle or npm-install.

import {
  RDSDataClient,
  ExecuteStatementCommand,
  BatchExecuteStatementCommand,
} from '@aws-sdk/client-rds-data';
import { SQSClient, SendMessageBatchCommand } from '@aws-sdk/client-sqs';
import { createHash, createHmac, timingSafeEqual } from 'crypto';

const rds = new RDSDataClient({});
const sqs = new SQSClient({});
const { CLUSTER_ARN, SECRET_ARN, DB_NAME, QUEUE_URL, SYNC_TOKEN } = process.env;

const CLUSTER_RADIUS = 0.35; // metres — free strokes within this join one note

// ── Data API helpers ────────────────────────────────────────────────────────
const uuid = (name, v) => ({ name, value: { stringValue: v }, typeHint: 'UUID' });
const json = (name, v) => ({ name, value: { stringValue: JSON.stringify(v) }, typeHint: 'JSON' });
const str = (name, v) =>
  v == null ? { name, value: { isNull: true } } : { name, value: { stringValue: String(v) } };
const num = (name, v) =>
  v == null ? { name, value: { isNull: true } } : { name, value: { doubleValue: Number(v) } };

const exec = (sql, parameters = []) =>
  rds.send(new ExecuteStatementCommand({ resourceArn: CLUSTER_ARN, secretArn: SECRET_ARN, database: DB_NAME, sql, parameters }));

async function batch(sql, parameterSets) {
  for (let i = 0; i < parameterSets.length; i += 100) {
    await rds.send(
      new BatchExecuteStatementCommand({
        resourceArn: CLUSTER_ARN,
        secretArn: SECRET_ARN,
        database: DB_NAME,
        sql,
        parameterSets: parameterSets.slice(i, i + 100),
      }),
    );
  }
}

// Deterministic UUID (v5-style) from arbitrary string parts.
function uuidFrom(...parts) {
  const h = createHash('sha1').update(parts.join('|')).digest('hex');
  const y = ((parseInt(h[16], 16) & 0x3) | 0x8).toString(16);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-${y}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

const dist = (a, b) => Math.hypot(a[0] - b[0], a[1] - b[1], a[2] - b[2]);

// Verify one of our own HS256 JWTs (issued by the auth Lambda) and return its
// claims ({ email, ... }) or null.
function verifyJwt(token) {
  try {
    const [h, p, sig] = token.split('.');
    if (!h || !p || !sig) return null;
    const expected = createHmac('sha256', process.env.AUTH_JWT_SECRET).update(`${h}.${p}`).digest('base64url');
    const a = Buffer.from(sig);
    const b = Buffer.from(expected);
    if (a.length !== b.length || !timingSafeEqual(a, b)) return null;
    const claims = JSON.parse(Buffer.from(p, 'base64url').toString('utf8'));
    if (claims.exp && claims.exp < Math.floor(Date.now() / 1000)) return null;
    return claims;
  } catch {
    return null;
  }
}

function centroidOf(geometry) {
  if (Array.isArray(geometry?.centroid) && geometry.centroid.length === 3) return geometry.centroid;
  const pts = geometry?.points ?? [];
  if (!pts.length) return [0, 0, 0];
  const s = pts.reduce((acc, p) => [acc[0] + p[0], acc[1] + p[1], acc[2] + p[2]], [0, 0, 0]);
  return [s[0] / pts.length, s[1] / pts.length, s[2] / pts.length];
}

const reply = (statusCode, body) => ({
  statusCode,
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(body),
});

export const handler = async (event) => {
  // ── Auth ──
  const headers = event.headers ?? {};
  const key = headers['x-api-key'] ?? headers['X-Api-Key'];
  if (!SYNC_TOKEN || key !== SYNC_TOKEN) return reply(401, { error: 'unauthorized' });

  // ── Parse ──
  let payload;
  try {
    const raw = event.isBase64Encoded ? Buffer.from(event.body, 'base64').toString('utf8') : event.body;
    payload = JSON.parse(raw ?? '{}');
  } catch {
    return reply(400, { error: 'invalid json' });
  }

  const { deviceId, spaces = [], folders = [], strokes = [] } = payload;
  if (!deviceId) return reply(400, { error: 'deviceId required' });

  // Identity: a verified Google account (keyed by email) ties this device's data
  // to the same user the web app logs in as. Falls back to the device id when the
  // app isn't signed in yet.
  let identityKey = deviceId;
  let email = `${deviceId}@device.local`;
  const authz = headers['authorization'] ?? headers['Authorization'];
  if (authz?.startsWith('Bearer ')) {
    const claims = verifyJwt(authz.slice(7));
    if (claims?.email) {
      email = String(claims.email).toLowerCase();
      identityKey = email;
    }
  }

  const userId = uuidFrom('user', identityKey);
  const defaultSpaceId = uuidFrom('space', userId, 'Default');
  // iOS strokes carry spaceID as the Space UUID string, or the literal "Default".
  const resolveSpace = (ref) => (!ref || ref === 'Default' ? defaultSpaceId : uuidFrom('space', userId, ref));

  // ── Identity + spaces + folders ──
  await exec(`INSERT INTO users (id,email) VALUES (:id,:email) ON CONFLICT (id) DO UPDATE SET email = EXCLUDED.email`, [
    uuid('id', userId),
    str('email', email),
  ]);

  const spaceRows = spaces.map((s) => [
    uuid('id', resolveSpace(s.id)),
    uuid('uid', userId),
    str('name', s.name ?? 'Untitled'),
    str('color', s.colorHex ?? '#4A90D9'),
  ]);
  // Ensure a Default space exists if any stroke is free-floating in it.
  if (strokes.some((k) => !k.spaceId || k.spaceId === 'Default')) {
    spaceRows.push([uuid('id', defaultSpaceId), uuid('uid', userId), str('name', 'Default'), str('color', '#4A90D9')]);
  }
  if (spaceRows.length) {
    await batch(
      `INSERT INTO spaces (id,user_id,name,color_hex) VALUES (:id,:uid,:name,:color)
       ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name, color_hex=EXCLUDED.color_hex`,
      spaceRows,
    );
  }

  const folderSpace = new Map(); // folderId -> resolved spaceId
  if (folders.length) {
    await batch(
      `INSERT INTO folders (id,space_id,name) VALUES (:id,:sid,:name)
       ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name, space_id=EXCLUDED.space_id`,
      folders.map((f) => {
        const sid = resolveSpace(f.spaceId);
        folderSpace.set(f.id, sid);
        return [uuid('id', f.id), uuid('sid', sid), str('name', f.name ?? 'Folder')];
      }),
    );
  }

  // ── Cluster strokes → notes ──
  // Folder strokes: one note per folder. Free strokes: greedy spatial clustering.
  const noteOf = new Map(); // strokeId -> noteId
  const notes = new Map(); // noteId -> { spaceId, folderId, members:[], centroid }

  const folderGroups = new Map();
  const free = [];
  for (const k of strokes) {
    if (k.folderId) {
      if (!folderGroups.has(k.folderId)) folderGroups.set(k.folderId, []);
      folderGroups.get(k.folderId).push(k);
    } else {
      free.push(k);
    }
  }

  for (const [folderId, members] of folderGroups) {
    const noteId = uuidFrom('note', 'folder', folderId);
    const spaceId = folderSpace.get(folderId) ?? resolveSpace(members[0].spaceId);
    notes.set(noteId, { spaceId, folderId, members, centroid: centroidOf(members[0].geometry) });
    for (const m of members) noteOf.set(m.id, noteId);
  }

  // Greedy clustering per space for free strokes.
  const bySpace = new Map();
  for (const k of free) {
    const sid = resolveSpace(k.spaceId);
    if (!bySpace.has(sid)) bySpace.set(sid, []);
    bySpace.get(sid).push(k);
  }
  for (const [spaceId, items] of bySpace) {
    const clusters = [];
    for (const k of items) {
      const c = centroidOf(k.geometry);
      let hit = clusters.find((cl) => dist(cl.centroid, c) < CLUSTER_RADIUS);
      if (!hit) {
        hit = { members: [], centroid: c, sum: [0, 0, 0] };
        clusters.push(hit);
      }
      hit.members.push(k);
      hit.sum = [hit.sum[0] + c[0], hit.sum[1] + c[1], hit.sum[2] + c[2]];
      hit.centroid = hit.sum.map((v) => v / hit.members.length);
    }
    for (const cl of clusters) {
      const ids = cl.members.map((m) => m.id).sort();
      const noteId = uuidFrom('note', spaceId, ids.join(','));
      notes.set(noteId, { spaceId, folderId: null, members: cl.members, centroid: cl.centroid });
      for (const m of cl.members) noteOf.set(m.id, noteId);
    }
  }

  // ── Decide which notes changed (only those get reprocessed → saves Bedrock $) ──
  const noteIds = [...notes.keys()];
  const contentHash = (n) =>
    createHash('sha1').update(n.members.map((m) => m.id).sort().join(',') + JSON.stringify(n.members.map((m) => m.geometry))).digest('hex').slice(0, 16);

  const existing = new Map();
  if (noteIds.length) {
    const res = await exec(
      `SELECT id::text AS id, world_origin->>'hash' AS hash FROM notes WHERE id = ANY(:ids::uuid[])`,
      [{ name: 'ids', value: { stringValue: `{${noteIds.join(',')}}` } }],
    );
    for (const row of res.records ?? []) existing.set(row[0].stringValue, row[1]?.stringValue ?? null);
  }

  const changed = [];
  const noteRows = [];
  for (const [noteId, n] of notes) {
    const hash = contentHash(n);
    if (existing.get(noteId) !== hash) changed.push(noteId);
    noteRows.push([
      uuid('id', noteId),
      uuid('sid', n.spaceId),
      n.folderId ? uuid('fid', n.folderId) : { name: 'fid', value: { isNull: true } },
      json('world', { centroid: n.centroid, hash }),
    ]);
  }
  if (noteRows.length) {
    await batch(
      `INSERT INTO notes (id,space_id,folder_id,world_origin,status)
       VALUES (:id,:sid,:fid,:world,'pending')
       ON CONFLICT (id) DO UPDATE SET
         folder_id = EXCLUDED.folder_id,
         world_origin = EXCLUDED.world_origin,
         updated_at = now(),
         status = CASE WHEN notes.world_origin->>'hash' IS DISTINCT FROM EXCLUDED.world_origin->>'hash'
                       THEN 'pending' ELSE notes.status END`,
      noteRows,
    );
  }

  // ── Strokes ──
  if (strokes.length) {
    await batch(
      `INSERT INTO strokes (id,note_id,space_id,geometry,color,thickness)
       VALUES (:id,:nid,:sid,:geo,:color,:thick)
       ON CONFLICT (id) DO UPDATE SET
         note_id=EXCLUDED.note_id, space_id=EXCLUDED.space_id,
         geometry=EXCLUDED.geometry, color=EXCLUDED.color, thickness=EXCLUDED.thickness`,
      strokes.map((k) => [
        uuid('id', k.id),
        uuid('nid', noteOf.get(k.id)),
        uuid('sid', resolveSpace(k.spaceId)),
        json('geo', k.geometry ?? {}),
        str('color', k.color),
        num('thick', k.thickness),
      ]),
    );
  }

  // ── Enqueue changed notes for enrichment ──
  for (let i = 0; i < changed.length; i += 10) {
    const chunk = changed.slice(i, i + 10);
    await sqs.send(
      new SendMessageBatchCommand({
        QueueUrl: QUEUE_URL,
        Entries: chunk.map((id, j) => ({ Id: String(j), MessageBody: JSON.stringify({ noteId: id }) })),
      }),
    );
  }

  return reply(200, { accepted: strokes.length, noteClusters: notes.size, enqueued: changed.length });
};
