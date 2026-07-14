# Dropper marketing site

One-page marketing site for [Dropper](../) — Next.js (App Router) deployed to
**Cloudflare Workers** via the OpenNext Cloudflare adapter
([`@opennextjs/cloudflare`](https://opennext.js.org/cloudflare)).

## Stack

- Next.js 16 (App Router, all pages statically prerendered)
- `@opennextjs/cloudflare` 1.x + `wrangler` 4.x
- No CSS framework — hand-rolled design system in `app/globals.css` using the
  app's own palette (`#07101f` background, `#8b9cf9` accent)
- Node 26 for tooling, pinned in the repository root `.tool-versions` (run
  `asdf install` from the repository root)

## Commands

```sh
npm install
npm run dev        # Next dev server (fast iteration)  → http://localhost:3000
npm run build      # plain `next build`
npm run typecheck  # strict TypeScript + unused-symbol checks
npm run check      # typecheck + production Next build
npm run preview    # OpenNext build + local Workers runtime (workerd) preview
npm run deploy     # OpenNext build + production Worker deployment
npm run upload     # OpenNext build + upload a new Worker version (no deploy)
npm run og         # regenerate public/og.png (sharp, build-time only)
npm run wallpaper  # regenerate the optimized hero wallpaper (see below)
npm run cf-typegen # generate CloudflareEnv types from wrangler.jsonc
```

`npm run preview` is the one that matters before shipping: it runs the site in
workerd, the same runtime as production Workers.

## Public share route

Public shares do not enter Next or OpenNext. The standalone native Worker in
`../workers/share.ts` owns the more-specific `dropper.page/share/*` Cloudflare
route and streams R2 bodies directly. The native app continues uploading to
R2's authenticated S3 endpoint, and all existing branded URLs stay unchanged.

The URL prefix is removed before lookup, so this object:

```text
share/example-a1b2c3/index.html
```

is available at:

```text
https://dropper.page/share/example-a1b2c3/index.html
```

The site's `DOWNLOAD_BUCKET` binding only exposes one fixed object from the
separate `installers/` namespace:
`GET /downloads/Dropper.dmg` streams the single fixed object
`installers/Dropper_latest.dmg` — the key is hardcoded server-side, and the
short cache lifetime means a new release propagates within minutes. The
conditional-request and Range mechanics live in `lib/r2-http.ts`.

## Deploying

Deploy site updates from this directory with:

```bash
npm run deploy
```

Deploy the independent share Worker from the repository root with:

```bash
cd site
npx wrangler deploy --config ../workers/share.wrangler.jsonc
```

The checked-in `wrangler.jsonc` targets Dropper's production custom domains.
Maintainer deployments only require
authentication (`npx wrangler login` or `CLOUDFLARE_API_TOKEN`) followed by
`npm run deploy`.

For a fork or first deployment in a different Cloudflare account:

1. `npx wrangler login` (or set `CLOUDFLARE_API_TOKEN`).
2. Replace or remove the production entries under `routes` in `wrangler.jsonc`.
3. `npm run deploy` — deploys the Worker named `dropper-site` per
   `wrangler.jsonc`.

## Hero demo

The hero is a **working demo**: drag one of the file chips (IMAGE / AUDIO /
MOVIE / MD) onto the dropdown's drop strip — or just tap a chip — and it runs
the app's real flow: progress ring → links state → highlighted row in the
list. The links are real too: "Copy page link" / "Copy file link" put live
URLs on the clipboard, and "Open web page" opens a share page made with the
actual app, served from the real bucket (URLs in `components/demo/data.ts`).

The chips' file names and sizes come from `lib/demo-manifest.json`, a
hand-maintained static file (see its `note` field). To swap in different demo
media: upload with the app, then update the share URLs in
`components/demo/data.ts` and the names/sizes in the manifest.

## Download route

`make release` at the repo root uploads the DMG to
`installers/Dropper_latest.dmg` in the `dropper-page` bucket;
`app/downloads/Dropper.dmg/route.ts` serves it at
`https://dropper.page/downloads/Dropper.dmg`. `DOWNLOAD_URL` in `lib/site.ts`
(every download CTA) points there. Because the object is overwritten in place
on release, the route sends a short `max-age` with ETag revalidation — never
an immutable cache.

## Placeholders to swap before launch

| What                                  | Where                                                                                                                                                                       |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Download URL (DMG)                    | Wired up: `DOWNLOAD_URL` in `lib/site.ts` → `/downloads/Dropper.dmg` (see above)                                                                                            |
| Production origin (canonical/OG URLs) | `SITE_URL` in `lib/site.ts`                                                                                                                                                 |
| Demo media                            | Share URLs in `components/demo/data.ts` + names/sizes in `lib/demo-manifest.json`                                                                                           |
| Hero wallpaper                        | Replace `public/wallpaper.jpg`, run `npm run wallpaper`                                                                                                                     |
| Real screenshots                      | Pass `src="/shots/…"` to a `<ProductShot>` in `components/sections/SharePages.tsx`, `Screenshots.tsx`, or `Collections.tsx` — the HTML/CSS mockup is the automatic fallback |

## Hero wallpaper

The hero's desktop background is `public/wallpaper.jpg` (the untouched
original — currently 3840×2160, 2.6 MB). Visitors never download it: the
site serves `public/wallpaper-1600.webp` (~190 KB), generated by
`npm run wallpaper` (sharp resize to 1600w, WebP, quality auto-stepped to
stay under ~280 KB). A dark scrim sits over it in CSS (`.mock-desktop`) so
the frosted dropdown keeps its contrast. After replacing `wallpaper.jpg`,
re-run `npm run wallpaper`.

## Product visuals

There are no fake screenshots. The markup-editor shot is a real capture
(`public/screenshot-editor.png`); the rest of the app UI is recreated as
HTML/CSS components (crisp at any DPI, zero image weight):

- `components/HeroDemo.tsx` — the interactive menu bar dropdown
  (toolbar, path bar, row list, drop strip, footer — layout mirrors
  `ShareListView.swift`), plus the draggable demo file chips
- `components/mockups/SharePageMockup.tsx` — share page in a browser frame
  (waveform audio player, video player, markdown + download cards)
- `components/mockups/SplitDropMockup.tsx` — the "Add to collection /
  Upload new item" split drop zone

The static ones are wrapped in `components/ProductShot.tsx`, which swaps to
a real `<img>` the moment you pass it a `src` — the Screenshots section
already does.
