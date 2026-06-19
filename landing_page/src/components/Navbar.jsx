import { useEffect, useRef, useState } from 'react';
import gsap from 'gsap';
import { shouldAnimate } from '../lib/motion';
import './Navbar.css';

const LINKS = [
  { label: 'Idea', href: '#idea' },
  { label: 'Pipeline', href: '#pipeline' },
  { label: 'Stack', href: '#stack' },
  { label: 'Demo', href: '#demo' },
];

export default function Navbar() {
  const navRef = useRef(null);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    let ctx;
    if (shouldAnimate()) ctx = gsap.context(() => {
      gsap.fromTo(
        '.nav-fade',
        { y: -18, opacity: 0 },
        { y: 0, opacity: 1, duration: 0.9, stagger: 0.07, ease: 'power3.out', delay: 0.15 }
      );
    }, navRef);

    const onScroll = () => setScrolled(window.scrollY > 24);
    window.addEventListener('scroll', onScroll, { passive: true });
    onScroll();
    return () => {
      ctx?.revert();
      window.removeEventListener('scroll', onScroll);
    };
  }, []);

  return (
    <nav ref={navRef} className={`navbar ${scrolled ? 'is-scrolled' : ''}`} id="navbar">
      <div className="navbar-inner container">
        <a href="#top" className="nav-fade navbar-brand">
          SpatialBoard
        </a>
        <div className="nav-fade navbar-links">
          {LINKS.map((l) => (
            <a key={l.href} href={l.href} className="navbar-link">{l.label}</a>
          ))}
        </div>
        <a
          href="https://github.com/g4ntavya/Spatial-Board"
          target="_blank"
          rel="noopener noreferrer"
          className="nav-fade navbar-cta"
          id="nav-github-btn"
        >
          GitHub
        </a>
      </div>
    </nav>
  );
}
