import { query, str } from '@/lib/db';
import { auth } from '@/lib/auth';
import { userIdFromEmail } from '@/lib/identity';
import Workspace, { type Space } from './Workspace';
import SignIn from './SignIn';

export const dynamic = 'force-dynamic';

export default async function Home() {
  const session = await auth();
  const email = session?.user?.email;

  if (!email) return <SignIn />;

  const userId = userIdFromEmail(email);
  let spaces: Space[] = [];
  let dbError = false;
  try {
    spaces = (await query(
      `SELECT id::text AS id, name, color_hex FROM spaces WHERE user_id = :uid::uuid ORDER BY created_at ASC`,
      [str('uid', userId)],
    )) as unknown as Space[];
  } catch (err) {
    console.error('failed to load spaces', err);
    dbError = true;
  }
  return <Workspace spaces={spaces} dbError={dbError} userEmail={email} />;
}
