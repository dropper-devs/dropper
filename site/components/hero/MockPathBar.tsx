import { icons } from "@/components/demo/icons";

/** The dropdown's breadcrumb path bar — static by design. */
export function MockPathBar() {
  return (
    <div className="mock-pathbar" aria-hidden="true">
      <span className="mock-ticon">{icons.house}</span>
      <span className="mock-crumb-sep">{icons.chevron}</span>
      <span className="mock-crumb">client-work</span>
      <span className="mock-tspacer" />
      <span className="mock-ticon">{icons.arrowUp}</span>
      <span className="mock-ticon">{icons.folderPlus}</span>
    </div>
  );
}
