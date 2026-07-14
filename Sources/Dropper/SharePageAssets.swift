import Foundation

// The share page's static assets, interpolated into the template by
// `renderShareHTML`. Split out so that function stays about the
// manifest→markup mapping rather than ~300 lines of CSS and JS. Neither
// string contains interpolation — the nonce lives on the enclosing tags.

/// The share page stylesheet (rendered inside the `<style>` element).
let sharePageStyles = """
      html, body { margin: 0; min-height: 100%; }
      body {
        display: flex; flex-direction: column; align-items: center; justify-content: center;
        gap: 28px; background: #14151a; color: #d7d9e0;
        font: 14px/1.4 -apple-system, system-ui, sans-serif;
        padding: 96px clamp(24px, 8vw, 128px) 32px; box-sizing: border-box;
      }
      .share-content {
        display: flex; flex-direction: column; align-items: center;
        gap: 84px; width: 100%;
      }
      figure { margin: 0; display: flex; flex-direction: column; align-items: center; gap: 10px;
               width: 100%; max-width: 1600px; }
      img, video { max-width: 100%; max-height: 86vh; border-radius: 8px; }
      audio { width: min(640px, 100%); }
      figcaption { opacity: 0.7; word-break: break-all; text-align: center; font-size: 13px; }
      figcaption a { color: inherit; }
      .player {
        display: flex; align-items: center; gap: 14px;
        width: min(640px, 100%); box-sizing: border-box;
        background: #1c1e27; border: 1px solid rgba(255,255,255,0.07);
        border-radius: 14px; padding: 14px 18px;
      }
      .player button, .vbar button {
        width: 42px; height: 42px; border-radius: 50%; border: 0; flex: none;
        background: #8b9cf9; color: #14151a; cursor: pointer;
        display: grid; place-items: center; transition: background 0.15s;
      }
      .player button:hover, .vbar button:hover { background: #a5b3fb; }
      .player button:focus-visible, .vbar button:focus-visible {
        outline: 3px solid #c7d0ff; outline-offset: 3px;
      }
      .player button svg, .vbar button svg { width: 16px; height: 16px; fill: currentColor; }
      .icon-pause { display: none; }
      .playing .icon-play { display: none; }
      .playing .icon-pause { display: block; }
      .wave { position: relative; flex: 1; height: 56px; cursor: pointer; }
      .wave canvas { width: 100%; height: 100%; display: block; }
      .wave-seek {
        position: absolute; inset: 0; width: 100%; height: 100%; margin: 0;
        opacity: 0; cursor: pointer;
      }
      .wave:focus-within {
        outline: 3px solid #c7d0ff; outline-offset: 3px; border-radius: 6px;
      }
      .player .time, .vbar .time {
        font-variant-numeric: tabular-nums; font-size: 12px;
        opacity: 0.65; flex: none; min-width: 40px; text-align: right;
      }
      .vplayer { width: min(1400px, 100%); }
      .vplayer video {
        width: 100%; max-height: 80vh; display: block; background: #000;
        border-radius: 14px 14px 0 0; cursor: pointer;
      }
      .vbar {
        display: flex; align-items: center; gap: 14px; box-sizing: border-box;
        background: #1c1e27; border: 1px solid rgba(255,255,255,0.07);
        border-top: 0; border-radius: 0 0 14px 14px; padding: 10px 16px;
      }
      .seek {
        -webkit-appearance: none; appearance: none; flex: 1; height: 4px;
        border-radius: 2px; cursor: pointer;
        background: linear-gradient(to right,
          #8b9cf9 var(--p, 0%), rgba(255,255,255,0.22) var(--p, 0%));
      }
      .seek:focus-visible { outline: 3px solid #c7d0ff; outline-offset: 4px; }
      .seek::-webkit-slider-thumb {
        -webkit-appearance: none; width: 13px; height: 13px;
        border-radius: 50%; background: #c7d0ff; border: 0;
      }
      .seek::-moz-range-thumb {
        width: 13px; height: 13px; border-radius: 50%;
        background: #c7d0ff; border: 0;
      }
      .pdfview { width: 100%; height: calc(100vh - 130px); border: 0; border-radius: 14px; }
      .md, .txt {
        width: min(720px, 100%); box-sizing: border-box;
        background: #1c1e27; border: 1px solid rgba(255,255,255,0.07);
        border-radius: 14px; text-align: left;
      }
      .md { padding: 28px 32px; line-height: 1.6; overflow-wrap: break-word; }
      /* markdown stays invisible until fully rendered, then fades in —
         no half-transformed reflow jank */
      article.md[data-src] { opacity: 0; transition: opacity 0.25s ease; }
      article.md.ready { opacity: 1; }
      .md h1, .md h2, .md h3 { line-height: 1.25; }
      .md a { color: #8b9cf9; }
      .md code {
        background: rgba(255,255,255,0.08); padding: 1px 5px;
        border-radius: 4px; font-size: 13px;
      }
      .md pre { background: #14151a; padding: 14px; border-radius: 8px; overflow-x: auto; }
      .md pre code { background: none; padding: 0; }
      .md blockquote {
        border-left: 3px solid #8b9cf9; margin-left: 0;
        padding-left: 14px; opacity: 0.85;
      }
      .md img { max-width: 100%; }
      .md table { border-collapse: collapse; }
      .md th, .md td { border: 1px solid rgba(255,255,255,0.15); padding: 4px 10px; }
      .txt {
        margin: 0; padding: 18px 22px; max-height: 60vh; overflow: auto;
        font: 12px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace;
        white-space: pre-wrap; word-break: break-word;
      }
      .card {
        display: flex; align-items: center; gap: 14px;
        width: min(560px, 100%); box-sizing: border-box;
        background: #1c1e27; border: 1px solid rgba(255,255,255,0.07);
        border-radius: 14px; padding: 16px 18px;
      }
      .cardicon { width: 34px; height: 34px; color: #8b9cf9; flex: none; }
      .cardinfo { flex: 1; min-width: 0; text-align: left; }
      .cardname { font-size: 14px; word-break: break-all; }
      .cardsize { font-size: 12px; opacity: 0.6; margin-top: 2px; }
      a.dl {
        flex: none; background: #8b9cf9; color: #14151a; text-decoration: none;
        font-size: 13px; font-weight: 600; padding: 8px 16px;
        border-radius: 999px; transition: background 0.15s;
      }
      a.dl:hover { background: #a5b3fb; }
      .dropper-credit {
        margin-top: 8px; color: rgba(215,217,224,0.48);
        font-size: 12px; text-align: center;
      }
      .dropper-credit a {
        color: inherit; font-weight: 600; text-decoration: none;
        transition: color 0.15s;
      }
      .dropper-credit a:hover { color: #a5b3fb; }
      /* mobile-only close button: a small glass circle, top-right */
      .closer {
        display: none;
        position: fixed; top: 14px; right: 14px; z-index: 10;
        width: 40px; height: 40px; border-radius: 50%;
        border: 1px solid rgba(255,255,255,0.16);
        background: rgba(28,30,39,0.82);
        -webkit-backdrop-filter: blur(12px) saturate(1.4);
        backdrop-filter: blur(12px) saturate(1.4);
        color: #d7d9e0; cursor: pointer; padding: 0;
        align-items: center; justify-content: center;
        box-shadow: 0 6px 22px rgba(0,0,0,0.35);
      }
      .closer svg { width: 15px; height: 15px; }
      .closer:active { background: rgba(139,156,249,0.3); }
      @media (max-width: 700px), (pointer: coarse) {
        .closer { display: flex; }
      }
    """

/// The share page player/preview script (audio waveform, video controls,
/// Markdown/text fetch, single-playback coordination, mobile close button).
let sharePagePlayerScript = """
    (() => {
      // One thing plays at a time, across custom players and native elements.
      const natives = [...document.querySelectorAll('audio,video')];
      const customs = [];
      const pauseOthers = (current) => {
        natives.forEach(m => { if (m !== current) m.pause(); });
        customs.forEach(a => { if (a !== current) a.pause(); });
      };
      natives.forEach(m => m.addEventListener('play', () => pauseOthers(m)));

      const fmt = (s) => {
        if (!isFinite(s)) return '0:00';
        return Math.floor(s / 60) + ':' + String(Math.floor(s % 60)).padStart(2, '0');
      };
      const setToggleState = (button, playing) => {
        button.setAttribute('aria-label', playing ? 'Pause' : 'Play');
        button.setAttribute('aria-pressed', playing ? 'true' : 'false');
      };
      const setSeekText = (seek, current, duration) => {
        seek.setAttribute('aria-valuetext', duration
          ? fmt(current) + ' of ' + fmt(duration)
          : fmt(current));
      };

      // Inline previews: plain text as-is, markdown rendered (sanitized).
      document.querySelectorAll('pre.txt[data-src]').forEach(async (el) => {
        try {
          el.textContent = await (await fetch(el.dataset.src)).text();
        } catch {
          el.textContent = '(preview failed to load)';
        }
      });
      document.querySelectorAll('article.md[data-src]').forEach(async (el) => {
        const reveal = () => requestAnimationFrame(() => el.classList.add('ready'));
        let raw = null;
        try { raw = await (await fetch(el.dataset.src)).text(); } catch {}
        if (raw === null) { el.textContent = '(preview failed to load)'; reveal(); return; }
        try {
          el.innerHTML = DOMPurify.sanitize(marked.parse(raw), {
            USE_PROFILES: { html: true },
            FORBID_TAGS: [
              'base', 'button', 'embed', 'form', 'iframe', 'input', 'link',
              'meta', 'object', 'script', 'select', 'style', 'textarea'
            ]
          });
        } catch {
          el.textContent = raw;  // CDN blocked: show the raw markdown
        }
        reveal();
      });

      document.querySelectorAll('.vplayer').forEach(el => {
        const video = el.querySelector('video');
        const button = el.querySelector('button');
        const seek = el.querySelector('.seek');
        const time = el.querySelector('.time');
        const update = () => {
          const frac = video.duration ? video.currentTime / video.duration : 0;
          seek.value = Math.round(frac * 1000);
          seek.style.setProperty('--p', (frac * 100) + '%');
          time.textContent = video.paused && !video.currentTime
            ? fmt(video.duration) : fmt(video.currentTime);
          const playing = !video.paused;
          el.classList.toggle('playing', playing);
          setToggleState(button, playing);
          setSeekText(seek, video.currentTime, video.duration);
        };
        const toggle = () => video.paused ? video.play() : video.pause();
        video.addEventListener('timeupdate', update);
        video.addEventListener('loadedmetadata', update);
        video.addEventListener('play', update);
        video.addEventListener('pause', update);
        video.addEventListener('ended', () => { video.currentTime = 0; update(); });
        button.addEventListener('click', toggle);
        video.addEventListener('click', toggle);
        seek.addEventListener('input', () => {
          if (video.duration) video.currentTime = seek.value / 1000 * video.duration;
        });
        update();
      });

      document.querySelectorAll('.player').forEach(el => {
        const peaks = JSON.parse(el.dataset.peaks);
        const audio = new Audio(el.dataset.src);
        audio.preload = 'metadata';
        customs.push(audio);
        const button = el.querySelector('button');
        const wave = el.querySelector('.wave');
        const canvas = el.querySelector('canvas');
        const seek = el.querySelector('.wave-seek');
        const time = el.querySelector('.time');

        const draw = () => {
          const dpr = window.devicePixelRatio || 1;
          const w = wave.clientWidth, h = wave.clientHeight;
          canvas.width = w * dpr; canvas.height = h * dpr;
          const ctx = canvas.getContext('2d');
          ctx.scale(dpr, dpr);
          const n = peaks.length, bw = w / n;
          const gap = Math.min(bw * 0.35, 1.5);
          const frac = audio.duration ? audio.currentTime / audio.duration : 0;
          for (let i = 0; i < n; i++) {
            const ph = Math.max(2, peaks[i] / 100 * (h - 4));
            ctx.fillStyle = (i + 0.5) / n <= frac ? '#8b9cf9' : 'rgba(255,255,255,0.22)';
            ctx.fillRect(i * bw + gap / 2, (h - ph) / 2, Math.max(bw - gap, 1), ph);
          }
          time.textContent = audio.paused && !audio.currentTime
            ? fmt(audio.duration) : fmt(audio.currentTime);
          seek.value = Math.round(frac * 1000);
          setSeekText(seek, audio.currentTime, audio.duration);
        };

        const updatePlaybackState = () => {
          const playing = !audio.paused;
          el.classList.toggle('playing', playing);
          setToggleState(button, playing);
          draw();
        };
        audio.addEventListener('play', () => { pauseOthers(audio); updatePlaybackState(); });
        audio.addEventListener('pause', updatePlaybackState);
        audio.addEventListener('ended', () => { audio.currentTime = 0; updatePlaybackState(); });
        audio.addEventListener('timeupdate', draw);
        audio.addEventListener('loadedmetadata', draw);
        button.addEventListener('click', () => audio.paused ? audio.play() : audio.pause());
        seek.addEventListener('input', () => {
          if (!audio.duration) return;
          audio.currentTime = seek.value / 1000 * audio.duration;
          draw();
        });
        new ResizeObserver(draw).observe(wave);
        updatePlaybackState();
      });

      // Mobile close button: window.close() works for script/app-opened
      // tabs; fall back to going back when the browser refuses.
      document.querySelector('.closer')?.addEventListener('click', () => {
        window.close();
        setTimeout(() => history.back(), 200);
      });
    })();
    """
