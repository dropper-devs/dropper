import Reveal from "@/components/Reveal"
import HeroDemo from "@/components/HeroDemo"
import SmoothLink from "@/components/SmoothLink"
import DownloadButton from "@/components/ui/DownloadButton"
import { REQUIREMENTS } from "@/lib/site"

export default function Hero() {
  return (
    <section className="hero">
      <div className="container hero-grid">
        <div>
          <h1>
            Drop a file.
            <br />
            <span className="accent">Get a link.</span>
            <br />
            <span className="accent">Share it.</span>
          </h1>
          <p className="hero-sub">
            Dropper lives in your Mac&apos;s menu bar. Drag anything onto
            it and it uploads straight to <strong>your own</strong>{" "}
            Cloudflare R2 bucket — a beautiful share page lands on your
            clipboard in seconds. No middleman. No subscription.
          </p>
          <div className="hero-ctas">
            <DownloadButton />
            <SmoothLink className="btn btn-ghost" to="how">
              See how it works
            </SmoothLink>
          </div>
          <p className="fine-print">{REQUIREMENTS}</p>
        </div>
        {/* Renders the mock (right column) plus the floating chip-arc
            layer anchored to .hero-grid. Not wrapped in Reveal: its
            transform would become the containing block for the
            absolutely-positioned arc. */}
        <HeroDemo />
      </div>
    </section>
  )
}
