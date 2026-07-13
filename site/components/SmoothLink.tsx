import type { ReactNode } from "react";

/**
 * A real fragment link so navigation still works before hydration or without
 * JavaScript. SiteEnhancements progressively adds clean-URL smooth scrolling.
 */
export default function SmoothLink({
  to,
  className,
  children,
}: {
  to: string; // section id, without the #
  className?: string;
  children: ReactNode;
}) {
  return (
    <a href={`#${to}`} className={className} data-smooth-link>
      {children}
    </a>
  );
}
