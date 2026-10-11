// mediaclock.js — runs in the page's own world (MAIN) at document_start on sites
// that drive the browser's media controls (open.spotify.com). It records what
// the page reports to the Media Session API — position, play state and its own
// play/pause/next/previous/seek handlers — and publishes the position to
// content.js in the same shape as pageclock.js. Everything is passed through to
// the browser unchanged.
(() => {
  const ms = navigator.mediaSession;
  if (!ms) return;

  let pos = null; // last setPositionState: { position, duration, rate, at }
  const handlers = {};
  let media = null; // the element the page last asked to play

  if (typeof ms.setPositionState === "function") {
    const setPositionState = ms.setPositionState.bind(ms);
    ms.setPositionState = (state) => {
      pos = state && typeof state.position === "number"
        ? { position: state.position, duration: state.duration || 0, rate: state.playbackRate || 1, at: Date.now() }
        : null;
      return setPositionState(state);
    };
  }
  const setActionHandler = ms.setActionHandler.bind(ms);
  ms.setActionHandler = (action, handler) => {
    handlers[action] = handler;
    return setActionHandler(action, handler);
  };
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function () {
    // skip looping visuals (Spotify's Canvas clips); keep the actual track
    if (!this.loop && !(isFinite(this.duration) && this.duration < 30)) media = this;
    return play.apply(this, arguments);
  };

  function isPlaying() {
    if (ms.playbackState === "playing") return true;
    if (ms.playbackState === "paused") return false;
    return !!media && !media.paused;
  }

  function publish() {
    const md = ms.metadata;
    if (!md || !md.title) return;
    const playing = isPlaying();
    let t;
    let dur = 0;
    let rate = 1;
    if (pos) {
      rate = pos.rate;
      t = pos.position + (playing ? ((Date.now() - pos.at) / 1000) * rate : 0);
      dur = pos.duration;
    } else if (media) {
      t = media.currentTime;
      dur = media.duration;
    } else {
      return;
    }
    if (dur > 0 && t > dur) t = dur;
    document.dispatchEvent(new CustomEvent("verse-player-time", {
      detail: JSON.stringify({
        t, at: Date.now(), dur: isFinite(dur) ? dur : 0, playing, rate,
        title: md.title || "", artist: md.artist || "",
      }),
    }));
  }
  setInterval(publish, 250);

  const click = (sel) => {
    const el = document.querySelector(sel);
    if (el) el.click();
    return !!el;
  };
  const call = (action, extra) => {
    const h = handlers[action];
    if (typeof h !== "function") return false;
    h(Object.assign({ action }, extra));
    return true;
  };

  document.addEventListener("verse-player-control", (e) => {
    let c;
    try {
      c = JSON.parse(e.detail);
    } catch (_) {
      return;
    }
    if (c.cmd === "next") call("nexttrack") || click('[data-testid="control-button-skip-forward"]');
    else if (c.cmd === "prev") call("previoustrack") || click('[data-testid="control-button-skip-back"]');
    else if (c.cmd === "playpause") {
      (isPlaying() ? call("pause") : call("play")) || click('[data-testid="control-button-playpause"]');
    } else if (c.cmd === "seek" && typeof c.t === "number") call("seekto", { seekTime: c.t });
    publish();
  });
})();
