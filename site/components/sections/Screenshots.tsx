import Reveal from "@/components/Reveal"
import ProductShot from "@/components/ProductShot"

export default function Screenshots() {
  return (
    <section id="screenshots">
      <div className="container">
        <Reveal>
          <p className="section-kicker">Screenshots built in</p>
          <h2 className="section-title">
            Capture, mark up, share — without leaving the menu bar
          </h2>
          <p className="section-lede">
            Capture an area, a window, or a whole display. Point with
            arrows, lines, ellipses and boxes, scribble freehand, drop in
            text, crop out what doesn&apos;t matter — seven colors, stroke
            or fill, any size. Then upload straight to a share link, or
            save to your Desktop.
          </p>
        </Reveal>
        <Reveal delay={80}>
          <ProductShot
            src="/screenshot-editor.png"
            alt="The Dropper markup window: annotation tools, color palette, stroke slider, and Upload / Save to Desktop actions"
          />
        </Reveal>
      </div>
    </section>
  )
}
