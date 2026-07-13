/**
 * Demo model: the four draggable files, the seeded row, and the helpers the
 * panel uses to label rows and build share-page links.
 */

import demoManifest from "@/lib/demo-manifest.json"
import { SITE_URL } from "@/lib/site"

export type Kind = "image" | "audio" | "movie" | "markdown"
export type RowID = "seed" | Kind

export type Phase =
  | { t: "idle" }
  | { t: "targeted" }
  | { t: "uploading"; kind: Kind; pct: number }
  | { t: "links"; row: RowID }

export interface DemoFile {
  file: string
  bytes: number
  sizeLabel: string
}

export interface ListState {
  rows: RowID[] // present rows, in add order (seed first)
  archived: RowID[]
  selected: RowID[]
}

export const KINDS: Kind[] = ["image", "audio", "movie", "markdown"]

export const DEMO_FILES: Record<Kind, DemoFile> = Object.fromEntries(
  demoManifest.items.map((it) => [it.kind, { file: it.file, bytes: it.bytes, sizeLabel: it.sizeLabel }]),
) as Record<Kind, DemoFile>

export const SEED = {
  id: "seed" as RowID,
  title: "gateshead-bridge.png",
  meta: `2 hours ago · ${DEMO_FILES.image.sizeLabel}`,
  bytes: DEMO_FILES.image.bytes,
}

export function rowTitle(id: RowID): string {
  return id === "seed" ? SEED.title : DEMO_FILES[id].file
}
export function rowMeta(id: RowID): string {
  return id === "seed" ? SEED.meta : `just now · ${DEMO_FILES[id].sizeLabel}`
}
export function rowBytes(id: RowID): number {
  return id === "seed" ? SEED.bytes : DEMO_FILES[id].bytes
}

/** Links-strip content for a row. The seeded Gateshead Bridge row and the
    image chip intentionally share the same real sample-image page. */
/* Real shares made with the actual app, served from the real bucket. */
const SHARE_BASE = `${SITE_URL}/share/site`
const SAMPLE_IMAGE_SHARE = `${SHARE_BASE}/sample-image-9e3n8a`
const REAL_SHARES: Record<Kind, string> = {
  movie: `${SHARE_BASE}/sample-movie-uhovwy`,
  image: SAMPLE_IMAGE_SHARE,
  audio: `${SHARE_BASE}/sample-wav-e9bman`,
  markdown: `${SHARE_BASE}/sample-markdown-d7ja0j`,
}

export function linksFor(row: RowID): { name: string; page: string; file: string | null } {
  if (row === "seed") {
    const sampleImage = DEMO_FILES.image.file
    return {
      name: SEED.title,
      page: `${SAMPLE_IMAGE_SHARE}/index.html`,
      file: `${SAMPLE_IMAGE_SHARE}/${sampleImage}`,
    }
  }
  const f = DEMO_FILES[row].file
  const real = REAL_SHARES[row]
  return { name: f, page: `${real}/index.html`, file: `${real}/${f}` }
}

export function humanSize(bytes: number): string {
  if (bytes < 1000) return `${bytes} bytes`
  if (bytes < 1e6) return `${Math.round(bytes / 1e3)} KB`
  return `${(bytes / 1e6).toFixed(1).replace(/\.0$/, "")} MB`
}

export async function writeClipboard(text: string): Promise<boolean> {
  try {
    if (navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text)
      return true
    }
  } catch {
    /* fall through to the textarea fallback */
  }
  try {
    const ta = document.createElement("textarea")
    ta.value = text
    ta.setAttribute("readonly", "")
    ta.style.position = "fixed"
    ta.style.opacity = "0"
    document.body.appendChild(ta)
    ta.select()
    const ok = document.execCommand("copy")
    document.body.removeChild(ta)
    return ok
  } catch {
    return false
  }
}
