import SmoothLink from "@/components/SmoothLink"
import DownloadButton from "@/components/ui/DownloadButton"
import DropGlyph from "@/components/ui/DropGlyph"
import GitHubIcon from "@/components/ui/GitHubIcon"
import { GITHUB_URL } from "@/lib/site"

export default function Nav() {
  return (
    <nav className="nav">
    <div className="container nav-inner">
      <SmoothLink className="nav-brand" to="top">
        <DropGlyph />
        Dropper
      </SmoothLink>
      <div className="nav-links">
        <SmoothLink to="how">Share pages</SmoothLink>
        <SmoothLink to="screenshots">Screenshots</SmoothLink>
        <SmoothLink to="collections">Collections</SmoothLink>
        <SmoothLink to="setup">Easy setup</SmoothLink>
      </div>
      <a
        className="nav-github"
        href={GITHUB_URL}
        target="_blank"
        rel="noopener noreferrer"
        aria-label="Dropper on GitHub"
      >
        <GitHubIcon />
      </a>
      <DownloadButton small />
    </div>
  </nav>
  )
}
