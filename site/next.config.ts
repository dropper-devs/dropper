import type { NextConfig } from "next";
import { initOpenNextCloudflareForDev } from "@opennextjs/cloudflare";

// Makes Cloudflare bindings (KV, etc.) available via getCloudflareContext()
// during `next dev`. No-op in production builds.
initOpenNextCloudflareForDev();

const nextConfig: NextConfig = {};

export default nextConfig;
