import Reveal from "@/components/Reveal";
import FeatureCard from "@/components/ui/FeatureCard";
import { DropIcon, UploadCloudIcon, PasteIcon } from "@/components/ui/icons";

export default function HowItWorks() {
  return (
    <section id="how">
      <div className="container">
        <Reveal>
          <p className="section-kicker">How it works</p>
          <h2 className="section-title">From drop to link in seconds</h2>
        </Reveal>
        <div className="feature-grid">
          <FeatureCard title="Drop" icon={<DropIcon />}>
            Drag files onto the menu bar icon or its dropdown — images, audio,
            video, markdown, PDFs, zips. Literally any file.
          </FeatureCard>
          <FeatureCard delay={80} title="Upload" icon={<UploadCloudIcon />}>
            Dropper converts anything web-unfriendly on the fly, computes audio
            waveforms and thumbnails, and streams it all to your R2 bucket with
            live progress in the icon.
          </FeatureCard>
          <FeatureCard delay={160} title="Paste" icon={<PasteIcon />}>
            The share page URL is already on your clipboard. Paste it in Slack,
            iMessage, an email — the page is live, served straight from your
            bucket.
          </FeatureCard>
        </div>
      </div>
    </section>
  );
}
