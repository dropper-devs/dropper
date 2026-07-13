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
              Your bucket. Your account. Your data.
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
                  <strong>No subscription.</strong> Dropper is free — no
                  plans, no accounts. Storage is your own Cloudflare R2
                  bucket: the free tier covers 10 GB with zero egress
                  fees, and anything beyond it Cloudflare bills to you
                  directly.
                </span>
              </li>
              <li>
                <Tick />
                <span>
                  <strong>Links that outlive the app.</strong> Share pages
                  are plain files in your bucket, served from its public
                  URL — or a custom domain you attach. If Dropper
                  disappeared tomorrow, your links would keep working for
                  as long as your bucket and its public endpoint stay up.
                </span>
              </li>
              <li>
                <Tick />
                <span>
                  <strong>Unlisted by default.</strong> Every share URL
                  ends in an unguessable random suffix, and there is no
                  index to browse. Anyone you hand a link to can open it —
                  no accounts, no passwords.
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
            <div className="setup-assurance">
              <p className="setup-assurance-title">
                Set up once. It&apos;s yours.
              </p>
              <p>
                The guided wizard connects your Cloudflare account, enables
                your bucket&apos;s public r2.dev URL, and keeps your token
                safely in your Mac&apos;s Keychain. Attach your own domain to
                the bucket whenever you like — Dropper switches over with
                one Settings field.
              </p>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  )
}
