import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import './Hero.css';

export default function Hero() {
  const heroRef = useRef(null);
  const titleRef = useRef(null);
  const cursiveRef = useRef(null);
  const arImgRef = useRef(null);
  const cardRef = useRef(null);
  const taglineRef = useRef(null);

  useEffect(() => {
    const ctx = gsap.context(() => {
      const tl = gsap.timeline({ defaults: { ease: 'power4.out' } });

      tl.fromTo(
        cursiveRef.current,
        { y: 80, opacity: 0, rotateZ: -5 },
        { y: 0, opacity: 1, rotateZ: 0, duration: 1.2, delay: 0.5 }
      )
        .fromTo(
          '.hero-title-line',
          { y: 120, opacity: 0 },
          { y: 0, opacity: 1, duration: 1, stagger: 0.15 },
          '-=0.7'
        )
        .fromTo(
          arImgRef.current,
          { scale: 0.6, opacity: 0, rotation: -30 },
          { scale: 1, opacity: 0.55, rotation: 0, duration: 1.4 },
          '-=0.9'
        )
        .fromTo(
          cardRef.current,
          { x: 100, opacity: 0 },
          { x: 0, opacity: 1, duration: 1 },
          '-=0.8'
        )
        .fromTo(
          taglineRef.current,
          { y: 20, opacity: 0 },
          { y: 0, opacity: 1, duration: 0.8 },
          '-=0.4'
        );
    }, heroRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={heroRef} className="hero" id="hero">
      <div className="hero-content container">
        <div className="hero-left">
          <span ref={cursiveRef} className="hero-cursive">This is</span>
          <div ref={titleRef} className="hero-title">
            <div className="hero-title-line">SPATIAL</div>
            <div className="hero-title-line">BOARD</div>
          </div>
          <img
            ref={arImgRef}
            src="/assets/ar.png"
            alt="Spatial AR icon"
            className="hero-ar-image"
          />
        </div>
        <div ref={cardRef} className="hero-card">
          <p className="hero-card-text">
            A state of the art AR app, built specifically for AR glasses,
            showcased as a proof of concept on iPhone with LIMITED hardware.
          </p>
          <div className="hero-card-divider">
            <span className="hero-card-label">SPATIAL BOARD</span>
          </div>
          <p className="hero-card-text">
            Spatial AR note-taking app for iPhone with LiDAR that lets you draw,
            organize, and solve math in 3D space using hand gestures.
          </p>
        </div>
      </div>
      <div ref={taglineRef} className="hero-footer container">
        <span className="hero-handle">©SPATIALBOARD</span>
      </div>
    </section>
  );
}
