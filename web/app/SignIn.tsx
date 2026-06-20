'use client';

import { useState } from 'react';
import { signIn } from 'next-auth/react';

export default function SignIn() {
  const [mode, setMode] = useState<'signin' | 'signup'>('signin');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);
  const [showPw, setShowPw] = useState(false);

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
        <div className="signin-pw">
          <input
            className="signin-input"
            type={showPw ? 'text' : 'password'}
            placeholder={isSignup ? 'Password (min 8 characters)' : 'Password'}
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            autoComplete={isSignup ? 'new-password' : 'current-password'}
            minLength={isSignup ? 8 : undefined}
            required
          />
          <button
            type="button"
            className="signin-eye"
            onClick={() => setShowPw((s) => !s)}
            aria-label={showPw ? 'Hide password' : 'Show password'}
            title={showPw ? 'Hide password' : 'Show password'}
          >
            {showPw ? <EyeOffIcon /> : <EyeIcon />}
          </button>
        </div>
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

const EyeIcon = () => (<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><path d="M1.5 12S5 5 12 5s10.5 7 10.5 7-3.5 7-10.5 7S1.5 12 1.5 12z" /><circle cx="12" cy="12" r="3" /></svg>);
const EyeOffIcon = () => (<svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8"><path d="M3 3l18 18M10.6 5.2A10.9 10.9 0 0 1 12 5c7 0 10.5 7 10.5 7a18 18 0 0 1-3.3 4.2M6.3 6.3A18 18 0 0 0 1.5 12S5 19 12 19a10.7 10.7 0 0 0 4.2-.85M9.9 9.9a3 3 0 0 0 4.2 4.2" /></svg>);
