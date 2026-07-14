/**
 * Client-side Mixpanel wrapper, patterned after ScreenCam's analytics.ts.
 *
 * The token is fetched at runtime from /api/analytics/config (it lives as a
 * Cloudflare Worker secret, never in the bundle). Everything no-ops until
 * initAnalytics() succeeds, so local dev without secrets just stays silent.
 *
 * Usage:
 *   import { analytics } from "@/lib/analytics"
 *   analytics.track("CTA Clicked", { cta_name: "Download free" })
 */

import type { Mixpanel } from "mixpanel-browser";

let enabled = false;
let linkTrackingInstalled = false;
let mixpanel: Mixpanel | null = null;
let initializing: Promise<boolean> | null = null;

const UTM_KEYS = [
  "utm_source",
  "utm_medium",
  "utm_campaign",
  "utm_content",
  "utm_term",
] as const;

type Properties = Record<string, unknown>;

function stripUndefined(props: Properties): Properties {
  return Object.fromEntries(
    Object.entries(props).filter(([, v]) => v !== undefined && v !== ""),
  );
}

function currentUtms(): Properties {
  if (typeof window === "undefined") return {};
  const params = new URLSearchParams(window.location.search);
  const utms: Properties = {};
  for (const key of UTM_KEYS) {
    const v = params.get(key);
    if (v) utms[key] = v;
  }
  return utms;
}

function referrerDomain(referrer: string | undefined): string | undefined {
  if (!referrer) return undefined;
  try {
    return new URL(referrer).hostname;
  } catch {
    return undefined;
  }
}

function pageProperties(): Properties {
  if (typeof window === "undefined") return {};
  return stripUndefined({
    url: window.location.href,
    path: window.location.pathname,
    title: document.title,
    referrer: document.referrer || undefined,
    referrer_domain: referrerDomain(document.referrer || undefined),
    ...currentUtms(),
  });
}

/** First-touch attribution: UTMs, referrer and landing URL, pinned once. */
function captureInitialAttribution(client: Mixpanel): void {
  const attribution: Properties = {};
  for (const [k, v] of Object.entries(currentUtms()))
    attribution[`initial_${k}`] = v;
  attribution.initial_landing_url = window.location.href;
  if (document.referrer) attribution.initial_referrer = document.referrer;

  // register_once: repeat visits never overwrite first-touch values.
  client.register_once(attribution);
  client.people.set_once(attribution);
}

/** Every real link click, tracked automatically (skip pure #anchors). */
function installLinkTracking(): void {
  if (linkTrackingInstalled || typeof document === "undefined") return;
  linkTrackingInstalled = true;
  document.addEventListener(
    "click",
    (event) => {
      if (!enabled || !(event.target instanceof Element)) return;
      const anchor = event.target.closest(
        "a[href]",
      ) as HTMLAnchorElement | null;
      if (!anchor) return;
      const href = anchor.getAttribute("href") || "";
      if (!href || href.startsWith("#") || href.startsWith("javascript:"))
        return;
      mixpanel?.track(
        "Link Clicked",
        stripUndefined({
          ...pageProperties(),
          href,
          destination_url: anchor.href,
          link_text: anchor.textContent
            ?.trim()
            .replace(/\s+/g, " ")
            .slice(0, 120),
        }),
      );
    },
    true,
  );
}

export async function initAnalytics(
  token: string | undefined,
): Promise<boolean> {
  if (!token || typeof window === "undefined") return false;
  if (enabled) return true;
  if (initializing) return initializing;

  initializing = (async () => {
    try {
      const { default: client } = await import("mixpanel-browser");
      client.init(token, {
        track_pageview: false,
        persistence: "localStorage",
      });
      mixpanel = client;
      enabled = true;
      captureInitialAttribution(client);
      installLinkTracking();
      return true;
    } catch {
      initializing = null;
      return false;
    }
  })();

  return initializing;
}

export const analytics = {
  track(event: string, properties?: Properties): void {
    if (enabled)
      mixpanel?.track(
        event,
        stripUndefined({ ...pageProperties(), ...properties }),
      );
  },
  trackPageView(): void {
    if (enabled) mixpanel?.track("Page Viewed", pageProperties());
  },
};
