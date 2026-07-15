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
      .gallery-content { max-width: 1280px; }
      .image-gallery {
        display: grid; grid-template-columns: repeat(auto-fit, minmax(128px, 150px));
        justify-content: center; gap: clamp(8px, 1.2vw, 16px); width: 100%;
      }
      .gallery-item {
        display: block; position: relative; aspect-ratio: 1; overflow: hidden;
        box-sizing: border-box; border-radius: 12px;
        border: 1px solid rgba(255,255,255,0.08); background: #1c1e27;
        box-shadow: 0 14px 34px rgba(0,0,0,0.22); cursor: pointer;
      }
      .gallery-item img {
        display: block; width: 100%; height: 100%; max-width: none; max-height: none;
        border-radius: 0; object-fit: cover; pointer-events: none; cursor: pointer;
        transition: transform 0.32s cubic-bezier(0.2, 0.7, 0.2, 1);
      }
      .gallery-item:hover img { transform: scale(1.035); }
      .gallery-item:focus-visible {
        outline: 3px solid #c7d0ff; outline-offset: 4px;
      }
      .lightbox {
        position: fixed; inset: 0; width: 100vw; height: 100vh; height: 100dvh;
        max-width: none; max-height: none; margin: 0; border: 0;
        padding: clamp(68px, 8vh, 96px) clamp(70px, 8vw, 120px)
                 clamp(24px, 4vh, 48px); box-sizing: border-box;
        overflow: hidden; background: rgba(9,10,14,0.72); color: #d7d9e0;
      }
      .lightbox[open] {
        display: flex; align-items: center; justify-content: center;
        animation: lightbox-fade-in 0.24s ease-out both;
      }
      .lightbox[open] .lightbox-stage {
        animation: lightbox-stage-in 0.32s cubic-bezier(0.2, 0.75, 0.2, 1) both;
      }
      .lightbox::backdrop {
        background: rgba(9,10,14,0.38);
        -webkit-backdrop-filter: blur(18px); backdrop-filter: blur(18px);
      }
      .lightbox[open]::backdrop {
        animation: lightbox-backdrop-in 0.24s ease-out both;
      }
      .lightbox.closing { animation: lightbox-fade-out 0.18s ease-in both; }
      .lightbox.closing .lightbox-stage {
        animation: lightbox-stage-out 0.18s ease-in both;
      }
      .lightbox.closing::backdrop {
        animation: lightbox-backdrop-out 0.18s ease-in both;
      }
      @keyframes lightbox-fade-in { from { opacity: 0; } to { opacity: 1; } }
      @keyframes lightbox-fade-out { from { opacity: 1; } to { opacity: 0; } }
      @keyframes lightbox-stage-in {
        from { opacity: 0; transform: translateY(10px) scale(0.975); }
        to { opacity: 1; transform: translateY(0) scale(1); }
      }
      @keyframes lightbox-stage-out {
        from { opacity: 1; transform: translateY(0) scale(1); }
        to { opacity: 0; transform: translateY(6px) scale(0.985); }
      }
      @keyframes lightbox-backdrop-in { from { opacity: 0; } to { opacity: 1; } }
      @keyframes lightbox-backdrop-out { from { opacity: 1; } to { opacity: 0; } }
      .lightbox-stage {
        display: grid; grid-template-rows: minmax(0, 1fr) auto;
        gap: 14px; width: min(1600px, 100%); height: 100%; max-width: 1600px;
      }
      .lightbox-image {
        place-self: center; min-width: 0; min-height: 0;
        width: auto; height: auto; max-width: 100%; max-height: 100%;
        object-fit: contain; border-radius: 10px;
        box-shadow: 0 24px 70px rgba(0,0,0,0.48);
      }
      .lightbox-caption {
        display: flex; align-items: center; justify-content: center; gap: 12px;
        width: 100%; min-width: 0; opacity: 1; word-break: normal; color: #d7d9e0;
      }
      .lightbox-name {
        min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
      }
      .lightbox-count { flex: none; color: rgba(215,217,224,0.52); }
      .lightbox-download {
        flex: none; color: #c7d0ff; font-weight: 600; text-decoration: none;
      }
      .lightbox-download:hover { color: #fff; }
      .lightbox-close, .lightbox-nav {
        position: fixed; z-index: 2; display: grid; place-items: center;
        width: 46px; height: 46px; padding: 0; border-radius: 50%;
        border: 1px solid rgba(255,255,255,0.15);
        background: rgba(28,30,39,0.74); color: #f2f3f7; cursor: pointer;
        -webkit-backdrop-filter: blur(12px); backdrop-filter: blur(12px);
        transition: background 0.15s, transform 0.15s;
      }
      .lightbox-close { top: 18px; right: 18px; }
      .lightbox-nav { top: 50%; transform: translateY(-50%); }
      .lightbox-prev { left: 18px; }
      .lightbox-next { right: 18px; }
      .lightbox-close:hover, .lightbox-nav:hover { background: rgba(139,156,249,0.34); }
      .lightbox-nav:hover { transform: translateY(-50%) scale(1.04); }
      .lightbox-close:focus-visible, .lightbox-nav:focus-visible,
      .lightbox-download:focus-visible {
        outline: 3px solid #c7d0ff; outline-offset: 3px;
      }
      .lightbox-close svg, .lightbox-nav svg {
        width: 20px; height: 20px; fill: none; stroke: currentColor;
        stroke-width: 1.8; stroke-linecap: round; stroke-linejoin: round;
      }
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
        .lightbox { padding: 64px 14px 20px; }
        .lightbox-close, .lightbox-nav { width: 42px; height: 42px; }
        .lightbox-close { top: 12px; right: 12px; }
        .lightbox-prev { left: 8px; }
        .lightbox-next { right: 8px; }
        .lightbox-caption { gap: 8px; padding: 0 38px; box-sizing: border-box; }
      }
      @media (prefers-reduced-motion: reduce) {
        .gallery-item img, .lightbox-close, .lightbox-nav { transition: none; }
        .gallery-item:hover img { transform: none; }
        .lightbox[open], .lightbox[open]::backdrop,
        .lightbox[open] .lightbox-stage { animation: none; }
      }
    """

/// The share page interaction script (gallery lightbox, media controls,
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

      const galleryItems = [...document.querySelectorAll('.gallery-item')];
      const lightbox = document.querySelector('.lightbox');
      if (lightbox && galleryItems.length) {
        const preview = lightbox.querySelector('.lightbox-image');
        const name = lightbox.querySelector('.lightbox-name');
        const count = lightbox.querySelector('.lightbox-count');
        const download = lightbox.querySelector('.lightbox-download');
        const stage = lightbox.querySelector('.lightbox-stage');
        const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
        let current = 0;
        let closeTimer = null;

        const finishClose = () => {
          if (closeTimer !== null) {
            clearTimeout(closeTimer);
            closeTimer = null;
          }
          lightbox.classList.remove('closing');
          if (lightbox.open) lightbox.close();
        };
        const closeLightbox = () => {
          if (!lightbox.open || lightbox.classList.contains('closing')) return;
          if (reducedMotion.matches) { finishClose(); return; }
          lightbox.classList.add('closing');
          closeTimer = setTimeout(finishClose, 220);
        };

        const showImage = (index) => {
          current = (index + galleryItems.length) % galleryItems.length;
          const item = galleryItems[current];
          const source = item.getAttribute('href');
          const imageName = item.dataset.name || '';
          preview.src = source;
          preview.alt = imageName;
          name.textContent = imageName;
          count.textContent = (current + 1) + ' / ' + galleryItems.length;
          download.href = source;
          download.download = imageName;
          download.setAttribute('aria-label', 'Download ' + imageName);
        };

        galleryItems.forEach((item, index) => {
          item.addEventListener('click', (event) => {
            if (typeof lightbox.showModal !== 'function') return;
            event.preventDefault();
            showImage(index);
            lightbox.showModal();
          });
        });
        lightbox.querySelector('.lightbox-close').addEventListener('click', () => {
          closeLightbox();
        });
        lightbox.querySelector('.lightbox-prev').addEventListener('click', () => {
          showImage(current - 1);
        });
        lightbox.querySelector('.lightbox-next').addEventListener('click', () => {
          showImage(current + 1);
        });
        lightbox.addEventListener('click', (event) => {
          if (event.target === lightbox || event.target === stage) closeLightbox();
        });
        lightbox.addEventListener('cancel', (event) => {
          event.preventDefault();
          closeLightbox();
        });
        lightbox.addEventListener('keydown', (event) => {
          if (event.key === 'ArrowLeft') {
            event.preventDefault();
            showImage(current - 1);
          } else if (event.key === 'ArrowRight') {
            event.preventDefault();
            showImage(current + 1);
          }
        });
        lightbox.addEventListener('animationend', (event) => {
          if (event.target === lightbox && event.animationName === 'lightbox-fade-out') {
            finishClose();
          }
        });
        lightbox.addEventListener('close', () => {
          if (closeTimer !== null) clearTimeout(closeTimer);
          closeTimer = null;
          lightbox.classList.remove('closing');
          preview.removeAttribute('src');
          preview.alt = '';
        });
      }

      // Mobile close button: window.close() works for script/app-opened
      // tabs; fall back to going back when the browser refuses.
      document.querySelector('.closer')?.addEventListener('click', () => {
        window.close();
        setTimeout(() => history.back(), 200);
      });
    })();
    """
