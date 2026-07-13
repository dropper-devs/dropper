import DropGlyph from "@/components/ui/DropGlyph"
import Link from "next/link"

export default function Footer() {
  return (
    <footer>
    <div className="container footer-inner">
      <span style={{ display: "inline-flex", alignItems: "center", gap: 8 }}>
        <DropGlyph size={16} /> Dropper
      </span>
      <span>© {new Date().getFullYear()} Temecula DSP</span>
      <span className="spacer" />
      <Link href="/privacy">Privacy</Link>
      <a href="#updates">Get updates</a>
    </div>
  </footer>
  )
}
