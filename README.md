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
| `Makefile`, `build.conf`, `scripts/` | Local build and the release pipeline (build → sign → notarize → dmg → upload → tag) |
| `tools/` | Build-time helpers (app icon generator) |

## Share bundle format

Every share is a self-contained folder in the configured R2 prefix. The
folder name is a readable, sanitized version of the first filename followed by
a random suffix. A single-file share and a collection use the same format.

For example, a two-file collection might look like this:

```text
share/site/launch-demo-4adcb0b260c14b669777ab8c98f6772e/
├── index.html
├── manifest.json
├── launch-demo.mp4
├── notes.md
├── .thumb.launch-demo.mp4.jpg
├── .poster.launch-demo.mp4.jpg
└── .pinned
```

The objects have distinct jobs:

| Object | Purpose |
| --- | --- |
| `index.html` | The generated, static share page and public entry point. |
| `manifest.json` | The authoritative list, order, display metadata, and ownership record for the share. |
| `<filename>` | An uploaded media or document object. Filenames are sanitized and deduplicated within the share. |
| `.thumb.<filename>.jpg` | Optional small preview used by the Dropper menu. |
| `.poster.<filename>.jpg` | Optional larger video poster used by the generated share page. |
| `.pinned` | Zero-byte marker indicating that the active share is pinned. |
| `.archived` | Zero-byte marker indicating that the share is archived. |

### Manifest

`manifest.json` is the source of truth. Its item order is the collection order
in both the app and `index.html`; changing the first item also changes the
derived collection title. `file` is the sanitized R2 object name, while `name`
preserves the original filename for display.

```json
{
  "version": 2,
  "items": [
    {
      "file": "launch-demo.mp4",
      "name": "Launch Demo.mov",
      "kind": "video",
      "size": 18427392,
      "width": 1920,
      "height": 1080,
      "poster": ".poster.launch-demo.mp4.jpg"
    },
    {
      "file": "notes.md",
      "name": "Notes.md",
      "kind": "markdown",
      "size": 1842
    }
  ]
}
```

New manifests currently write `version: 2`. The app does not use that value as
a compatibility gate, does not force an existing manifest to a newer version,
and preserves the stored value when updating a collection. It still validates
the manifest's filenames, unique membership, sizes, and poster paths before
using it.

Only a folder with a readable `manifest.json` is treated as a share. Other
folders remain ordinary folders in the browser.

### Pinning and archiving

Pinning and archiving do not move or rewrite the share. They are represented by
zero-byte marker objects, so the public URL and bundle contents remain stable:

- Pinning creates `.pinned`; unpinning deletes it. A pin only changes ordering
  in Dropper's active list.
- Archiving creates `.archived` and removes `.pinned`. Unarchiving deletes
  `.archived`. Archiving hides the share from the active list, but does not
  disable its public page or media URLs.

### Updating and deleting a collection

Adding, reordering, or removing collection items updates `manifest.json` and
regenerates `index.html` without changing the share URL. Dropper serializes
mutations to the same share; the manifest is written first, the page follows,
and removed media is deleted only after both land, so the live page never
references a removed object.

For a full share deletion, Dropper derives the owned object set only from a
readable manifest and the known companion filenames above. It removes
`index.html` first and `manifest.json` last, leaving any unrecognized objects
in the folder untouched.

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

## Releasing

`make release` runs the full distribution pipeline defined in `scripts/` and
configured by `build.conf`. It requires a Developer ID certificate, a
notarization profile, and Wrangler access to the R2 bucket — see those files
for the specifics. After a successful upload, it creates the annotated Git tag
`v<VERSION>` and pushes that tag only. Releasing the same version again moves
that version's tag to the new commit; changing `VERSION` creates a new tag.
GitHub Releases and GitHub-hosted binaries are not part of this process.
Set `TAG_MESSAGE_FILE=/path/to/notes.txt` to use approved release notes as the
annotated tag message; otherwise the message is simply `Dropper v<VERSION>`.

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
