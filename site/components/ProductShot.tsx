import type { ReactNode } from "react";

/**
 * A product visual slot. Today every shot is a hand-built HTML/CSS mockup
 * (crisp at any DPI); when real screenshots exist, pass `src` and the image
 * replaces the mockup with zero layout changes:
 *
 *   <ProductShot alt="Dropper menu bar dropdown" src="/shots/dropdown.png">
 *     <MenuBarMockup />
 *   </ProductShot>
 */
export default function ProductShot({
  src,
  alt,
  caption,
  children,
}: {
  /** Optional real screenshot; falls back to the mockup children. */
  src?: string;
  alt: string;
  caption?: string;
  children?: ReactNode;
}) {
  return (
    <figure className="product-shot" style={{ margin: 0 }}>
      {src ? (
        // eslint-disable-next-line @next/next/no-img-element
        <img src={src} alt={alt} loading="lazy" />
      ) : (
        <div role="img" aria-label={alt}>
          {children}
        </div>
      )}
      {caption ? (
        <figcaption className="product-shot-caption">{caption}</figcaption>
      ) : null}
    </figure>
  );
}
