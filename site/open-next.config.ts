import { defineCloudflareConfig } from "@opennextjs/cloudflare";

// Rendered pages are fully static (SSG); the dynamic API and download handlers
// do not use ISR, so the default no-op incremental cache is all that's needed.
// If ISR/revalidation is ever added, wire up the R2 incremental cache per the
// OpenNext docs.
export default defineCloudflareConfig();
