import type { ReactNode } from "react";

/**
 * A product visual slot for either a hand-built HTML/CSS mockup or a real
 * screenshot. Pass `src` to replace the fallback children; width and height
 * reserve the screenshot's aspect ratio before its lazy load completes:
 *
 *   <ProductShot alt="Dropper menu bar dropdown" src="/shots/dropdown.png" width={1200} height={900}>
 *     <MenuBarMockup />
 *   </ProductShot>
 */
export default function ProductShot({
  src,
  alt,
  width,
  height,
  children,
}: {
  /** Optional real screenshot; falls back to the mockup children. */
  src?: string;
  alt: string;
  width?: number;
  height?: number;
  children?: ReactNode;
}) {
  return (
    <figure className="product-shot">
      {src ? (
        <img src={src} alt={alt} width={width} height={height} loading="lazy" />
      ) : (
        <div role="img" aria-label={alt}>
          {children}
        </div>
      )}
    </figure>
  );
}
