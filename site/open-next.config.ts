import { defineCloudflareConfig } from "@opennextjs/cloudflare";

// The site is fully static (SSG) apart from /api/subscribe, so the default
// (no-op) incremental cache is all that's needed. If ISR/revalidation is ever
// added, wire up the R2 incremental cache per the OpenNext docs.
export default defineCloudflareConfig();
