import { NextResponse } from "next/server";
import { getCloudflareContext } from "@opennextjs/cloudflare";

/**
 * Hands the browser the Mixpanel project token (public by design — it can
 * only ingest events). The API secret stays server-side and is never
 * returned here.
 */
export async function GET() {
  const { env } = getCloudflareContext();
  const token = (env as { MIXPANEL_TOKEN?: string }).MIXPANEL_TOKEN;
  return NextResponse.json(
    { mixpanelToken: token ?? null },
    { headers: { "cache-control": "public, max-age=300" } },
  );
}
