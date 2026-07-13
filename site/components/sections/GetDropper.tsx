import Reveal from "@/components/Reveal"
import SubscribeForm from "@/components/SubscribeForm"
import DownloadButton from "@/components/ui/DownloadButton"
import { REQUIREMENTS } from "@/lib/site"

export default function GetDropper() {
  return (
    <section id="updates" style={{ paddingTop: 40 }}>
      <div className="container">
        {/* no Reveal here: animating a pane whose backdrop runs through the
            SVG displacement filter re-renders the refraction every frame —
            the big glass slab arrives static instead */}
        <div className="subscribe-aurora">
          <div className="subscribe-box liquid-pane">
            <h2 className="section-title" style={{ marginBottom: 8 }}>
              Get Dropper
            </h2>
            <p style={{ color: "var(--text-dim)", margin: 0 }}>
              Free download. Or leave your email and we&apos;ll tell you
              about new releases — nothing else.
            </p>
            <div style={{ marginTop: 26 }}>
              <DownloadButton />
              <p className="fine-print">{REQUIREMENTS}</p>
            </div>
            <SubscribeForm />
          </div>
        </div>
      </div>
    </section>
  )
}
