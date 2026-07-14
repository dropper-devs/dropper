import Reveal from "@/components/Reveal";
import ProductShot from "@/components/ProductShot";
import SplitDropMockup from "@/components/mockups/SplitDropMockup";
import Tick from "@/components/ui/Tick";

export default function Collections() {
  return (
    <section id="collections">
      <div className="container split">
        <Reveal>
          <div>
            <p className="section-kicker">Collections</p>
            <h2 className="section-title">Many files, one link</h2>
            <ul className="checklist">
              <li>
                <Tick />
                <span>
                  <strong>One drop, one page.</strong> Drop five files at once
                  and they share a single page — in the order you dropped them.
                </span>
              </li>
              <li>
                <Tick />
                <span>
                  <strong>Add more later.</strong> Drag onto an existing share
                  and choose “Add to collection” — same link, more content.
                </span>
              </li>
              <li>
                <Tick />
                <span>
                  <strong>Drag to reorder.</strong> Rearrange files in the
                  dropdown and the live page updates to match.
                </span>
              </li>
            </ul>
          </div>
        </Reveal>
        <Reveal delay={100}>
          <ProductShot alt="Dragging files over an existing share splits the drop zone: add to collection, or upload as a new item">
            <SplitDropMockup />
          </ProductShot>
        </Reveal>
      </div>
    </section>
  );
}
