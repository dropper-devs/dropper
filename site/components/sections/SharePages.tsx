import Reveal from "@/components/Reveal";
import ProductShot from "@/components/ProductShot";
import SharePageMockup from "@/components/mockups/SharePageMockup";
import Tick from "@/components/ui/Tick";

export default function SharePages() {
  return (
    <section id="share-pages">
      <div className="container">
        <Reveal>
          <p className="section-kicker">Share pages</p>
          <h2 className="section-title">Pages people actually enjoy opening</h2>
          <p className="section-lede">
            Every drop becomes a dark, focused page served from your own bucket
            — not a download prompt, not someone else&apos;s branding.
          </p>
        </Reveal>
        <div className="split">
          <Reveal>
            <ul className="checklist">
              <li>
                <Tick />
                <span>
                  <strong>Optional image gallery view.</strong> Multiple images
                  become a compact square grid; click any tile for a smoothly
                  animated, full-screen lightbox with a blurred backdrop and
                  previous/next navigation.
                </span>
              </li>
              <li>
                <Tick />
                <span>
                  <strong>SoundCloud-style audio player.</strong> Waveforms are
                  computed at upload time, drawn crisp at any DPI,
                  click-to-seek, one track playing at a time.
                </span>
              </li>
              <li>
                <Tick />
                <span>
                  <strong>A real video player.</strong> Custom scrubber, and the
                  layout is sized from the video&apos;s dimensions before a
                  single frame loads — the page never reflows.
                </span>
              </li>
              <li>
                <Tick />
                <span>
                  <strong>Rendered markdown &amp; text previews.</strong> Notes
                  read like documents, code reads like code.
                </span>
              </li>
              <li>
                <Tick />
                <span>
                  <strong>Native PDF embedding</strong> and clean download cards
                  for everything else.
                </span>
              </li>
            </ul>
          </Reveal>
          <Reveal delay={100}>
            <ProductShot alt="A Dropper share page with a waveform audio player and a custom video player">
              <SharePageMockup />
            </ProductShot>
          </Reveal>
        </div>
      </div>
    </section>
  );
}
