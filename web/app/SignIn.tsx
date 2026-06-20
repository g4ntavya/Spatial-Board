'use client';

import { useState } from 'react';
import { signIn } from 'next-auth/react';

export default function SignIn() {
  const [mode, setMode] = useState<'signin' | 'signup'>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setError('');

    if (mode === 'signup') {
      const res = await fetch('/api/signup', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ email, password }),
      });
      if (!res.ok) {
        setBusy(false);
        setError((await res.json().catch(() => ({})))?.error || 'Could not create account.');
        return;
      }
    }

    const res = await signIn('credentials', { email, password, redirect: false });
    setBusy(false);
    if (res?.error) setError(mode === 'signup' ? 'Account created, but sign-in failed.' : 'Invalid email or password.');
    else window.location.reload();
  }

  const isSignup = mode === 'signup';

  return (
    <div className="signin">
      <form className="signin-card" onSubmit={onSubmit}>
        <div className="signin-brand">SpatialBoard</div>
        <p className="signin-tagline">Your spatial notes, indexed and searchable.</p>
        <input
          className="signin-input"
          type="email"
          placeholder="Email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          autoComplete="username"
          required
        />
        <input
          className="signin-input"
          type="password"
          placeholder={isSignup ? 'Password (min 8 characters)' : 'Password'}
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          autoComplete={isSignup ? 'new-password' : 'current-password'}
          minLength={isSignup ? 8 : undefined}
          required
        />
        {error && <div className="signin-error">{error}</div>}
        <button type="submit" className="signin-btn" disabled={busy}>
          {busy ? (isSignup ? 'Creating account…' : 'Signing in…') : isSignup ? 'Create account' : 'Sign in'}
        </button>
        <button
          type="button"
          className="signin-switch"
          onClick={() => { setError(''); setMode(isSignup ? 'signin' : 'signup'); }}
        >
          {isSignup ? 'Already have an account? Sign in' : 'New here? Create an account'}
        </button>
      </form>
    </div>
  );
}
