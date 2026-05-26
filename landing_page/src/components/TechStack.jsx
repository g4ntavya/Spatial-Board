import { useEffect, useRef } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import './TechStack.css';

gsap.registerPlugin(ScrollTrigger);

const techItems = [
  { name: 'ARKit', detail: 'WorldAnchors & Session Management' },
  { name: 'RealityKit', detail: '3D Mesh Rendering & Entities' },
  { name: 'Vision', detail: 'Hand Pose & Gesture Detection' },
  { name: 'SwiftData', detail: 'Persistent Spatial Models' },
  { name: 'Metal', detail: 'GPU-Accelerated Stroke Processing' },
  { name: 'Gemini AI', detail: 'Math Solving via API' },
  { name: 'Swift 6', detail: 'Full Concurrency with Actors' },
  { name: 'LiDAR', detail: 'Depth Sensing at 15 fps' },
];

const requirements = [
  { label: 'iOS', value: '26.0+' },
  { label: 'Xcode', value: '17.0+' },
  { label: 'Swift', value: '6.0' },
  { label: 'Device', value: 'iPhone Pro (LiDAR)' },
];

export default function TechStack() {
  const sectionRef = useRef(null);

  useEffect(() => {
    const ctx = gsap.context(() => {
      gsap.fromTo(
        '.tech-eyebrow, .tech-title',
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
        '.tech-chip',
        { scale: 0.85, opacity: 0 },
        {
          scale: 1,
          opacity: 1,
          duration: 0.5,
          stagger: 0.06,
          ease: 'back.out(1.4)',
          scrollTrigger: { trigger: '.tech-chips', start: 'top 85%' },
        }
      );

      gsap.fromTo(
        '.req-item',
        { y: 30, opacity: 0 },
        {
          y: 0,
          opacity: 1,
          duration: 0.6,
          stagger: 0.08,
          ease: 'power3.out',
          scrollTrigger: { trigger: '.req-grid', start: 'top 88%' },
        }
      );
    }, sectionRef);

    return () => ctx.revert();
  }, []);

  return (
    <section ref={sectionRef} className="techstack" id="tech-stack">
      <div className="container">
        <div className="tech-header">
          <div>
            <span className="tech-eyebrow">Technology</span>
            <h2 className="tech-title">Under the hood</h2>
          </div>
        </div>

        <div className="tech-chips">
          {techItems.map((item, i) => (
            <div key={i} className="tech-chip" id={`tech-chip-${i}`}>
              <span className="tech-chip-name">{item.name}</span>
              <span className="tech-chip-detail">{item.detail}</span>
            </div>
          ))}
        </div>

        <div className="req-section">
          <h3 className="req-heading">Requirements</h3>
          <div className="req-grid">
            {requirements.map((req, i) => (
              <div key={i} className="req-item" id={`req-${i}`}>
                <span className="req-label">{req.label}</span>
                <span className="req-value">{req.value}</span>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
