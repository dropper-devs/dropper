import Reveal from "@/components/Reveal"
import FeatureCard from "@/components/ui/FeatureCard"

export default function HowItWorks() {
  return (
    <section id="how">
      <div className="container">
        <Reveal>
          <p className="section-kicker">How it works</p>
          <h2 className="section-title">From drop to link in seconds</h2>
        </Reveal>
        <div className="feature-grid">
          <FeatureCard
            title="Drop"
            icon={
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M12 3v10m-4-4 4 4 4-4" strokeLinecap="round" strokeLinejoin="round" />
                <path d="M4 16v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3" strokeLinecap="round" />
              </svg>
            }
          >
            Drag files onto the menu bar icon or its dropdown — images,
            audio, video, markdown, PDFs, zips. Literally any file.
          </FeatureCard>
          <FeatureCard
            delay={80}
            title="Upload"
            icon={
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M7 17.5a4.5 4.5 0 1 1 .9-8.9 5.5 5.5 0 0 1 10.6 1.5 3.7 3.7 0 0 1-.9 7.3" strokeLinecap="round" strokeLinejoin="round" />
                <path d="M12 21v-8m-3.5 3.5L12 13l3.5 3.5" strokeLinecap="round" strokeLinejoin="round" />
              </svg>
            }
          >
            Dropper converts anything web-unfriendly on the fly,
            computes audio waveforms and thumbnails, and streams it all
            to your R2 bucket with live progress in the icon.
          </FeatureCard>
          <FeatureCard
            delay={160}
            title="Paste"
            icon={
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M9 4H7a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V6a2 2 0 0 0-2-2h-2" strokeLinejoin="round" />
                <rect x="9" y="2.5" width="6" height="3.5" rx="1" />
                <path d="M9 11.5h6M9 15.5h4" strokeLinecap="round" />
              </svg>
            }
          >
            The share page URL is already on your clipboard. Paste it
            in Slack, iMessage, an email — the page is live, served
            straight from your bucket.
          </FeatureCard>
        </div>
      </div>
    </section>
  )
}
