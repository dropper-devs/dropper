import { getCloudflareContext } from "@opennextjs/cloudflare";
import { conditionalStatus, ifRangeMatches, parseRange } from "@/lib/r2-http";

/**
 * Serves the installer DMG from R2 at a stable dropper.page URL, replacing
 * the bucket's rate-limited r2.dev dev domain. The object key is fixed
 * server-side — this route exposes exactly one object, nothing else in the
 * bucket. The root `make release` (scripts/upload.sh) overwrites
 * `installers/Dropper_latest.dmg` on every release, so this URL always
 * serves the newest build.
 */

const INSTALLER_KEY = "installers/Dropper_latest.dmg";

function errorResponse(
  message: string | null,
  status: number,
  headers?: HeadersInit,
): Response {
  const responseHeaders = new Headers(headers);
  responseHeaders.set("Cache-Control", "no-store");
  responseHeaders.set("X-Content-Type-Options", "nosniff");
  return new Response(message, { status, headers: responseHeaders });
}

function installerHeaders(object: R2Object): Headers {
  const headers = new Headers();
  headers.set("Accept-Ranges", "bytes");
  headers.set("ETag", object.httpEtag);
  headers.set("Last-Modified", object.uploaded.toUTCString());
  headers.set("Content-Type", "application/x-apple-diskimage");
  headers.set("Content-Disposition", 'attachment; filename="Dropper.dmg"');
  // The key is overwritten in place on release, so this must never be
  // immutable-cached: a short max-age, then ETag revalidation, keeps
  // caches from pinning a stale installer.
  headers.set("Cache-Control", "public, max-age=300");
  headers.set("X-Content-Type-Options", "nosniff");
  return headers;
}

async function fullResponse(
  request: Request,
  bucket: R2Bucket,
): Promise<Response> {
  const object = await bucket.get(INSTALLER_KEY);
  if (object === null) return errorResponse("Not Found", 404);

  const headers = installerHeaders(object);
  const condition = conditionalStatus(request, object);
  if (condition) return new Response(null, { status: condition, headers });

  headers.set("Content-Length", String(object.size));
  return new Response(object.body, { status: 200, headers });
}

export async function GET(request: Request): Promise<Response> {
  const bucket = getCloudflareContext().env.DOWNLOAD_BUCKET;
  const rangeHeader = request.headers.get("Range");

  try {
    if (!rangeHeader) return await fullResponse(request, bucket);

    const metadata = await bucket.head(INSTALLER_KEY);
    if (metadata === null) return errorResponse("Not Found", 404);

    const condition = conditionalStatus(request, metadata);
    if (condition) {
      return new Response(null, {
        status: condition,
        headers: installerHeaders(metadata),
      });
    }
    if (!ifRangeMatches(request, metadata)) {
      return await fullResponse(request, bucket);
    }

    const range = parseRange(rangeHeader, metadata.size);
    if (range.kind === "ignore") {
      return await fullResponse(request, bucket);
    }
    if (range.kind === "unsatisfiable") {
      return errorResponse("Range Not Satisfiable", 416, {
        "Content-Range": `bytes */${metadata.size}`,
      });
    }

    const object = await bucket.get(INSTALLER_KEY, {
      range: { offset: range.offset, length: range.length },
      onlyIf: { etagMatches: metadata.etag },
    });
    if (object === null) return errorResponse("Not Found", 404);
    if (!("body" in object)) return await fullResponse(request, bucket);

    const headers = installerHeaders(object);
    const end = range.offset + range.length - 1;
    headers.set(
      "Content-Range",
      `bytes ${range.offset}-${end}/${metadata.size}`,
    );
    headers.set("Content-Length", String(range.length));
    return new Response(object.body, { status: 206, headers });
  } catch (error) {
    console.error(
      JSON.stringify({
        message: "R2 installer read failed",
        key: INSTALLER_KEY,
        error: error instanceof Error ? error.message : String(error),
      }),
    );
    return errorResponse("Internal Server Error", 500);
  }
}

export async function HEAD(request: Request): Promise<Response> {
  const bucket = getCloudflareContext().env.DOWNLOAD_BUCKET;
  try {
    const object = await bucket.head(INSTALLER_KEY);
    if (object === null) return errorResponse(null, 404);

    const headers = installerHeaders(object);
    const condition = conditionalStatus(request, object);
    if (condition) return new Response(null, { status: condition, headers });

    headers.set("Content-Length", String(object.size));
    return new Response(null, { status: 200, headers });
  } catch (error) {
    console.error(
      JSON.stringify({
        message: "R2 installer metadata read failed",
        key: INSTALLER_KEY,
        error: error instanceof Error ? error.message : String(error),
      }),
    );
    return errorResponse(null, 500);
  }
}
