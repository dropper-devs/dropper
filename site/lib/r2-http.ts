/**
 * HTTP conditional-request and Range mechanics shared by the R2-streaming
 * installer route (`/downloads/Dropper.dmg`). Everything here is pure
 * header parsing against an `R2Object` — response policy (content types,
 * caching, error bodies) stays in each route.
 */

function stripWeakPrefix(etag: string): string {
  return etag.startsWith("W/") ? etag.slice(2) : etag;
}

function etagList(value: string): string[] {
  return value.split(",").map((etag) => etag.trim());
}

export function conditionalStatus(
  request: Request,
  object: R2Object,
): 304 | 412 | null {
  const ifMatch = request.headers.get("If-Match");
  if (ifMatch) {
    const matches = etagList(ifMatch).some(
      (etag) =>
        etag === "*" || (!etag.startsWith("W/") && etag === object.httpEtag),
    );
    if (!matches) return 412;
  } else {
    const unmodifiedSince = request.headers.get("If-Unmodified-Since");
    if (unmodifiedSince) {
      const date = Date.parse(unmodifiedSince);
      if (
        !Number.isNaN(date) &&
        Math.floor(object.uploaded.getTime() / 1000) > Math.floor(date / 1000)
      ) {
        return 412;
      }
    }
  }

  const ifNoneMatch = request.headers.get("If-None-Match");
  if (ifNoneMatch) {
    const objectETag = stripWeakPrefix(object.httpEtag);
    const matches = etagList(ifNoneMatch).some(
      (etag) => etag === "*" || stripWeakPrefix(etag) === objectETag,
    );
    if (matches) return 304;
  } else {
    const modifiedSince = request.headers.get("If-Modified-Since");
    if (modifiedSince) {
      const date = Date.parse(modifiedSince);
      if (
        !Number.isNaN(date) &&
        Math.floor(object.uploaded.getTime() / 1000) <= Math.floor(date / 1000)
      ) {
        return 304;
      }
    }
  }

  return null;
}

export function ifRangeMatches(request: Request, object: R2Object): boolean {
  const value = request.headers.get("If-Range");
  if (!value) return true;
  if (value.startsWith('"') || value.startsWith("W/")) {
    return !value.startsWith("W/") && value === object.httpEtag;
  }

  const date = Date.parse(value);
  return (
    !Number.isNaN(date) &&
    Math.floor(object.uploaded.getTime() / 1000) <= Math.floor(date / 1000)
  );
}

export type ParsedRange =
  | { kind: "ignore" }
  | { kind: "unsatisfiable" }
  | { kind: "range"; offset: number; length: number };

export function parseRange(value: string, size: number): ParsedRange {
  if (!value.trim().startsWith("bytes=") || value.includes(","))
    return { kind: "ignore" };

  const match = /^bytes=(\d*)-(\d*)$/.exec(value.trim());
  if (!match || (!match[1] && !match[2])) return { kind: "ignore" };
  if (size < 1) return { kind: "unsatisfiable" };

  if (!match[1]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0)
      return { kind: "unsatisfiable" };
    const length = Math.min(suffix, size);
    return { kind: "range", offset: size - length, length };
  }

  const start = Number(match[1]);
  const requestedEnd = match[2] ? Number(match[2]) : size - 1;
  if (
    !Number.isSafeInteger(start) ||
    !Number.isSafeInteger(requestedEnd) ||
    start < 0 ||
    requestedEnd < start ||
    start >= size
  ) {
    return { kind: "unsatisfiable" };
  }

  const end = Math.min(requestedEnd, size - 1);
  return { kind: "range", offset: start, length: end - start + 1 };
}
