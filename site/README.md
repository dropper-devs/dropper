# Dropper marketing site

One-page marketing site for [Dropper](../) — Next.js (App Router) deployed to
**Cloudflare Workers** via the OpenNext Cloudflare adapter
([`@opennextjs/cloudflare`](https://opennext.js.org/cloudflare)).

## Stack

- Next.js 16 (App Router, all pages statically prerendered)
- `@opennextjs/cloudflare` 1.x + `wrangler` 4.x
- No CSS framework — hand-rolled design system in `app/globals.css` using the
  app's own palette (`#14151a` background, `#8b9cf9` accent)
- Node 26 for tooling (`export PATH=/opt/homebrew/opt/node/bin:$PATH` on this
  machine — the system Node 20 is too old)

## Commands

```sh
npm install
npm run dev        # Next dev server (fast iteration)  → http://localhost:3000
npm run build      # plain `next build`
npm run preview    # OpenNext build + local Workers runtime (workerd) preview
npm run deploy     # OpenNext build + production Worker deployment
npm run og         # regenerate public/og.png (sharp, build-time only)
npm run demo-assets # regenerate demo media + peaks + /demo share page (see below)
npm run wallpaper  # regenerate the optimized hero wallpaper (see below)
npm run cf-typegen # generate CloudflareEnv types from wrangler.jsonc
```

`npm run preview` is the one that matters before shipping: it runs the site in
workerd, the same runtime as production Workers.

## Public share route

The `SHARE_BUCKET` R2 binding exposes only the `dropper-page/share/` namespace
at `https://dropper.page/share/*`. The separate `installers/` namespace is not
reachable through this route. The native app uploads directly to R2's
authenticated S3 endpoint; the Worker only handles public `GET` and `HEAD`
requests and streams object bodies without buffering them.

The URL prefix is removed before lookup, so this object:

```text
share/example-a1b2c3/index.html
```

is available at:

```text
https://dropper.page/share/example-a1b2c3/index.html
```

## Deploying

The site and public R2 share route are live on `dropper.page`. Deploy updates
from this directory with:

```bash
npm run deploy
```

For a first deployment in a new Cloudflare account:

1. `npx wrangler login` (or set `CLOUDFLARE_API_TOKEN`).
2. Set up the KV binding (below) if you want the email form to store anything.
3. `npm run deploy` — deploys the Worker named `dropper-site` per
   `wrangler.jsonc`. Add a custom domain in the Cloudflare dashboard (Workers
   → dropper-site → Domains & Routes) or via `routes` in `wrangler.jsonc`.

## Email capture / KV setup

`POST /api/subscribe` validates the address (plus a `website` honeypot field —
bots that fill it get a fake success) and writes
`subscriber:<email> → {"email", "subscribedAt"}` into a KV namespace bound as
`SUBSCRIBERS`.

Without the binding the route returns a clear **503** and the form shows an
error — nothing crashes, so local dev works out of the box.

To enable storage:

```sh
npx wrangler kv namespace create SUBSCRIBERS
```

then uncomment the `kv_namespaces` block in `wrangler.jsonc` and paste the id
it prints:

```jsonc
"kv_namespaces": [
  { "binding": "SUBSCRIBERS", "id": "<namespace-id>" }
]
```

`npm run preview` (and `next dev`, via `initOpenNextCloudflareForDev()`) will
then use a **local simulated** KV; the deployed Worker uses the real one.
List collected addresses with:

```sh
npx wrangler kv key list --binding SUBSCRIBERS --remote
```

## Hero demo & the /demo share page

The hero is a **working demo**: drag one of the placeholder chips (IMAGE /
AUDIO / MOVIE / ZIP) onto the dropdown's drop strip — or just tap a chip —
and it runs the app's real flow: progress ring → links state → highlighted
row in the list. "Copy page link" / "Copy file link" write real URLs to the
clipboard; "Open web page" opens `/demo/`, a **byte-faithful port of the
app's generated share page** (from `Sources/Dropper/SharePage.swift`) baked
to `public/demo/index.html`, deep-linked to that item's `<figure id>` anchor.

`npm run demo-assets` (script: `scripts/demo-assets.mjs`) generates:

- `public/demo/placeholder-image.png` — on-palette placeholder (sharp)
- `public/demo/placeholder-audio.wav` — ~4 s of synthesized plucks (16-bit PCM)
- `public/demo/placeholder-movie.mp4` — 3 s H.264 test clip (**needs ffmpeg**;
  skipped with a warning if ffmpeg isn't on PATH)
- `public/demo/placeholder-files.zip` — a real stored zip of a README.txt
- **real waveform peaks** computed from the WAV — the same algorithm as the
  app's `AudioConverter.peaks`: 200 buckets, max |sample| across channels per
  bucket, normalized to 0–100 integers
- `public/demo/index.html` — the share page itself (peaks, video
  width/height via ffprobe, file sizes all baked in)
- `lib/demo-manifest.json` — file names + sizes that drive the hero chips/rows

### Swapping in real media

1. Replace the files in `public/demo/` **keeping the same names**
   (`placeholder-image.png`, `placeholder-audio.wav` — 16/24/32-bit int or
   float32 PCM WAV, `placeholder-movie.mp4` — H.264, `placeholder-files.zip`).
2. Open `scripts/demo-assets.mjs` and set `REGENERATE = false` (top of file)
   so your files are never overwritten.
3. `npm run demo-assets` — recomputes peaks from your WAV, re-probes the
   movie's dimensions, re-reads sizes, and re-bakes `index.html` +
   `demo-manifest.json`.
4. Rebuild/preview as usual.

## Placeholders to swap before launch

| What | Where |
| --- | --- |
| Download URL (DMG/zip) | `DOWNLOAD_URL` in `lib/site.ts` |
| Production origin (canonical/OG URLs) | `SITE_URL` in `lib/site.ts` |
| Demo media | `public/demo/` + `npm run demo-assets` (see above) |
| Hero wallpaper | Replace `public/wallpaper.jpg`, run `npm run wallpaper` |
| Real screenshots | Pass `src="/shots/…"` to any `<ProductShot>` in `app/page.tsx` — the HTML/CSS mockup is the automatic fallback |

## Hero wallpaper

The hero's desktop background is `public/wallpaper.jpg` (the untouched
original — currently 3840×2160, 2.6 MB). Visitors never download it: the
site serves `public/wallpaper-1600.webp` (~190 KB), generated by
`npm run wallpaper` (sharp resize to 1600w, WebP, quality auto-stepped to
stay under ~280 KB). A dark scrim sits over it in CSS (`.mock-desktop`) so
the frosted dropdown keeps its contrast. After replacing `wallpaper.jpg`,
re-run `npm run wallpaper`.

## Product visuals

There are no fake screenshots. The app UI is recreated as HTML/CSS
components (crisp at any DPI, zero image weight):

- `components/HeroDemo.tsx` — the interactive menu bar dropdown
  (toolbar, path bar, row list, drop strip, footer — layout mirrors
  `ShareListView.swift`), plus the draggable demo file chips
- `components/mockups/SharePageMockup.tsx` — share page in a browser frame
  (waveform audio player, video player, markdown + download cards)
- `components/mockups/MarkupMockup.tsx` — screenshot markup window (tools,
  the app's 7-color palette, stroke slider, annotated canvas)
- `components/mockups/SplitDropMockup.tsx` — the "Add to collection /
  Upload new item" split drop zone

The static ones are wrapped in `components/ProductShot.tsx`, which swaps to
a real `<img>` the moment you pass it a `src`.
