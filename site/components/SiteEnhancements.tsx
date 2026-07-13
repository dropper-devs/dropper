"use client";

import { usePathname } from "next/navigation";
import { useEffect } from "react";

const REVEAL_SELECTOR = "[data-reveal]";
const SMOOTH_LINK_SELECTOR = "a[data-smooth-link]";

function reveal(element: Element) {
  element.classList.add("is-visible");
}

/**
 * One small client island for site-wide progressive enhancements. Content and
 * links are complete server-rendered HTML; this only adds viewport reveals and
 * clean-URL smooth scrolling when JavaScript is available.
 */
export default function SiteEnhancements() {
  const pathname = usePathname();

  useEffect(() => {
    const elements = document.querySelectorAll<HTMLElement>(
      `${REVEAL_SELECTOR}:not(.is-visible)`,
    );

    if (
      window.matchMedia("(prefers-reduced-motion: reduce)").matches ||
      !("IntersectionObserver" in window)
    ) {
      elements.forEach(reveal);
      return;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          reveal(entry.target);
          observer.unobserve(entry.target);
        }
      },
      { threshold: 0.15, rootMargin: "0px 0px -40px 0px" },
    );

    elements.forEach((element) => observer.observe(element));
    return () => observer.disconnect();
  }, [pathname]);

  useEffect(() => {
    let animationFrame: number | null = null;
    let restoreScrollBehavior: (() => void) | null = null;

    function stopScrollAnimation() {
      if (animationFrame !== null) {
        window.cancelAnimationFrame(animationFrame);
        animationFrame = null;
      }
      restoreScrollBehavior?.();
      restoreScrollBehavior = null;
    }

    function animateScrollTo(top: number) {
      stopScrollAnimation();

      const start = window.scrollY;
      const distance = top - start;
      if (Math.abs(distance) < 2) {
        window.scrollTo(0, top);
        return;
      }

      // Native smooth scrolling can be reduced to an instant jump by browser
      // or macOS motion settings. Drive the short ease ourselves so the site
      // navigation feels the same everywhere.
      const root = document.documentElement;
      const previousScrollBehavior = root.style.scrollBehavior;
      root.style.scrollBehavior = "auto";
      restoreScrollBehavior = () => {
        root.style.scrollBehavior = previousScrollBehavior;
      };

      const duration = Math.min(850, Math.max(420, Math.abs(distance) * 0.18));
      let startedAt: number | null = null;

      function tick(timestamp: number) {
        startedAt ??= timestamp;
        const progress = Math.min((timestamp - startedAt) / duration, 1);
        const eased = 1 - Math.pow(1 - progress, 4);
        window.scrollTo(0, start + distance * eased);

        if (progress < 1) {
          animationFrame = window.requestAnimationFrame(tick);
          return;
        }

        window.scrollTo(0, top);
        animationFrame = null;
        restoreScrollBehavior?.();
        restoreScrollBehavior = null;
      }

      animationFrame = window.requestAnimationFrame(tick);
    }

    function handleClick(event: MouseEvent) {
      if (
        event.defaultPrevented ||
        event.button !== 0 ||
        event.metaKey ||
        event.ctrlKey ||
        event.shiftKey ||
        event.altKey
      ) {
        return;
      }

      const origin = event.target;
      if (!(origin instanceof Element)) return;

      const link = origin.closest<HTMLAnchorElement>(SMOOTH_LINK_SELECTOR);
      if (
        !link ||
        (link.target && link.target !== "_self") ||
        link.hasAttribute("download")
      ) {
        return;
      }

      const destination = new URL(link.href, window.location.href);
      if (
        destination.origin !== window.location.origin ||
        destination.pathname !== window.location.pathname ||
        destination.search !== window.location.search ||
        !destination.hash
      ) {
        return;
      }

      let targetId: string;
      try {
        targetId = decodeURIComponent(destination.hash.slice(1));
      } catch {
        return;
      }

      const target = document.getElementById(targetId);
      if (!target) return;

      event.preventDefault();
      const navOffset = 76;
      const targetTop =
        targetId === "top"
          ? 0
          : window.scrollY + target.getBoundingClientRect().top - navOffset;

      animateScrollTo(Math.max(0, targetTop));

      // preventDefault keeps a clean URL. Also clean up a fragment that may
      // have been present when the page was first opened.
      if (window.location.hash) {
        window.history.replaceState(
          window.history.state,
          "",
          `${window.location.pathname}${window.location.search}`,
        );
      }
    }

    function handleScrollInterruption() {
      stopScrollAnimation();
    }

    document.addEventListener("click", handleClick);
    window.addEventListener("wheel", handleScrollInterruption, { passive: true });
    window.addEventListener("touchstart", handleScrollInterruption, { passive: true });
    window.addEventListener("keydown", handleScrollInterruption);

    return () => {
      document.removeEventListener("click", handleClick);
      window.removeEventListener("wheel", handleScrollInterruption);
      window.removeEventListener("touchstart", handleScrollInterruption);
      window.removeEventListener("keydown", handleScrollInterruption);
      stopScrollAnimation();
    };
  }, []);

  return null;
}
