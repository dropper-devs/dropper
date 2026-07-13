import type { ReactNode } from "react";

/**
 * Server-rendered wrapper for scroll-reveal content. SiteEnhancements owns the
 * one shared IntersectionObserver that reveals every wrapper on the page.
 */
export default function Reveal({
  children,
  delay = 0,
  as: Tag = "div",
}: {
  children: ReactNode;
  delay?: number;
  as?: "div" | "section" | "li" | "figure";
}) {
  return (
    <Tag
      className="reveal"
      data-reveal
      style={delay ? { transitionDelay: `${delay}ms` } : undefined}
    >
      {children}
    </Tag>
  );
}
