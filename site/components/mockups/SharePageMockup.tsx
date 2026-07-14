/**
 * HTML/CSS recreation of a Dropper share page inside a browser frame,
 * mirroring the real generated page (SharePage.swift): waveform audio player
 * with accent progress, custom video bar, markdown card, download card.
 */

// Deterministic pseudo-waveform (same bars on every render/build).
const PEAKS = Array.from({ length: 64 }, (_, i) => {
  const v =
    52 +
    38 * Math.sin(i * 0.55) * Math.sin(i * 0.13 + 1.2) +
    22 * Math.sin(i * 1.9 + 0.4);
  return Math.round(Math.min(100, Math.max(8, Math.abs(v))));
});

const PLAYED_FRACTION = 0.42;

const PlayIcon = () => (
  <svg viewBox="0 0 16 16">
    <path d="M4 2.5v11l9-5.5z" />
  </svg>
);

export default function SharePageMockup() {
  return (
    <div className="mock-browser">
      <div className="mock-browser-bar">
        <span className="mock-dots">
          <i />
          <i />
          <i />
        </span>
        <span className="mock-urlbar">
          <span className="lock">🔒</span>
          files.yourdomain.com/mixdown-final-v3-x8d2k1/
        </span>
      </div>
      <div className="mock-page">
        <div className="mock-share-file">
          <div className="mock-player card">
            <span className="mock-play">
              <PlayIcon />
            </span>
            <span className="mock-wave" aria-hidden="true">
              {PEAKS.map((p, i) => (
                <i
                  key={i}
                  className={
                    (i + 0.5) / PEAKS.length <= PLAYED_FRACTION ? "played" : ""
                  }
                  style={{ height: `${p}%` }}
                />
              ))}
            </span>
            <span className="mock-time">1:34</span>
          </div>
          <span className="mock-file-label">mixdown-final-v3.wav</span>
        </div>

        <div className="mock-share-file">
          <div className="mock-video">
            <div className="screen">
              <svg viewBox="0 0 24 24" fill="currentColor">
                <path d="M8 5.5v13l11-6.5z" />
              </svg>
            </div>
            <div className="bar">
              <span className="mock-play">
                <PlayIcon />
              </span>
              <span className="mock-seek" />
              <span className="mock-time">0:48</span>
            </div>
          </div>
          <span className="mock-file-label">demo-walkthrough.mp4</span>
        </div>

        <div className="mock-share-file">
          <div className="mock-md card">
            <div className="h"># Release notes — v0.9</div>
            <div className="line" />
            <div className="line short" />
            <div className="line code" />
            <div className="line" />
            <div className="line short" />
          </div>
          <span className="mock-file-label">release-notes.md</span>
        </div>

        <div className="mock-share-file">
          <div className="mock-dl-card card">
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.6"
            >
              <path d="M6 2h9l5 5v15H6z" strokeLinejoin="round" />
              <path d="M15 2v5h5" strokeLinejoin="round" />
              <path d="M10 4v2M10 8v2M10 12v2M10 16v2" />
            </svg>
            <span className="info">
              <span className="name">project-assets.zip</span>
              <span className="size">148.2 MB</span>
            </span>
            <span className="mock-dl-pill">Download</span>
          </div>
        </div>
      </div>
    </div>
  );
}
