import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import './Footer.css';

gsap.registerPlugin(ScrollTrigger);

export default function Footer() {
  const footerRef = useRef(null);

  useEffect(() => {
    const ctx = gsap.context(() => {
      gsap.fromTo(
        '.footer-rule',
        { scaleX: 0 },
        {
          scaleX: 1,
          duration: 1.2,
          ease: 'power3.inOut',
          scrollTrigger: { trigger: footerRef.current, start: 'top 95%' },
        }
      );

      gsap.fromTo(
        '.footer-inner',
        { y: 30, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.8,
          ease: 'power3.out',
          scrollTrigger: { trigger: footerRef.current, start: 'top 92%' },
        }
      );
    }, footerRef);

    return () => ctx.revert();
  }, []);

  return (
    <footer ref={footerRef} className="footer" id="footer">
      <div className="container">
        <div className="footer-rule" />
        <div className="footer-inner">
          <div className="footer-brand">
            <span className="footer-cursive">This is</span>
            <span className="footer-logo">SPATIAL BOARD</span>
          </div>

          <nav className="footer-nav">
            <a href="#features" className="footer-nav-link" id="footer-features-link">Features</a>
            <a href="#showcase" className="footer-nav-link" id="footer-screenshots-link">Screenshots</a>
            <a href="#demo" className="footer-nav-link" id="footer-demo-link">Demo</a>
            <a href="#tech-stack" className="footer-nav-link" id="footer-tech-link">Technology</a>
            <a
              href="https://github.com/g4ntavya/Spatial-Board"
              target="_blank"
              rel="noopener noreferrer"
              className="footer-nav-link"
              id="footer-github-link"
            >
              GitHub ↗
            </a>
          </nav>

          <div className="footer-colophon">
            <span>© 2026 Gantavya Rohilla</span>
            <span className="footer-sep">·</span>
            <a
              href="https://x.com/g4ntavya"
              target="_blank"
              rel="noopener noreferrer"
              className="footer-x-link"
              id="footer-x-link"
            >
              @g4ntavya
            </a>
            <span className="footer-sep">·</span>
            <span>MIT License</span>
          </div>
        </div>
      </div>
    </footer>
  );
}
