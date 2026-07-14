import Reveal from "@/components/Reveal";

export default function Conversion() {
  return (
    <section>
      <div className="container">
        <Reveal>
          <p className="section-kicker">Web-safe by default</p>
          <h2 className="section-title">Links that play everywhere</h2>
          <p className="section-lede">
            Apple formats are great — until you send them to someone on Chrome.
            Dropper converts as it uploads, so nobody ever writes back “it
            won&apos;t open”.
          </p>
        </Reveal>
        <div className="convert-row">
          <Reveal>
            <div className="convert-chip card">
              <span className="from">HEIC</span>
              <span className="arrow">→</span>
              <span className="to">JPEG</span>
            </div>
          </Reveal>
          <Reveal delay={80}>
            <div className="convert-chip card">
              <span className="from">AIFF</span>
              <span className="arrow">→</span>
              <span className="to">WAV</span>
            </div>
          </Reveal>
          <Reveal delay={160}>
            <div className="convert-chip card">
              <span className="from">MOV / HEVC</span>
              <span className="arrow">→</span>
              <span className="to">MP4</span>
            </div>
          </Reveal>
        </div>
        <Reveal delay={200}>
          <p className="fine-print convert-note">
            Lossless where possible — H.264 movies are remuxed, not re-encoded,
            and AIFF→WAV is a bit-perfect repack. Every conversion can be
            switched off.
          </p>
        </Reveal>
      </div>
    </section>
  );
}
