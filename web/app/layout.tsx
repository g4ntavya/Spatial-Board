import type { Metadata } from 'next';
import './globals.css';

export const metadata: Metadata = {
  title: 'SpatialBoard — Library',
  description: 'Your spatial notes, indexed and searchable.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  // Set the theme before first paint to avoid a flash and so the sign-in screen
  // matches too.
  const themeBootstrap = `(function(){try{var t=localStorage.getItem('sb-theme')||(matchMedia('(prefers-color-scheme: dark)').matches?'dark':'light');document.documentElement.dataset.theme=t;}catch(e){}})();`;
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <script dangerouslySetInnerHTML={{ __html: themeBootstrap }} />
      </head>
      <body>{children}</body>
    </html>
  );
}
