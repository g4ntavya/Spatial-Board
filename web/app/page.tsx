import { query } from '@/lib/db';
import Workspace, { type Space } from './Workspace';

export const dynamic = 'force-dynamic';

export default async function Home() {
  let spaces: Space[] = [];
  let dbError = false;
  try {
    spaces = (await query(
      `SELECT id::text AS id, name, color_hex FROM spaces ORDER BY created_at ASC`,
    )) as unknown as Space[];
  } catch (err) {
    console.error('failed to load spaces', err);
    dbError = true;
  }
  return <Workspace spaces={spaces} dbError={dbError} />;
}
