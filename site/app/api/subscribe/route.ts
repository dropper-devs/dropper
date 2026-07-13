import { NextResponse } from "next/server";
import { saveSubscription } from "@/lib/subscriptions";

/**
 * Email capture. Stores the address in the SUBSCRIBERS KV namespace when the
 * binding is configured (see wrangler.jsonc / README); degrades gracefully
 * with a clear 503 when it isn't (e.g. local dev before KV setup).
 *
 * Basic validation + a "website" honeypot field: bots that fill it get a
 * fake success and nothing is stored.
 */

export async function POST(request: Request) {
  let email = "";
  let honeypot = "";

  try {
    const contentType = request.headers.get("content-type") ?? "";
    if (contentType.includes("application/json")) {
      const body = (await request.json()) as Record<string, unknown>;
      email = typeof body.email === "string" ? body.email : "";
      honeypot = typeof body.website === "string" ? body.website : "";
    } else {
      const form = await request.formData();
      email = String(form.get("email") ?? "");
      honeypot = String(form.get("website") ?? "");
    }
  } catch {
    return NextResponse.json(
      { ok: false, error: "Malformed request body." },
      { status: 400 },
    );
  }

  const result = await saveSubscription({ email, website: honeypot });
  if (!result.ok) {
    return NextResponse.json(
      { ok: false, error: result.error },
      { status: result.status },
    );
  }

  return NextResponse.json({ ok: true });
}

export function GET() {
  return NextResponse.json(
    { ok: false, error: "Use POST." },
    { status: 405, headers: { Allow: "POST" } },
  );
}
