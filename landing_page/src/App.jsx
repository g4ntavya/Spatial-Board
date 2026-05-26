import { useEffect } from 'react';
import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import Navbar from './components/Navbar';
import Hero from './components/Hero';
import Notice from './components/Notice';
import Features from './components/Features';
import Showcase from './components/Showcase';
import DemoVideo from './components/DemoVideo';
import TechStack from './components/TechStack';
import Architecture from './components/Architecture';
import Footer from './components/Footer';
import './App.css';
import { Analytics } from "@vercel/analytics/next"

gsap.registerPlugin(ScrollTrigger);

function App() {
  useEffect(() => {
    return () => {
      ScrollTrigger.getAll().forEach((t) => t.kill());
    };
  }, []);

  return (
    <>
      <Navbar />
      <main>
        <Hero />
        <Notice />
        <Features />
        <Showcase />
        <DemoVideo />
        <TechStack />
        <Architecture />
      </main>
      <Footer />
    </>
  );
}

export default App;
