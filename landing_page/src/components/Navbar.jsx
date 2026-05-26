import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import './Navbar.css';

export default function Navbar() {
  const navRef = useRef(null);

  useEffect(() => {
    const ctx = gsap.context(() => {
      gsap.fromTo(
        '.navbar-name',
        { y: -30, opacity: 0 },
        { y: 0, opacity: 1, duration: 1, ease: 'power3.out', delay: 0.2 }
      );
      gsap.fromTo(
        '.navbar-year',
        { y: -30, opacity: 0 },
        { y: 0, opacity: 1, duration: 1, ease: 'power3.out', delay: 0.35 }
      );
    }, navRef);
    return () => ctx.revert();
  }, []);

  return (
    <nav ref={navRef} className="navbar" id="navbar">
      <div className="navbar-inner container">
        <span className="navbar-name">Gantavya Rohilla</span>
        <span className="navbar-year">2026</span>
      </div>
    </nav>
  );
}
