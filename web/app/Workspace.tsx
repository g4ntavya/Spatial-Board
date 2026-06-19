'use client';

import { useCallback, useEffect, useState } from 'react';

export type Space = { id: string; name: string; color_hex: string };
type Note = {
  id: string;
  title: string | null;
  category: string | null;
  ocr_text: string | null;
  status: string;
  updated_at: string;
  distance?: number;
};
type NoteDetail = Note & { svg: string | null };

export default function Workspace({ spaces, dbError }: { spaces: Space[]; dbError: boolean }) {
  const [activeId, setActiveId] = useState<string | undefined>(spaces[0]?.id);
  const [query, setQuery] = useState('');
  const [mode, setMode] = useState<'keyword' | 'semantic'>('keyword');
  const [notes, setNotes] = useState<Note[]>([]);
  const [loading, setLoading] = useState(false);
  const [selected, setSelected] = useState<NoteDetail | null>(null);

  const loadNotes = useCallback(async () => {
    if (!activeId) return;
    setLoading(true);
    try {
      const params = new URLSearchParams({ space: activeId, mode });
      if (query.trim()) params.set('q', query.trim());
      const res = await fetch(`/api/notes?${params}`, { cache: 'no-store' });
      setNotes(res.ok ? await res.json() : []);
    } finally {
      setLoading(false);
    }
  }, [activeId, query, mode]);

  // Debounce search / reload on space + mode change.
  useEffect(() => {
    const t = setTimeout(loadNotes, query ? 350 : 0);
    return () => clearTimeout(t);
  }, [loadNotes, query]);

  const openNote = async (id: string) => {
    const res = await fetch(`/api/note?id=${id}`, { cache: 'no-store' });
    if (res.ok) setSelected(await res.json());
  };

  if (dbError) {
    return (
      <div className="empty-full">
        <h1>Can’t reach the library</h1>
        <p>The web app couldn’t connect to Aurora. Check the AWS env vars in your Vercel project.</p>
      </div>
    );
  }

  return (
    <div className="app">
      {/* Spaces */}
      <aside className="spaces">
        <div className="brand">SpatialBoard</div>
        <div className="spaces-label">Spaces</div>
        {spaces.length === 0 && <div className="spaces-empty">No spaces yet</div>}
        {spaces.map((s) => (
          <button
            key={s.id}
            className={`space-row ${s.id === activeId ? 'active' : ''}`}
            onClick={() => {
              setActiveId(s.id);
              setSelected(null);
            }}
          >
            <span className="dot" style={{ background: s.color_hex || '#8E8E93' }} />
            {s.name}
          </button>
        ))}
      </aside>

      {/* Notes list */}
      <section className="list">
        <div className="search">
          <input
            placeholder="Search notes…"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
          <div className="modes">
            <button className={mode === 'keyword' ? 'on' : ''} onClick={() => setMode('keyword')}>
              Keyword
            </button>
            <button className={mode === 'semantic' ? 'on' : ''} onClick={() => setMode('semantic')}>
              Semantic
            </button>
          </div>
        </div>

        <div className="notes">
          {loading && <div className="hint">Searching…</div>}
          {!loading && notes.length === 0 && (
            <div className="hint">
              {query ? 'No matches.' : 'No notes yet. Draw in the app and exit to sync.'}
            </div>
          )}
          {notes.map((n) => (
            <button
              key={n.id}
              className={`note-card ${selected?.id === n.id ? 'active' : ''}`}
              onClick={() => openNote(n.id)}
            >
              <div className="note-title">{n.title || 'Untitled note'}</div>
              <div className="note-snippet">
                {n.ocr_text?.trim() || (n.status === 'pending' ? 'Processing…' : 'No text')}
              </div>
              <div className="note-meta">
                {n.category && <span className="tag">{n.category}</span>}
                <span className="date">{formatDate(n.updated_at)}</span>
              </div>
            </button>
          ))}
        </div>
      </section>

      {/* Detail */}
      <main className="detail">
        {selected ? (
          <>
            <header className="detail-head">
              <h1>{selected.title || 'Untitled note'}</h1>
              <div className="detail-meta">
                {selected.category && <span className="tag">{selected.category}</span>}
                <span className="date">{formatDate(selected.updated_at)}</span>
              </div>
            </header>
            {selected.svg ? (
              <div className="canvas" dangerouslySetInnerHTML={{ __html: selected.svg }} />
            ) : (
              <div className="canvas placeholder">
                {selected.status === 'pending' ? 'Still processing…' : 'No rendering'}
              </div>
            )}
            {selected.ocr_text?.trim() && (
              <div className="transcript">
                <div className="transcript-label">Transcription</div>
                <p>{selected.ocr_text}</p>
              </div>
            )}
          </>
        ) : (
          <div className="empty">Select a note</div>
        )}
      </main>
    </div>
  );
}

function formatDate(iso: string) {
  const d = new Date(iso.replace(' ', 'T') + 'Z');
  if (isNaN(d.getTime())) return '';
  return d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}
