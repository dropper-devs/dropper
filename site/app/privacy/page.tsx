import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Privacy",
  description:
    "Dropper's privacy policy: your files go to your own bucket, with limited website analytics and optional email updates.",
};

export default function Privacy() {
  return (
    <main className="container prose">
      <h1>Privacy</h1>
      <p>
        Dropper is built around one idea: <strong>your data is yours</strong>.
        This page covers both the app and this website.
      </p>

      <h2>The app</h2>
      <ul>
        <li>
          Files you drop are uploaded directly from your Mac to{" "}
          <strong>your own Cloudflare R2 bucket</strong>, using credentials you
          provide. There is no intermediary server — we never receive, proxy,
          store, or see your files.
        </li>
        <li>
          Your Cloudflare API token is stored in the macOS Keychain on your
          machine and is used only to talk to Cloudflare&apos;s API and your
          bucket.
        </li>
        <li>
          The app contains no analytics, telemetry, tracking, or crash
          reporting. It makes network requests only to Cloudflare endpoints
          for your own account.
        </li>
        <li>
          Share links include a random suffix so they are not guessable.
          Anyone you give a link to can open it — treat links like the files
          themselves.
        </li>
      </ul>

      <h2>This website</h2>
      <ul>
        <li>
          When configured, we use Mixpanel to understand page views and link
          clicks. It may receive the page URL, referrer, campaign parameters,
          and the destination and text of links you click. Mixpanel uses
          browser local storage to recognize repeat visits.
        </li>
        <li>
          We do not run ads or sell analytics or subscriber data.
        </li>
        <li>
          If you submit your email in the “Get updates” form, we store that
          address (and the time you submitted it) so we can send you release
          announcements. Nothing else is collected, and the address is never
          shared or sold.
        </li>
        <li>
          To be removed from the list, reply to any update email or contact
          us and we&apos;ll delete your address.
        </li>
      </ul>

      <p style={{ marginTop: 40 }}>
        <Link href="/">← Back to Dropper</Link>
      </p>
    </main>
  );
}
