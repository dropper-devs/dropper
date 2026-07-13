import SmoothLink from "@/components/SmoothLink"
import DownloadButton from "@/components/ui/DownloadButton"
import DropGlyph from "@/components/ui/DropGlyph"
import Link from "next/link"

export default function Nav() {
  return (
    <nav className="nav">
    <div className="container nav-inner">
      <Link className="nav-brand" href="/">
        <DropGlyph />
        Dropper
      </Link>
      <div className="nav-links">
        <SmoothLink to="share-pages">Share pages</SmoothLink>
        <SmoothLink to="collections">Collections</SmoothLink>
        <SmoothLink to="screenshots">Screenshots</SmoothLink>
        <SmoothLink to="ownership">Your bucket</SmoothLink>
      </div>
      <DownloadButton small />
    </div>
  </nav>
  )
}
