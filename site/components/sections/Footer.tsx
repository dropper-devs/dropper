import DropGlyph from "@/components/ui/DropGlyph";
import SmoothLink from "@/components/SmoothLink";
import { GITHUB_URL } from "@/lib/site";
import Link from "next/link";

export default function Footer() {
  return (
    <footer>
      <div className="container footer-inner">
        <span className="footer-brand">
          <DropGlyph size={16} /> Dropper
        </span>
        <span>© {new Date().getFullYear()} Temecula DSP</span>
        <span className="spacer" />
        <a href={GITHUB_URL} target="_blank" rel="noopener noreferrer">
          GitHub
        </a>
        <Link href="/privacy">Privacy</Link>
        <SmoothLink to="updates">Download</SmoothLink>
      </div>
    </footer>
  );
}
