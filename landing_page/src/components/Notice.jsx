import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import './Notice.css';

gsap.registerPlugin(ScrollTrigger);

export default function Notice() {
  const sectionRef = useRef(null);

  useEffect(() => {
    const ctx = gsap.context(() => {
      gsap.fromTo(
        '.notice-rule',
        { scaleX: 0 },
        {
          scaleX: 1,
          duration: 1.2,
          ease: 'power3.inOut',
          scrollTrigger: {
            trigger: sectionRef.current,
            start: 'top 80%',
          },
        }
      );

      gsap.fromTo(
        '.notice-eyebrow',
        { y: 20, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.6,
          ease: 'power3.out',
          scrollTrigger: { trigger: sectionRef.current, start: 'top 78%' },
        }
      );

      gsap.fromTo(
        '.notice-statement',
        { y: 30, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.8,
          ease: 'power3.out',
          scrollTrigger: { trigger: sectionRef.current, start: 'top 75%' },
        }
      );

      gsap.fromTo(
        '.notice-actions',
        { y: 30, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.8,
          delay: 0.15,
          ease: 'power3.out',
          scrollTrigger: { trigger: sectionRef.current, start: 'top 70%' },
        }
      );
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} className="notice" id="notice">
      <div className="container">
        <div className="notice-rule" />
        <div className="notice-layout">
          <div className="notice-left">
            <span className="notice-eyebrow">Why a landing page?</span>
          </div>
          <div className="notice-right">
            <p className="notice-statement">
              Due to Apple TestFlight distribution restrictions requiring a paid
              Apple Developer account, SpatialBoard is currently showcased
              through an interactive demo and source repository.
            </p>
            <div className="notice-actions">
              <a
                href="https://youtu.be/NDZyi6bChMY"
                target="_blank"
                rel="noopener noreferrer"
                className="notice-link notice-link--primary"
                id="watch-demo-btn"
              >
                <span className="notice-link-icon">▶</span>
                Watch the demo
              </a>
              <a
                href="https://github.com/g4ntavya/Spatial-Board"
                target="_blank"
                rel="noopener noreferrer"
                className="notice-link notice-link--secondary"
                id="source-code-btn"
              >
                View source on GitHub →
              </a>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
