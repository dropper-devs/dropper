// Generates the optimized wallpaper derivative served by the hero demo.
// The original (public/wallpaper.jpg) is kept untouched and is never
// referenced by the site — only the derivative ships to visitors.
//
//   npm run wallpaper
//
// Re-run after replacing public/wallpaper.jpg.
import sharp from "sharp";
import { statSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const pub = join(dirname(fileURLToPath(import.meta.url)), "..", "public");
const src = join(pub, "wallpaper.jpg");
const out = join(pub, "wallpaper-1600.webp");

// Step quality down until the derivative is comfortably small.
let quality = 78;
for (;;) {
  await sharp(src).resize({ width: 1600 }).webp({ quality }).toFile(out);
  const kb = Math.round(statSync(out).size / 1024);
  if (kb <= 280 || quality <= 50) {
    console.log(`wrote wallpaper-1600.webp (${kb} KB, q${quality})`);
    break;
  }
  quality -= 8;
}
