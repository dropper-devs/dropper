import type { Metadata, Viewport } from "next";
import Analytics from "@/components/Analytics";
import SiteEnhancements from "@/components/SiteEnhancements";
import { DESCRIPTION, SITE_NAME, SITE_URL, TAGLINE } from "@/lib/site";
import "./globals.css";

export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: `${SITE_NAME} — ${TAGLINE}`,
    template: `%s — ${SITE_NAME}`,
  },
  description: DESCRIPTION,
  keywords: [
    "file sharing",
    "macOS menu bar",
    "Cloudflare R2",
    "screenshot tool",
    "share links",
    "self-hosted",
  ],
  openGraph: {
    title: `${SITE_NAME} — ${TAGLINE}`,
    description: DESCRIPTION,
    url: SITE_URL,
    siteName: SITE_NAME,
    type: "website",
    images: [{ url: "/og.png", width: 1200, height: 630, alt: SITE_NAME }],
  },
  twitter: {
    card: "summary_large_image",
    title: `${SITE_NAME} — ${TAGLINE}`,
    description: DESCRIPTION,
    images: ["/og.png"],
  },
};

export const viewport: Viewport = {
  themeColor: "#14151a",
};

export default function RootLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <head>
        <noscript>
          <style>{`.reveal { opacity: 1 !important; transform: none !important; transition: none !important; }`}</style>
        </noscript>
      </head>
      <body>
        {children}
        <SiteEnhancements />
        <Analytics />
      </body>
    </html>
  );
}
