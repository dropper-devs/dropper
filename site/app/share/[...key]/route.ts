import { getCloudflareContext } from "@opennextjs/cloudflare"

type RouteContext = {
  params: Promise<{ key: string[] }>
}

const SHARE_PREFIX = "share/"
const ACTIVE_CONTENT_TYPES = new Set([
  "application/ecmascript",
  "application/javascript",
  "application/wasm",
  "application/xhtml+xml",
  "application/xml",
  "image/svg+xml",
  "text/ecmascript",
  "text/html",
  "text/javascript",
  "text/xml",
])
const ACTIVE_CONTENT_EXTENSIONS = new Set([
  "cjs",
  "htm",
  "html",
  "js",
  "jsm",
  "mjs",
  "shtml",
  "svg",
  "svgz",
  "wasm",
  "xht",
  "xhtml",
  "xml",
  "xsl",
  "xslt",
])

function errorResponse(message: string | null, status: number, headers?: HeadersInit): Response {
  const responseHeaders = new Headers(headers)
  responseHeaders.set("Cache-Control", "no-store")
  responseHeaders.set("X-Content-Type-Options", "nosniff")
  responseHeaders.set("X-Robots-Tag", "noindex, nofollow, noarchive")
  return new Response(message, { status, headers: responseHeaders })
}

function attachmentName(key: string): string {
  const name = key.split("/").at(-1) || "download"
  const encoded = encodeURIComponent(name).replace(
    /[!'()*]/g,
    (character) => `%${character.charCodeAt(0).toString(16).toUpperCase()}`,
  )
  return `attachment; filename*=UTF-8''${encoded}`
}

function isActiveContent(key: string, contentType: string | undefined): boolean {
  const extension = key.split("/").at(-1)?.split(".").at(-1)?.toLowerCase()
  const mime = contentType?.split(";", 1)[0].trim().toLowerCase()
  return Boolean(
    (extension && ACTIVE_CONTENT_EXTENSIONS.has(extension)) ||
      (mime && (ACTIVE_CONTENT_TYPES.has(mime) || mime.endsWith("+xml"))),
  )
}

function objectHeaders(object: R2Object, key: string): Headers {
  const headers = new Headers()
  object.writeHttpMetadata(headers)
  headers.set("Accept-Ranges", "bytes")
  headers.set("ETag", object.httpEtag)
  headers.set("Last-Modified", object.uploaded.toUTCString())
  headers.set("Referrer-Policy", "no-referrer")
  headers.set("X-Content-Type-Options", "nosniff")
  headers.set("X-Robots-Tag", "noindex, nofollow, noarchive")

  if (key.endsWith("/index.html")) {
    headers.set(
      "Content-Security-Policy",
      "default-src 'none'; base-uri 'none'; form-action 'none'; " +
        "frame-ancestors 'none'; script-src 'unsafe-inline' https://cdn.jsdelivr.net; " +
        "style-src 'unsafe-inline'; img-src 'self' data: https:; " +
        // frame-src 'self': Chrome loads <object type="application/pdf">
        // as a nested browsing context governed by frame-src (NOT just
        // object-src) — without this the PDF viewer silently falls back
        // to the download card. Verified empirically.
        "media-src 'self' blob:; connect-src 'self'; object-src 'self'; " +
        "frame-src 'self'",
    )
  } else {
    const contentType = headers.get("Content-Type") ?? undefined
    if (isActiveContent(key, contentType)) {
      headers.set("Content-Type", "application/octet-stream")
      headers.set("Content-Disposition", attachmentName(key))
    }
  }

  return headers
}

function stripWeakPrefix(etag: string): string {
  return etag.startsWith("W/") ? etag.slice(2) : etag
}

function etagList(value: string): string[] {
  return value.split(",").map((etag) => etag.trim())
}

function conditionalStatus(request: Request, object: R2Object): 304 | 412 | null {
  const ifMatch = request.headers.get("If-Match")
  if (ifMatch) {
    const matches = etagList(ifMatch).some(
      (etag) => etag === "*" || (!etag.startsWith("W/") && etag === object.httpEtag),
    )
    if (!matches) return 412
  } else {
    const unmodifiedSince = request.headers.get("If-Unmodified-Since")
    if (unmodifiedSince) {
      const date = Date.parse(unmodifiedSince)
      if (!Number.isNaN(date) && Math.floor(object.uploaded.getTime() / 1000) > Math.floor(date / 1000)) {
        return 412
      }
    }
  }

  const ifNoneMatch = request.headers.get("If-None-Match")
  if (ifNoneMatch) {
    const objectETag = stripWeakPrefix(object.httpEtag)
    const matches = etagList(ifNoneMatch).some(
      (etag) => etag === "*" || stripWeakPrefix(etag) === objectETag,
    )
    if (matches) return 304
  } else {
    const modifiedSince = request.headers.get("If-Modified-Since")
    if (modifiedSince) {
      const date = Date.parse(modifiedSince)
      if (!Number.isNaN(date) && Math.floor(object.uploaded.getTime() / 1000) <= Math.floor(date / 1000)) {
        return 304
      }
    }
  }

  return null
}

function ifRangeMatches(request: Request, object: R2Object): boolean {
  const value = request.headers.get("If-Range")
  if (!value) return true
  if (value.startsWith('"') || value.startsWith("W/")) {
    return !value.startsWith("W/") && value === object.httpEtag
  }

  const date = Date.parse(value)
  return !Number.isNaN(date) && Math.floor(object.uploaded.getTime() / 1000) <= Math.floor(date / 1000)
}

type ParsedRange =
  | { kind: "ignore" }
  | { kind: "unsatisfiable" }
  | { kind: "range"; offset: number; length: number }

function parseRange(value: string, size: number): ParsedRange {
  if (!value.trim().startsWith("bytes=") || value.includes(",")) return { kind: "ignore" }

  const match = /^bytes=(\d*)-(\d*)$/.exec(value.trim())
  if (!match || (!match[1] && !match[2])) return { kind: "ignore" }
  if (size < 1) return { kind: "unsatisfiable" }

  if (!match[1]) {
    const suffix = Number(match[2])
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return { kind: "unsatisfiable" }
    const length = Math.min(suffix, size)
    return { kind: "range", offset: size - length, length }
  }

  const start = Number(match[1])
  const requestedEnd = match[2] ? Number(match[2]) : size - 1
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(requestedEnd) ||
    start < 0 ||
    requestedEnd < start ||
    start >= size
  ) {
    return { kind: "unsatisfiable" }
  }

  const end = Math.min(requestedEnd, size - 1)
  return { kind: "range", offset: start, length: end - start + 1 }
}

async function objectKey(context: RouteContext): Promise<string | null> {
  const { key } = await context.params
  if (
    !key.length ||
    key.some(
      (part) =>
        !part ||
        part === "." ||
        part === ".." ||
        part.includes("\\") ||
        part.includes("\0"),
    )
  ) {
    return null
  }

  const objectKey = `${SHARE_PREFIX}${key.join("/")}`
  return new TextEncoder().encode(objectKey).byteLength <= 1024 ? objectKey : null
}

async function fullObjectResponse(
  request: Request,
  bucket: R2Bucket,
  key: string,
): Promise<Response> {
  const object = await bucket.get(key)
  if (object === null) return errorResponse("Not Found", 404)

  const headers = objectHeaders(object, key)
  const condition = conditionalStatus(request, object)
  if (condition) return new Response(null, { status: condition, headers })

  headers.set("Content-Length", String(object.size))
  return new Response(object.body, { status: 200, headers })
}

export async function GET(request: Request, context: RouteContext): Promise<Response> {
  const key = await objectKey(context)
  if (!key) return errorResponse("Not Found", 404)

  const bucket = getCloudflareContext().env.SHARE_BUCKET
  const rangeHeader = request.headers.get("Range")

  try {
    if (!rangeHeader) return await fullObjectResponse(request, bucket, key)

    const metadata = await bucket.head(key)
    if (metadata === null) return errorResponse("Not Found", 404)

    const condition = conditionalStatus(request, metadata)
    if (condition) {
      return new Response(null, { status: condition, headers: objectHeaders(metadata, key) })
    }
    if (!ifRangeMatches(request, metadata)) {
      return await fullObjectResponse(request, bucket, key)
    }

    const range = parseRange(rangeHeader, metadata.size)
    if (range.kind === "ignore") {
      return await fullObjectResponse(request, bucket, key)
    }
    if (range.kind === "unsatisfiable") {
      return errorResponse("Range Not Satisfiable", 416, {
        "Content-Range": `bytes */${metadata.size}`,
      })
    }

    const requestedRange = { offset: range.offset, length: range.length }
    const object = await bucket.get(key, {
      range: requestedRange,
      onlyIf: { etagMatches: metadata.etag },
    })
    if (object === null) return errorResponse("Not Found", 404)
    if (!("body" in object)) return await fullObjectResponse(request, bucket, key)

    const headers = objectHeaders(object, key)
    const end = range.offset + range.length - 1
    headers.set("Content-Range", `bytes ${range.offset}-${end}/${metadata.size}`)
    headers.set("Content-Length", String(range.length))
    return new Response(object.body, { status: 206, headers })
  } catch (error) {
    console.error(
      JSON.stringify({
        message: "R2 share read failed",
        key,
        error: error instanceof Error ? error.message : String(error),
      }),
    )
    return errorResponse("Internal Server Error", 500)
  }
}

export async function HEAD(request: Request, context: RouteContext): Promise<Response> {
  const key = await objectKey(context)
  if (!key) return errorResponse(null, 404)

  const bucket = getCloudflareContext().env.SHARE_BUCKET
  try {
    const object = await bucket.head(key)
    if (object === null) return errorResponse(null, 404)

    const headers = objectHeaders(object, key)
    const condition = conditionalStatus(request, object)
    if (condition) return new Response(null, { status: condition, headers })

    headers.set("Content-Length", String(object.size))
    return new Response(null, { status: 200, headers })
  } catch (error) {
    console.error(
      JSON.stringify({
        message: "R2 share metadata read failed",
        key,
        error: error instanceof Error ? error.message : String(error),
      }),
    )
    return errorResponse(null, 500)
  }
}
