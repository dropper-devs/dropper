/** Site-wide production URLs used by every download CTA and by metadata. */
export const SITE_URL = "https://dropper.page";

/** Served by the Worker's /downloads route, which streams
    installers/Dropper_latest.dmg from R2 (see app/downloads/Dropper.dmg). */
export const DOWNLOAD_URL = `${SITE_URL}/downloads/Dropper.dmg`;

export const SITE_NAME = "Dropper";
export const TAGLINE = "Drop a file. Get a link.";
export const DESCRIPTION =
  "Dropper lives in your Mac's menu bar. Drag files onto it and they upload " +
  "to your own Cloudflare R2 bucket — a beautiful share page link lands on " +
  "your clipboard in seconds. Free, no middleman, no subscription.";

export const REQUIREMENTS = "Free · macOS 14+ · Apple silicon & Intel";

export const GITHUB_URL = "https://github.com/dropper-devs/dropper";
