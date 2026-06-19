import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { shouldAnimate } from '../lib/motion';
import './DemoVideo.css';

gsap.registerPlugin(ScrollTrigger);

export default function DemoVideo() {
  const sectionRef = useRef(null);

  useEffect(() => {
    if (!shouldAnimate()) return;
    const ctx = gsap.context(() => {
      gsap.fromTo(
        '.demo-eyebrow, .demo-title',
        { y: 50, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.9,
          stagger: 0.12,
          ease: 'power3.out',
          scrollTrigger: { trigger: sectionRef.current, start: 'top 80%' },
        }
      );

      gsap.fromTo(
        '.demo-embed',
        { y: 60, opacity: 0, scale: 0.97 },
        {
          y: 0,
          opacity: 1,
          scale: 1,
          duration: 1.2,
          ease: 'power3.out',
          scrollTrigger: { trigger: '.demo-embed', start: 'top 85%' },
        }
      );
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} className="demo" id="demo">
      <div className="container">
        <div className="demo-header">
          <div className="demo-header-left">
            <span className="demo-eyebrow">Demo</span>
            <h2 className="demo-title">Full walkthrough</h2>
          </div>
          <p className="demo-aside">
            Drawing, gesture recognition, Kon math solving, and spatial
            organization — all running in real-time on iPhone with LiDAR.
          </p>
        </div>

        <div className="demo-embed">
          <iframe
            src="https://www.youtube.com/embed/NDZyi6bChMY"
            title="SpatialBoard Demo Video"
            frameBorder="0"
            allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
            allowFullScreen
            id="demo-video-iframe"
          />
        </div>
      </div>
    </section>
  );
}
