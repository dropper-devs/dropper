import DownloadButton from "@/components/ui/DownloadButton";
import { GITHUB_URL, REQUIREMENTS } from "@/lib/site";

export default function GetDropper() {
  return (
    <section id="updates" className="get-dropper">
      <div className="container">
        {/* no Reveal here: animating a pane whose backdrop runs through the
            SVG displacement filter re-renders the refraction every frame —
            the big glass slab arrives static instead */}
        <div className="get-dropper-aurora">
          <div className="get-dropper-box liquid-pane">
            <h2 className="section-title">Get Dropper</h2>
            <p className="get-dropper-lede">
              Free download. No subscription. Source-available on{" "}
              <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer">
                GitHub
              </a>
              .
            </p>
            <div className="get-dropper-actions">
              <DownloadButton />
              <p className="fine-print">{REQUIREMENTS}</p>
            </div>
          </div>
        </div>
      </div>
    </section>
  );
}
