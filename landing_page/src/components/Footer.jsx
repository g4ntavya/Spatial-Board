import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { shouldAnimate } from '../lib/motion';
import './Footer.css';

gsap.registerPlugin(ScrollTrigger);

const LINKS = [
  { label: 'Idea', href: '#idea', id: 'footer-idea-link' },
  { label: 'Pipeline', href: '#pipeline', id: 'footer-pipeline-link' },
  { label: 'Stack', href: '#stack', id: 'footer-stack-link' },
  { label: 'Demo', href: '#demo', id: 'footer-demo-link' },
  { label: 'Architecture', href: '#architecture', id: 'footer-arch-link' },
];

export default function Footer() {
  const footerRef = useRef(null);

  useEffect(() => {
    if (!shouldAnimate()) return;
    const ctx = gsap.context(() => {
      gsap.fromTo('.footer-rule', { scaleX: 0 }, {
        scaleX: 1, duration: 1.2, ease: 'power3.inOut',
        scrollTrigger: { trigger: footerRef.current, start: 'top 95%' },
      });
      gsap.fromTo('.footer-col', { y: 24, opacity: 0 }, {
        y: 0, opacity: 1, duration: 0.8, stagger: 0.08, ease: 'power3.out',
        scrollTrigger: { trigger: footerRef.current, start: 'top 90%' },
      });
    }, footerRef);
    return () => ctx.revert();
  }, []);

  return (
    <footer ref={footerRef} className="footer" id="footer">
      <div className="container">
        <div className="footer-rule rule" />
        <div className="footer-grid">
          <div className="footer-col footer-brand">
            <span className="footer-logo">SpatialBoard</span>
            <p className="footer-tagline">
              Handwriting, anchored in space — indexed by AWS.
            </p>
          </div>

          <nav className="footer-col footer-nav">
            <span className="footer-nav-label">Sections</span>
            {LINKS.map((l) => (
              <a key={l.href} href={l.href} className="footer-nav-link" id={l.id}>{l.label}</a>
            ))}
          </nav>

          <nav className="footer-col footer-nav">
            <span className="footer-nav-label">Elsewhere</span>
            <a href="https://github.com/g4ntavya/Spatial-Board" target="_blank" rel="noopener noreferrer" className="footer-nav-link" id="footer-github-link">GitHub</a>
            <a href="https://youtu.be/sIWVNEsMZm8" target="_blank" rel="noopener noreferrer" className="footer-nav-link" id="footer-video-link">Demo video</a>
            <a href="https://x.com/g4ntavya" target="_blank" rel="noopener noreferrer" className="footer-nav-link" id="footer-x-link">@g4ntavya</a>
          </nav>
        </div>

        <div className="footer-col footer-colophon">
          <span>© 2026 Gantavya Rohilla</span>
          <span className="footer-sep">/</span>
          <span>MIT License</span>
          <span className="footer-sep">/</span>
          <span>Built for H0 — Hack the Zero Stack</span>
        </div>
      </div>
    </footer>
  );
}
