import { DOWNLOAD_URL } from "@/lib/site";
import { DownloadIcon } from "@/components/ui/icons";

export default function DownloadButton({ small = false }: { small?: boolean }) {
  return (
    <a
      className={`btn btn-primary${small ? " btn-small" : ""}`}
      href={DOWNLOAD_URL}
      download
    >
      <DownloadIcon />
      Download free
    </a>
  );
}
