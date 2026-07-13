import "server-only";

import { getCloudflareContext } from "@opennextjs/cloudflare";

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

type SubscriptionInput = {
  email: string;
  website: string;
};

export type SubscriptionResult =
  | { ok: true }
  | { ok: false; error: string; status: 400 | 500 | 503 };

/**
 * Validate and store a subscription from any server entry point.
 *
 * A filled honeypot deliberately returns the same success shape as a real
 * signup while storing nothing.
 */
export async function saveSubscription({
  email: rawEmail,
  website,
}: SubscriptionInput): Promise<SubscriptionResult> {
  if (website.trim() !== "") {
    return { ok: true };
  }

  const email = rawEmail.trim().toLowerCase();
  if (!email || email.length > 254 || !EMAIL_RE.test(email)) {
    return {
      ok: false,
      error: "Please enter a valid email address.",
      status: 400,
    };
  }

  let kv: KVNamespace | undefined;
  try {
    const { env } = getCloudflareContext();
    kv = env.SUBSCRIBERS;
  } catch {
    kv = undefined;
  }

  if (!kv) {
    return {
      ok: false,
      error:
        "Subscriptions aren't set up yet — the SUBSCRIBERS KV binding is " +
        "not configured. See the README.",
      status: 503,
    };
  }

  try {
    await kv.put(
      `subscriber:${email}`,
      JSON.stringify({ email, subscribedAt: new Date().toISOString() }),
    );
  } catch {
    return {
      ok: false,
      error: "Could not save your address. Please try again.",
      status: 500,
    };
  }

  return { ok: true };
}
