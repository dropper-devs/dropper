import Reveal from "@/components/Reveal"
import Tick from "@/components/ui/Tick"

export default function Ownership() {
  return (
    <section id="ownership">
      <div className="container split">
        <Reveal>
          <div>
            <p className="section-kicker">Ownership</p>
            <h2 className="section-title">
              Your bucket. Your domain. Your data.
            </h2>
            <ul className="checklist">
              <li>
                <Tick />
                <span>
                  <strong>No middleman storage.</strong> Files go from
                  your Mac directly to your Cloudflare R2 bucket. Dropper
                  never sees, proxies, or holds your data.
                </span>
              </li>
              <li>
                <Tick />
                <span>
                  <strong>No subscription.</strong> The app is free.
                  Cloudflare R2 has a generous free tier and zero egress
                  fees — most people pay nothing at all.
                </span>
              </li>
              <li>
                <Tick />
                <span>
                  <strong>Your links, forever.</strong> Serve share pages
                  from your own domain. If Dropper disappeared tomorrow,
                  every link you ever sent would still work.
                </span>
              </li>
              <li>
                <Tick />
                <span>
                  <strong>Private by default.</strong> Every share URL
                  carries a random suffix — links work only for the people
                  you give them to.
                </span>
              </li>
            </ul>
          </div>
        </Reveal>
        <Reveal delay={100}>
          <div style={{ display: "grid", gap: 18, justifyItems: "start" }}>
            <span className="own-link-pill">
              <span className="domain">files.yourdomain.com</span>
              <span>/</span>
              <span className="slug">mixdown-final-v3-x8d2k1</span>
            </span>
            <p style={{ color: "var(--text-dim)", fontSize: 15, margin: 0 }}>
              Setup takes a few minutes: paste a Cloudflare API token
              once, pick a bucket, and optionally point a domain at it.
              Dropper keeps the token in your Mac&apos;s Keychain.
            </p>
          </div>
        </Reveal>
      </div>
    </section>
  )
}
