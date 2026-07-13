"use client";

import { useEffect } from "react";
import { analytics, initAnalytics } from "@/lib/analytics";

/** Boots Mixpanel once per page load, then records the page view. */
export default function Analytics() {
  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const response = await fetch("/api/analytics/config");
        const data = (await response.json()) as { mixpanelToken?: string | null };
        if (!cancelled && data.mixpanelToken) {
          const initialized = await initAnalytics(data.mixpanelToken);
          if (!cancelled && initialized) analytics.trackPageView();
        }
      } catch {
        // analytics stays disabled; the site works fine without it
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  return null;
}
