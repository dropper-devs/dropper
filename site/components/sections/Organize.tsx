import Reveal from "@/components/Reveal";
import FeatureCard from "@/components/ui/FeatureCard";
import { ArchiveBoxIcon, StarIcon, FolderIcon } from "@/components/ui/icons";

export default function Organize() {
  return (
    <section>
      <div className="container">
        <Reveal>
          <p className="section-kicker">Stays tidy</p>
          <h2 className="section-title">Organized without trying</h2>
        </Reveal>
        <div className="feature-grid">
          <FeatureCard title="Archive, don't break" icon={<ArchiveBoxIcon />}>
            Archiving clears a share out of your list — but the link keeps
            working. Declutter without killing anything you already sent.
          </FeatureCard>
          <FeatureCard delay={80} title="Pin what matters" icon={<StarIcon />}>
            Pin your evergreen links — the press kit, the demo reel — and they
            stay at the top of the dropdown.
          </FeatureCard>
          <FeatureCard
            delay={160}
            title="Folders & breadcrumbs"
            icon={<FolderIcon />}
          >
            Browse your bucket in folders with breadcrumbs. Shares get
            human-readable names like{" "}
            <code className="slug-code">mixdown-final-v3-x8d2k1</code> —
            readable to you, unguessable to everyone else.
          </FeatureCard>
        </div>
      </div>
    </section>
  );
}
