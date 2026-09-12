// content.js — runs in the YouTube Music page (isolated world).
// Two sources of truth, in priority order:
//   1. Better Lyrics DOM (accurate per-word timing via data-* attrs) — preferred
//   2. LRCLIB (handled in background.js) — fallback when BL isn't present
// Reads playback position from <video>.currentTime and forwards to background.

const api = globalThis.browser || globalThis.chrome;

const SEL = {
  title: "ytmusic-player-bar .title",
  byline: "ytmusic-player-bar .byline",
};

let lastTrackKey = null;
let lastTick = 0;
let lastPosTick = 0;

// Better Lyrics state
let blModel = null; // [{ t, dur, text, words:[{t,dur,text}] }]
let blActive = false;
let blLastKey = "";
let forcedLRC = false; // user chose LRCLIB source (ignore Better Lyrics)

function textOf(sel) {
  const el = document.querySelector(sel);
  return el ? el.textContent.trim() : "";
}
function parseArtist(byline) {
  return byline ? byline.split("•")[0].trim() : "";
}
function send(msg) {
  try { api.runtime.sendMessage(msg); } catch (_) {}
}

// ---- Better Lyrics DOM → timing model ----
function parseBL() {
  const cont = document.querySelector(".blyrics-container");
  if (!cont) return null;
  const lineEls = [...cont.querySelectorAll(".blyrics--line")];
  if (!lineEls.length) return null;

  const model = lineEls
    .map((le) => {
      const t = parseFloat(le.dataset.time) || 0;
      const dur = parseFloat(le.dataset.duration) || 0;
      const words = [...le.querySelectorAll(".blyrics--word")].map((we) => ({
        t: parseFloat(we.dataset.time) || 0,
        dur: parseFloat(we.dataset.duration) || 0,
        text: (we.dataset.content ?? we.textContent ?? "").trim(),
      }));
      const text = words.length
        ? words.map((w) => w.text).join(" ")
        : le.classList.contains("blyrics--instrumental")
          ? "♪"
          : le.textContent.trim();
      return { t, dur, text, words };
    })
    .filter((l) => l.text);
  model.sort((a, b) => a.t - b.t);
  return model.length ? model : null;
}

// pick current line + word from BL model at time `cur`
function blRender(cur) {
  if (!blModel) return;
  let li = -1;
  for (let i = 0; i < blModel.length; i++) {
    if (blModel[i].t <= cur) li = i;
    else break;
  }
  if (li < 0) {
    emitBL("♪", -1);
    return;
  }
  const line = blModel[li];
  let wi = -1;
  for (let i = 0; i < line.words.length; i++) {
    if (line.words[i].t <= cur) wi = i;
    else break;
  }
  // once the line is sung out (past its duration), clear the highlight so it
  // doesn't leave the last word lit during the gap before the next line
  if (line.dur > 0 && cur > line.t + line.dur) wi = -1;
  emitBL(line.text, wi);
}
function emitBL(text, active) {
  const key = text + "|" + active;
  if (key === blLastKey) return;
  blLastKey = key;
  send({ type: "bl", text, active });
}

// re-parse BL DOM periodically (picks up new songs / lyric loads)
setInterval(() => {
  const m = parseBL();
  blModel = m;
  const on = forcedLRC ? false : !!m;
  if (on !== blActive) {
    blActive = on;
    blLastKey = "";
    send({ type: "mode", bl: on });
  }
}, 1000);

// ---- track detection (for menu + LRCLIB fallback) ----
function albumArt() {
  const img =
    document.querySelector("ytmusic-player-bar img") ||
    document.querySelector(".ytmusic-player-bar img");
  let src = img ? img.src : "";
  // request a crisper thumbnail (googleusercontent size suffix)
  src = src.replace(/=w\d+-h\d+[^&]*$/, "=w120-h120");
  return src;
}
function currentTrack() {
  const title = textOf(SEL.title);
  const artist = parseArtist(textOf(SEL.byline));
  const video = document.querySelector("video");
  const duration = video && isFinite(video.duration) ? video.duration : 0;
  return { title, artist, duration, art: albumArt() };
}
function checkTrack() {
  const t = currentTrack();
  if (!t.title) return;
  const key = t.title + " " + t.artist;
  if (key !== lastTrackKey) {
    lastTrackKey = key;
    checkTrack._sentDuration = !!t.duration;
    send({ type: "track", title: t.title, artist: t.artist, duration: t.duration, art: t.art });
  } else if (t.duration && !checkTrack._sentDuration) {
    checkTrack._sentDuration = true;
    send({ type: "track", title: t.title, artist: t.artist, duration: t.duration, art: t.art });
  }
}
setInterval(checkTrack, 1000);

// ---- playback position ----
function attachVideo() {
  const video = document.querySelector("video");
  if (!video || video._verseAttached) return;
  video._verseAttached = true;

  video.addEventListener("timeupdate", () => {
    const now = performance.now();
    // position stream for the seek bar (~4/sec is plenty)
    if (now - lastPosTick > 250) {
      lastPosTick = now;
      send({
        type: "pos",
        t: video.currentTime,
        dur: isFinite(video.duration) ? video.duration : 0,
        paused: video.paused,
      });
    }
    if (now - lastTick < 50) return;
    lastTick = now;
    if (blActive) blRender(video.currentTime);
    else send({ type: "time", t: video.currentTime, paused: video.paused });
  });
  video.addEventListener("pause", () => send({ type: "pause" }));
  video.addEventListener("play", () => send({ type: "play" }));
}
setInterval(attachVideo, 1000);
attachVideo();
checkTrack();

// ---- playback control (commands from the menu-bar app via background) ----
function clickFirst(selectors) {
  for (const s of selectors) {
    const el = document.querySelector(s);
    if (el) { el.click(); return true; }
  }
  return false;
}
api.runtime.onMessage.addListener((msg) => {
  if (!msg || !msg.cmd) return;
  const video = document.querySelector("video");
  switch (msg.cmd) {
    case "playpause":
      if (video) { video.paused ? video.play() : video.pause(); }
      break;
    case "next":
      clickFirst(["ytmusic-player-bar .next-button", ".next-button"]);
      break;
    case "prev":
      clickFirst(["ytmusic-player-bar .previous-button", ".previous-button"]);
      break;
    case "seek":
      if (video && typeof msg.t === "number") video.currentTime = msg.t;
      break;
    case "source": {
      forcedLRC = msg.value === 1;
      const on = forcedLRC ? false : !!blModel;
      blActive = on;
      blLastKey = "";
      send({ type: "mode", bl: on });
      lastTrackKey = null; // force a track resend so background (re)fetches LRCLIB if needed
      break;
    }
  }
});
