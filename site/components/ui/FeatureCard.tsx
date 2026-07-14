import type { ReactNode } from "react";
import Reveal from "@/components/Reveal";

/** One card in a .feature-grid: scroll-reveal wrapper around an icon, a
    title, and body copy. Sections pass the 0/80/160ms reveal stagger. */
export default function FeatureCard({
  icon,
  title,
  children,
  delay,
}: {
  icon: ReactNode;
  title: string;
  children: ReactNode;
  delay?: number;
}) {
  return (
    <Reveal delay={delay}>
      <div className="feature-card">
        <span className="icon" aria-hidden="true">
          {icon}
        </span>
        <h3>{title}</h3>
        <p>{children}</p>
      </div>
    </Reveal>
  );
}
