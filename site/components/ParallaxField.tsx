import ParallaxController from "./ParallaxController";

export default function ParallaxField() {
  return (
    <ParallaxController>
      <svg className="space-layer space-layer-slow" viewBox="0 0 1600 1000" preserveAspectRatio="xMidYMid slice">
        <defs>
          <radialGradient id="planet-a" cx="36%" cy="30%" r="78%">
            <stop offset="0%" stopColor="rgba(98, 120, 222, 0.34)" />
            <stop offset="100%" stopColor="rgba(28, 40, 88, 0.12)" />
          </radialGradient>
        </defs>
        {/* Saturn trick: ring passes behind the planet, then in front below */}
        <ellipse className="space-orbit" cx="1320" cy="230" rx="205" ry="54" transform="rotate(-17 1320 230)" />
        <circle className="space-orb" fill="url(#planet-a)" cx="1320" cy="230" r="126" />
        <g transform="rotate(-17 1320 230)">
          <path className="space-orbit front" d="M1115 230 A 205 54 0 0 0 1525 230" />
        </g>
        <circle className="space-star" cx="210" cy="180" r="2" />
        <circle className="space-star faint" cx="570" cy="310" r="1.4" />
        <circle className="space-star" cx="1030" cy="120" r="1.6" />
        <circle className="space-star faint" cx="1490" cy="720" r="1.8" />
        <circle className="space-star" cx="95" cy="415" r="1.6" />
        <circle className="space-star faint" cx="455" cy="555" r="1.3" />
        <circle className="space-star" cx="760" cy="235" r="1.8" />
        <circle className="space-star faint" cx="1240" cy="635" r="1.4" />
        <path className="space-sparkle" d="M636 140 h8 M640 136 v8" />
      </svg>
      <svg className="space-layer space-layer-mid" viewBox="0 0 1600 1000" preserveAspectRatio="xMidYMid slice">
        <defs>
          <radialGradient id="planet-b" cx="38%" cy="28%" r="80%">
            <stop offset="0%" stopColor="rgba(108, 128, 222, 0.33)" />
            <stop offset="100%" stopColor="rgba(36, 48, 100, 0.14)" />
          </radialGradient>
        </defs>
        <ellipse className="space-orbit fine" cx="470" cy="615" rx="118" ry="30" transform="rotate(21 470 615)" />
        <circle className="space-orb" fill="url(#planet-b)" cx="470" cy="615" r="64" />
        <g transform="rotate(21 470 615)">
          <path className="space-orbit fine front" d="M352 615 A 118 30 0 0 0 588 615" />
        </g>
        <circle className="space-star" cx="385" cy="90" r="1.2" />
        <circle className="space-star faint" cx="815" cy="650" r="2" />
        <circle className="space-star" cx="1210" cy="520" r="1.3" />
        <circle className="space-star" cx="985" cy="215" r="1.5" />
        <circle className="space-star faint" cx="1445" cy="235" r="1.2" />
        <circle className="space-star" cx="300" cy="505" r="1.7" />
        <circle className="space-star faint" cx="1090" cy="905" r="1.4" />
      </svg>
      <svg className="space-layer space-layer-fast" viewBox="0 0 1600 1000" preserveAspectRatio="xMidYMid slice">
        <defs>
          <linearGradient id="tail-a" gradientUnits="userSpaceOnUse" x1="970" y1="820" x2="1160" y2="690">
            <stop offset="0%" stopColor="rgba(165, 179, 251, 0.5)" />
            <stop offset="100%" stopColor="rgba(165, 179, 251, 0)" />
          </linearGradient>
          <linearGradient id="tail-b" gradientUnits="userSpaceOnUse" x1="120" y1="160" x2="260" y2="85">
            <stop offset="0%" stopColor="rgba(165, 179, 251, 0.42)" />
            <stop offset="100%" stopColor="rgba(165, 179, 251, 0)" />
          </linearGradient>
        </defs>
        <path className="space-comet" stroke="url(#tail-a)" d="M970 820 1160 690" />
        <circle className="space-star bright" cx="970" cy="820" r="3" />
        <path className="space-comet" stroke="url(#tail-b)" d="M120 160 260 85" />
        <circle className="space-star bright" cx="120" cy="160" r="2.4" />
        <circle className="space-star" cx="1460" cy="410" r="1.2" />
        <circle className="space-star faint" cx="665" cy="880" r="1.6" />
        <circle className="space-star" cx="250" cy="690" r="1.5" />
        <circle className="space-star faint" cx="1330" cy="860" r="1.8" />
        <circle className="space-star" cx="720" cy="395" r="1.1" />
      </svg>
    </ParallaxController>
  );
}
