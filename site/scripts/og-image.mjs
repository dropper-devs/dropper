// Generates public/og.png (1200x630) from an inline SVG using sharp.
// Build-time only — nothing OG-related ships in the Worker.
// Run: npm run og
import sharp from "sharp";
import { mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const out = join(dirname(fileURLToPath(import.meta.url)), "..", "public", "og.png");

// Deterministic waveform bars, mirroring the site mockup.
const bars = Array.from({ length: 48 }, (_, i) => {
  const v =
    52 +
    38 * Math.sin(i * 0.55) * Math.sin(i * 0.13 + 1.2) +
    22 * Math.sin(i * 1.9 + 0.4);
  return Math.round(Math.min(100, Math.max(10, Math.abs(v))));
});

const barWidth = 7;
const gap = 4;
const waveWidth = bars.length * (barWidth + gap) - gap;
const waveX = 600 - waveWidth / 2;
const waveMidY = 470;
const played = 0.42;

const waveSvg = bars
  .map((p, i) => {
    const h = (p / 100) * 90;
    const x = waveX + i * (barWidth + gap);
    const fill = (i + 0.5) / bars.length <= played ? "#8b9cf9" : "rgba(255,255,255,0.20)";
    return `<rect x="${x}" y="${waveMidY - h / 2}" width="${barWidth}" height="${h}" rx="2" fill="${fill}"/>`;
  })
  .join("\n");

const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="630">
  <defs>
    <radialGradient id="glow" cx="50%" cy="0%" r="90%">
      <stop offset="0%" stop-color="#8b9cf9" stop-opacity="0.22"/>
      <stop offset="60%" stop-color="#8b9cf9" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="1200" height="630" fill="#14151a"/>
  <rect width="1200" height="630" fill="url(#glow)"/>
  <g transform="translate(536,96) scale(2.7)">
    <path d="M12 2.7c3.6 4.4 6.3 8 6.3 11.4a6.3 6.3 0 1 1-12.6 0C5.7 10.7 8.4 7.1 12 2.7z" fill="#8b9cf9"/>
  </g>
  <text x="600" y="240" text-anchor="middle" font-family="-apple-system, 'SF Pro Display', 'Helvetica Neue', Arial, sans-serif" font-size="76" font-weight="800" fill="#d7d9e0" letter-spacing="-2">Dropper</text>
  <text x="600" y="316" text-anchor="middle" font-family="-apple-system, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif" font-size="38" font-weight="600" fill="#8b9cf9">Drop a file. Get a link.</text>
  <text x="600" y="372" text-anchor="middle" font-family="-apple-system, 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif" font-size="24" fill="rgba(215,217,224,0.55)">Menu bar sharing to your own Cloudflare R2 bucket — free, for macOS</text>
  ${waveSvg}
</svg>`;

await mkdir(dirname(out), { recursive: true });
await sharp(Buffer.from(svg)).png().toFile(out);
console.log(`wrote ${out}`);
