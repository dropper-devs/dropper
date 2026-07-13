import Reveal from "@/components/Reveal"
import FeatureCard from "@/components/ui/FeatureCard"

export default function Organize() {
  return (
    <section>
      <div className="container">
        <Reveal>
          <p className="section-kicker">Stays tidy</p>
          <h2 className="section-title">Organized without trying</h2>
        </Reveal>
        <div className="feature-grid">
          <FeatureCard
            title="Archive, don't break"
            icon={
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <rect x="3" y="4" width="18" height="5" rx="1.5" />
                <path d="M5 9v9a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9M10 13h4" strokeLinecap="round" />
              </svg>
            }
          >
            Archiving clears a share out of your list — but the link
            keeps working. Declutter without killing anything you
            already sent.
          </FeatureCard>
          <FeatureCard
            delay={80}
            title="Pin what matters"
            icon={
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M12 3l2.7 5.7 6.3.8-4.6 4.3 1.2 6.2L12 17l-5.6 3 1.2-6.2L3 9.5l6.3-.8z" strokeLinejoin="round" />
              </svg>
            }
          >
            Pin your evergreen links — the press kit, the demo reel —
            and they stay at the top of the dropdown.
          </FeatureCard>
          <FeatureCard
            delay={160}
            title="Folders & breadcrumbs"
            icon={
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
                <path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
              </svg>
            }
          >
            Browse your bucket in folders with breadcrumbs. Shares get
            human-readable names like{" "}
            <code style={{ font: "12px var(--mono)", color: "var(--accent-bright)" }}>
              mixdown-final-v3-x8d2k1
            </code>{" "}
            — readable to you, unguessable to everyone else.
          </FeatureCard>
        </div>
      </div>
    </section>
  )
}
