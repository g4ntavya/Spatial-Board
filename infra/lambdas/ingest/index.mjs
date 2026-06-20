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

const LINK_RADIUS = 0.16;    // metres — single-linkage gap inside one note (tight: keeps topics apart)
const APPEND_RADIUS = 0.30;  // metres — a new cluster this close to an existing note re-joins it

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
  // Strokes are grouped by (space, folder), then single-linkage clustered by
  // NEAREST-MEMBER distance (not centroid) so a long line of writing stays one
  // note while a separate topic 20cm away becomes its own note. This fixes
  // unrelated content (e.g. "my name is …" and "4×4=16") being merged.
  const noteOf = new Map(); // strokeId -> noteId
  const notes = new Map();  // noteId -> { spaceId, folderId, members:[], centroid, category }

  const folderName = new Map(folders.map((f) => [f.id, f.name ?? 'Folder']));
  const meanCentroid = (members) => {
    const s = members.reduce((a, m) => {
      const c = centroidOf(m.geometry);
      return [a[0] + c[0], a[1] + c[1], a[2] + c[2]];
    }, [0, 0, 0]);
    const n = members.length || 1;
    return [s[0] / n, s[1] / n, s[2] / n];
  };

  // Single-linkage: a stroke joins a cluster if it's within LINK_RADIUS of ANY
  // member of that cluster; clusters that both match get merged.
  function singleLinkage(items, radius) {
    const cs = []; // { members:[stroke], pts:[centroid] }
    for (const k of items) {
      const c = centroidOf(k.geometry);
      const hits = [];
      for (let i = 0; i < cs.length; i++) {
        if (cs[i].pts.some((p) => dist(p, c) < radius)) hits.push(i);
      }
      if (!hits.length) { cs.push({ members: [k], pts: [c] }); continue; }
      const base = cs[hits[0]];
      base.members.push(k); base.pts.push(c);
      for (let j = hits.length - 1; j >= 1; j--) {
        const m = cs[hits[j]];
        base.members.push(...m.members); base.pts.push(...m.pts);
        cs.splice(hits[j], 1);
      }
    }
    return cs.map((x) => x.members);
  }

  // Group by (space, folder|free)
  const groups = new Map();
  for (const k of strokes) {
    const sid = resolveSpace(k.spaceId);
    const fid = k.folderId ?? null;
    const key = `${sid}|${fid ?? ''}`;
    if (!groups.has(key)) groups.set(key, { spaceId: sid, folderId: fid, items: [] });
    groups.get(key).items.push(k);
  }

  // Contextual append: pull existing FREE notes in the synced spaces so new
  // strokes written right next to an old note (days later) re-join it instead of
  // spawning a duplicate. Proximity is the signal the user asked for ("very close
  // in distance"); the whole note is then re-OCR'd so the context stays coherent.
  const syncedSpaceIds = [...new Set([...groups.values()].map((g) => g.spaceId))];
  const existingFree = []; // { id, spaceId, centroid }
  if (syncedSpaceIds.length) {
    const res = await exec(
      `SELECT id::text AS id, space_id::text AS sid, world_origin->'centroid' AS c
         FROM notes
        WHERE space_id = ANY(:sids::uuid[]) AND folder_id IS NULL AND (world_origin ? 'hash')`,
      [{ name: 'sids', value: { stringValue: `{${syncedSpaceIds.join(',')}}` } }],
    );
    for (const r of res.records ?? []) {
      let c = null;
      try { c = JSON.parse(r[2]?.stringValue ?? 'null'); } catch { /* ignore */ }
      if (Array.isArray(c) && c.length === 3) existingFree.push({ id: r[0].stringValue, spaceId: r[1].stringValue, centroid: c });
    }
  }

  const addToNote = (noteId, fields, members) => {
    if (notes.has(noteId)) {
      const ex = notes.get(noteId);
      ex.members.push(...members);
      ex.centroid = meanCentroid(ex.members);
    } else {
      notes.set(noteId, { ...fields, members, centroid: meanCentroid(members) });
    }
    for (const m of members) noteOf.set(m.id, noteId);
  };

  for (const { spaceId, folderId, items } of groups.values()) {
    for (const cl of singleLinkage(items, LINK_RADIUS)) {
      const c = meanCentroid(cl);
      let noteId = null;
      if (folderId === null) {
        // attach to the nearest existing free note if it's close enough
        let best = null;
        for (const e of existingFree) {
          if (e.spaceId !== spaceId) continue;
          const d = dist(e.centroid, c);
          if (d < APPEND_RADIUS && (!best || d < best.d)) best = { id: e.id, d };
        }
        if (best) noteId = best.id;
      }
      const category = folderId !== null ? folderName.get(folderId) ?? 'Folder' : null;
      if (!noteId) {
        const ids = cl.map((m) => m.id).sort();
        noteId = uuidFrom('note', spaceId, folderId ?? 'free', ids[0]);
      }
      addToNote(noteId, { spaceId, folderId, category }, cl);
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
      str('category', n.category ?? null),
      json('world', { centroid: n.centroid, hash }),
    ]);
  }
  if (noteRows.length) {
    await batch(
      // Folder notes carry their folder name as the category (so in-app folders
      // show up as folders on the web). Free notes leave category to the Process
      // Lambda's classifier — and we never clobber that on re-sync.
      `INSERT INTO notes (id,space_id,folder_id,category,world_origin,status)
       VALUES (:id,:sid,:fid,:category,:world,'pending')
       ON CONFLICT (id) DO UPDATE SET
         folder_id = EXCLUDED.folder_id,
         category = CASE WHEN EXCLUDED.folder_id IS NOT NULL THEN EXCLUDED.category ELSE notes.category END,
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

  // ── Remove orphaned notes ──
  // After re-clustering, an ingest-made note can end up with no strokes (a ghost
  // duplicate). Delete those in the synced spaces. Seeded/demo notes have no
  // 'hash' in world_origin, so they're preserved.
  if (syncedSpaceIds.length) {
    await exec(
      `DELETE FROM notes
         WHERE space_id = ANY(:sids::uuid[])
           AND (world_origin ? 'hash')
           AND NOT EXISTS (SELECT 1 FROM strokes s WHERE s.note_id = notes.id)`,
      [{ name: 'sids', value: { stringValue: `{${syncedSpaceIds.join(',')}}` } }],
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
