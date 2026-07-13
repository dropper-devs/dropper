import { DOWNLOAD_URL } from "@/lib/site"

export default function DownloadButton({ small = false }: { small?: boolean }) {
  return (
    <a className={`btn btn-primary${small ? " btn-small" : ""}`} href={DOWNLOAD_URL} download>
      <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.4">
        <path d="M12 3v12M6.5 10 12 15.5 17.5 10M4 20h16" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      Download free
    </a>
  )
}
