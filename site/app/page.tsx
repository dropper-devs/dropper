import ParallaxField from "@/components/ParallaxField";
import Nav from "@/components/sections/Nav";
import Hero from "@/components/sections/Hero";
import FeatureDemo from "@/components/sections/FeatureDemo";
import HowItWorks from "@/components/sections/HowItWorks";
import SharePages from "@/components/sections/SharePages";
import Screenshots from "@/components/sections/Screenshots";
import Collections from "@/components/sections/Collections";
import Conversion from "@/components/sections/Conversion";
import Organize from "@/components/sections/Organize";
import Ownership from "@/components/sections/Ownership";
import SetupWizard from "@/components/sections/SetupWizard";
import GetDropper from "@/components/sections/GetDropper";
import Footer from "@/components/sections/Footer";

/* Displacement map for the glass lens: R encodes horizontal shift, G
   vertical; #808000 is "no shift". A blurred neutral rounded-rect sits over
   edge-to-edge gradients, confining refraction to a soft bevel. */
const LENS_MAP =
  "data:image/svg+xml;utf8," +
  encodeURIComponent(
    "<svg xmlns='http://www.w3.org/2000/svg' width='400' height='260'>" +
      "<defs>" +
      "<linearGradient id='gx' x1='0' y1='0' x2='1' y2='0'>" +
      "<stop offset='0' stop-color='#ff0000'/><stop offset='1' stop-color='#000000'/>" +
      "</linearGradient>" +
      "<linearGradient id='gy' x1='0' y1='0' x2='0' y2='1'>" +
      "<stop offset='0' stop-color='#00ff00'/><stop offset='1' stop-color='#000000'/>" +
      "</linearGradient>" +
      "<filter id='b'><feGaussianBlur stdDeviation='12'/></filter>" +
      "</defs>" +
      "<rect width='400' height='260' fill='url(#gx)'/>" +
      "<rect width='400' height='260' fill='url(#gy)' style='mix-blend-mode:screen'/>" +
      "<rect x='22' y='22' width='356' height='216' rx='44' fill='#808000' filter='url(#b)'/>" +
      "</svg>",
  );

export default function Home() {
  return (
    <>
      {/* Refraction engine for the liquid-glass cards. The displacement map
          (an inline SVG image) is neutral gray in the middle and ramps to
          full red/green at the borders, so the backdrop bends hard at the
          pane's edges — a lens bevel — and stays clear in the center. */}
      <svg style={{ display: "none" }} aria-hidden="true">
        <filter id="liquid-glass" x="-10%" y="-10%" width="120%" height="120%">
          <feImage href={LENS_MAP} preserveAspectRatio="none" result="map" />
          <feDisplacementMap
            in="SourceGraphic"
            in2="map"
            scale="64"
            xChannelSelector="R"
            yChannelSelector="G"
          />
        </filter>
      </svg>
      <Nav />
      <ParallaxField />
      <main>
        <Hero />
        <FeatureDemo />
        <HowItWorks />
        <SharePages />
        <Screenshots />
        <Collections />
        <Conversion />
        <Organize />
        <Ownership />
        <SetupWizard />
        <GetDropper />
      </main>
      <Footer />
    </>
  );
}
