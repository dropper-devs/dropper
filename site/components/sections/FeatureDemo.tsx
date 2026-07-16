"use client";

import Reveal from "@/components/Reveal";
import { analytics } from "@/lib/analytics";
import { useRef, useState } from "react";

const FEATURE_DEMO_URL =
  "https://dropper.page/share/feature-demos/dropper-4db9c32f1efbb6e229b3a41b67996fac/dropper.mp4";

export default function FeatureDemo() {
  const videoRef = useRef<HTMLVideoElement>(null);
  const trackedPlayRef = useRef(false);
  const [isPlaying, setIsPlaying] = useState(false);
  const [isHovered, setIsHovered] = useState(false);
  const [hasFocus, setHasFocus] = useState(false);
  const [controlsPinned, setControlsPinned] = useState(false);
  const showControls = isHovered || hasFocus || controlsPinned;

  function playVideo() {
    void videoRef.current?.play();
  }

  function handlePlay() {
    setIsPlaying(true);
    if (trackedPlayRef.current) return;
    trackedPlayRef.current = true;
    analytics.track("Feature Demo Played", {
      video_id: "homepage-feature-demo",
    });
  }

  function handleEnded() {
    setIsPlaying(false);
    analytics.track("Feature Demo Completed", {
      video_id: "homepage-feature-demo",
    });
    trackedPlayRef.current = false;
  }

  return (
    <section
      id="feature-demo"
      className="feature-demo"
      aria-label="Dropper feature demo"
    >
      <div className="container">
        <Reveal>
          <div
            className="feature-demo-frame"
            onMouseEnter={() => setIsHovered(true)}
            onMouseLeave={() => setIsHovered(false)}
            onFocusCapture={() => setHasFocus(true)}
            onBlurCapture={(event) => {
              if (
                !(event.relatedTarget instanceof Node) ||
                !event.currentTarget.contains(event.relatedTarget)
              ) {
                setHasFocus(false);
              }
            }}
            onPointerDown={(event) => {
              if (event.pointerType !== "mouse") setControlsPinned(true);
            }}
          >
            <video
              ref={videoRef}
              className="feature-demo-video"
              controls={showControls}
              playsInline
              preload="metadata"
              width={1920}
              height={1080}
              aria-label="Dropper feature demo video"
              onPlay={handlePlay}
              onPause={() => setIsPlaying(false)}
              onEnded={handleEnded}
            >
              <source src={FEATURE_DEMO_URL} type="video/mp4" />
              <a href={FEATURE_DEMO_URL}>Watch the Dropper feature demo</a>
            </video>
            {!isPlaying && (
              <button
                className="feature-demo-play"
                type="button"
                aria-label="Play the Dropper feature demo"
                onClick={playVideo}
                onKeyDown={() => setControlsPinned(true)}
              />
            )}
          </div>
        </Reveal>
      </div>
    </section>
  );
}
