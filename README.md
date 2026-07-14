# Dropper

**Drop a file. Get a link.**

Dropper lives in your Mac's menu bar. Drag files onto it and they upload to
your own Cloudflare R2 bucket — a share page link lands on your clipboard in
seconds. Free, no middleman, your bucket, your domain.

There is no server in the middle: the app signs S3 (SigV4) requests locally
and talks directly to R2. Share pages are static HTML the app generates and
uploads alongside your files. Onboarding takes a single Cloudflare API token,
from which the app derives its S3 credentials.

Website & download: [dropper.page](https://dropper.page)

## Repository layout

| Path | What it is |
| --- | --- |
| `Sources/Dropper` | The menu bar app (SwiftPM executable): UI, uploads, share pages, media conversion, onboarding |
| `Sources/CaptureKit` | Screenshot capture and markup, as a separate library target |
| `Tests/` | Unit tests for both targets |
| `site/` | Marketing site on Cloudflare Workers — see [`site/README.md`](site/README.md) |
| `workers/` | Small native Worker serving `/share/*` directly from R2, outside Next/OpenNext |
| `Makefile`, `build.conf`, `scripts/` | Local build and the release pipeline (build → sign → notarize → dmg → upload) |
| `tools/` | Build-time helpers (app icon generator) |

## Building from source

Requires a recent Xcode toolchain on macOS 14 or later.

```sh
make            # build and produce build/Dropper.app (signed ad hoc if no Developer ID)
make run        # build and launch it
make install    # copy it to /Applications (or use ./install.sh, which also relaunches)
swift test      # run the test suite
```

Plain `swift build` works too if you just want the executable without the
app bundle.

### Debug CLI

The binary doubles as a headless debug tool that exercises the same client
code as the UI — run it with `--list`, `--delete <id>`, `--verify-token
<token>`, or `--convert-video <path>` (see `Sources/Dropper/CLI.swift`).

## Releasing

`make release` runs the full distribution pipeline defined in `scripts/` and
configured by `build.conf`. It requires a Developer ID certificate, a
notarization profile, and Wrangler access to the R2 bucket — see those files
for the specifics.

## Website

The site in `site/` is a Next.js app deployed to Cloudflare Workers. Public
`/share/*` requests are handled separately by the small native R2 Worker in
`workers/`, so media never enters Next or OpenNext. The site has its own README
with setup, commands, and deployment notes.

## License

Dropper is **source-available, not open source**: reading, forking, private
modification, and internal use are allowed, while public distribution of
builds and commercial use are reserved. The full terms are in
[LICENSE.md](LICENSE.md).
