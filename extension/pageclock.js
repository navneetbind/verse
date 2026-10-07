// pageclock.js — runs in the page's own world (MAIN), where YouTube Music's
// player object lives. The <video> element's currentTime is not the song
// position on every YouTube Music layout (it can run on across tracks), so the
// player API is the source of truth. Publishes the position to content.js and
// carries out transport commands through the same API.
(() => {
  const player = () => document.getElementById("movie_player");

  function publish() {
    const p = player();
    if (!p || typeof p.getCurrentTime !== "function") return;
    let d;
    try {
      const vd = typeof p.getVideoData === "function" ? p.getVideoData() : {};
      const st = typeof p.getPlayerStateObject === "function" ? p.getPlayerStateObject() : null;
      d = {
        t: p.getCurrentTime(),
        at: Date.now(),
        dur: typeof p.getDuration === "function" ? p.getDuration() : 0,
        playing: st
          ? !!(st.isPlaying && !st.isBuffering && !st.isSeeking)
          : typeof p.getPlayerState === "function" && p.getPlayerState() === 1,
        rate: typeof p.getPlaybackRate === "function" ? p.getPlaybackRate() : 1,
        title: (vd && vd.title) || "",
        artist: (vd && vd.author) || "",
      };
    } catch (_) {
      return;
    }
    // a string crosses into the extension's isolated world without wrappers
    document.dispatchEvent(new CustomEvent("verse-player-time", { detail: JSON.stringify(d) }));
  }
  setInterval(publish, 250);

  document.addEventListener("verse-player-control", (e) => {
    const p = player();
    if (!p) return;
    let c;
    try {
      c = JSON.parse(e.detail);
    } catch (_) {
      return;
    }
    if (c.cmd === "next" && typeof p.nextVideo === "function") p.nextVideo();
    else if (c.cmd === "prev" && typeof p.previousVideo === "function") p.previousVideo();
    else if (c.cmd === "seek" && typeof p.seekTo === "function") p.seekTo(c.t, true);
    else if (c.cmd === "playpause" && typeof p.getPlayerState === "function") {
      if (p.getPlayerState() === 1) p.pauseVideo();
      else p.playVideo();
    }
    publish();
  });
})();
