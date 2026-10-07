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
let lastPosTick = 0;

// Better Lyrics state
let blModel = null; // [{ t, dur, text, words:[{t,dur,text}] }]
let blActive = false;
let blLastKey = "";
let forcedLRC = false; // user chose LRCLIB source (ignore Better Lyrics)

// Better Lyrics only loads lyrics while its tab is open. For each new song Verse
// opens that tab, keeps the timing it reads, and puts you back on your tab.
const TAB_HEADER_CLASS = "tab-header style-scope ytmusic-player-page";
const LYRICS_TAB = 1; // Up next, Lyrics, Related — same order in every locale
let curSong = null;
let blCache = null; // { song, model } — survives the lyrics leaving the page
const sigOwner = new Map(); // lyric signature → the song it was read for
let userTabClick = 0;

const reported = new Set();
function report(where, e) {
  const msg = where + ": " + (e && e.message ? e.message : String(e));
  if (reported.has(msg)) return;
  reported.add(msg);
  send({ type: "diag", text: "ERR " + msg + " | " + ((e && e.stack) || "").split("\n").slice(0, 3).join(" < ") });
}

function textOf(sel) {
  const el = document.querySelector(sel);
  return el ? el.textContent.trim() : "";
}
// Another extension can add its own (empty) .title inside the player bar, so take
// the first one that actually has text, then fall back to the media session and
// the tab title — all three carry the same song name.
function songTitle() {
  const el = [...document.querySelectorAll(SEL.title)].find((e) => e.textContent.trim());
  if (el) return el.textContent.trim();
  const md = navigator.mediaSession && navigator.mediaSession.metadata;
  if (md && md.title) return String(md.title).trim();
  const m = document.title.match(/^(.+?)\s+\|\s+YouTube Music$/);
  return m ? m[1].trim() : "";
}
function parseArtist(byline) {
  return byline ? byline.split("•")[0].trim() : "";
}
function send(msg) {
  try { api.runtime.sendMessage(msg); } catch (_) {}
}

// ---- Better Lyrics DOM → timing model ----
let blDumped = false;
let titleDumped = false;
function dumpTitles() {
  if (titleDumped) return;
  titleDumped = true;
  send({ type: "diag", text: "TITLES " + JSON.stringify({
    bars: document.querySelectorAll("ytmusic-player-bar").length,
    matches: [...document.querySelectorAll(SEL.title)].map((e) => e.tagName + "." + e.className + " = '" + e.textContent.trim().slice(0, 40) + "'"),
    mediaSession: navigator.mediaSession && navigator.mediaSession.metadata ? navigator.mediaSession.metadata.title : null,
    docTitle: document.title,
    picked: songTitle(),
  }) });
}
function dumpBL(cont, lineEls) {
  if (blDumped) return;
  const le = lineEls.find((e) => e.querySelector(".blyrics--word"));
  if (!le) return; // only instrumental lines so far — wait for a sung one
  blDumped = true;
  const wes = [...le.querySelectorAll(".blyrics--word")];
  send({
    type: "diag",
    text: JSON.stringify({
      containers: document.querySelectorAll(".blyrics-container").length,
      wrappers: document.querySelectorAll("#blyrics-wrapper").length,
      lines: lineEls.length,
      words: wes.length,
      nested: wes.filter((w) => w.parentElement?.closest(".blyrics--word")).length,
      children: [...le.children].map((c) => c.tagName + "." + c.className).join(" | "),
      sample: wes.map((w) => [w.dataset.time ?? null, w.dataset.duration ?? null, (w.dataset.content ?? w.textContent ?? "")]),
      parents: wes.slice(0, 4).map((w) => w.parentElement?.tagName + "." + (w.parentElement?.className || "")),
      html: le.outerHTML.slice(0, 1600),
    }),
  });
}

// Drop an exact mirrored second half when BL renders the word list twice: both
// copies share text AND timing, which a lyric that genuinely repeats does not.
function dropMirror(ws) {
  const n = ws.length;
  if (n < 2 || n % 2) return ws;
  const h = n / 2;
  for (let i = 0; i < h; i++) {
    const a = ws[i];
    const b = ws[i + h];
    if (a.text !== b.text || a.t !== b.t || a.dur !== b.dur) return ws;
  }
  return ws.slice(0, h);
}

// True when the page puts whitespace between two word spans. Syllables of one
// word sit flush against each other; separate words have a space text node.
function hasGap(a, b) {
  try {
    const r = document.createRange();
    r.setStartAfter(a);
    r.setEndBefore(b);
    return /\s/.test(r.toString());
  } catch (_) {
    return true;
  }
}

function parseBL() {
  const cont = document.querySelector(".blyrics-container");
  if (!cont) return null;
  const lineEls = [...cont.querySelectorAll(".blyrics--line")];
  if (!lineEls.length) return null;
  dumpBL(cont, lineEls);
  dumpTitles();

  const model = lineEls
    .map((le) => {
      const t = parseFloat(le.dataset.time) || 0;
      const dur = parseFloat(le.dataset.duration) || 0;
      // BL can expose the same word list twice; a duplicate repeats both the
      // timestamp and the text, while a word the lyric genuinely repeats is sung
      // later and carries a different one. Words with no timing are left alone.
      const seen = new Set();
      const words = [...le.querySelectorAll(".blyrics--word")]
        .map((we) => ({
          el: we,
          grp: we.closest(".blyrics-word-group"),
          t: parseFloat(we.dataset.time) || 0,
          dur: parseFloat(we.dataset.duration) || 0,
          text: (we.dataset.content ?? we.textContent ?? "").trim(),
        }))
        .filter((w) => {
          if (!w.t) return true;
          const key = w.t + "|" + w.text;
          if (seen.has(key)) return false;
          seen.add(key);
          return true;
        });
      const deduped = dropMirror(words);
      // Group syllable spans into the words the page actually shows, and record
      // which space-separated token each span belongs to — the app finds the
      // sung word by splitting the line on spaces. Spans in different word
      // groups, or with whitespace between them, are separate words; only spans
      // sharing a group with nothing between them are joined. If the page shows
      // no separation at all, fall back to one span per word.
      const gaps = deduped.map((w, i) => {
        if (i === 0) return true;
        const prev = deduped[i - 1];
        return (prev.grp && w.grp && prev.grp !== w.grp) || hasGap(prev.el, w.el);
      });
      const anyGap = gaps.slice(1).some(Boolean);
      const parts = [];
      deduped.forEach((w, i) => {
        if (i === 0 || !anyGap || gaps[i]) parts.push(w.text);
        else parts[parts.length - 1] += w.text;
        w.tok = parts.length - 1;
      });
      const text = parts.length
        ? parts.join(" ")
        : le.classList.contains("blyrics--instrumental")
          ? "♪"
          : le.textContent.trim();
      // BL fakes word timing on line-synced lyrics (zero durations, words a few
      // ms apart); only real richsync earns a word highlight
      const timed = deduped.length > 1 &&
        !le.querySelector(".blyrics-line-synced-word") &&
        deduped.some((w) => w.dur > 0) &&
        new Set(deduped.map((w) => w.t)).size > 1;
      return { t, dur, text, words: deduped.map(({ el, grp, ...w }) => w), timed };
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
    emitBL("♪", -1, false);
    return;
  }
  const line = blModel[li];
  let wi = -1;
  if (line.timed) {
    for (let i = 0; i < line.words.length; i++) {
      if (line.words[i].t <= cur) wi = i;
      else break;
    }
  }
  // once the line is sung out (past its duration), clear the highlight so it
  // doesn't leave the last word lit during the gap before the next line
  if (line.dur > 0 && cur > line.t + line.dur) wi = -1;
  emitBL(line.text, wi < 0 ? -1 : line.words[wi].tok, line.timed);
}
function emitBL(text, active, timed) {
  const key = text + "|" + active;
  if (key === blLastKey) return;
  blLastKey = key;
  send({ type: "bl", text, active, timed });
}

function songNow() {
  return songTitle() || null;
}
const sigOf = (m) => m.map((l) => l.t + ":" + l.text).join("|");

// Read BL into the cache for the song playing right now. The page can still be
// showing the previous song's lyrics, so a parse is only kept if those exact
// lyrics have not already been seen for a different song.
function refreshBL() {
  try {
    refreshBLInner();
  } catch (e) {
    report("refreshBL", e);
  }
}
function refreshBLInner() {
  const song = songNow();
  const m = parseBL();
  if (m && song) {
    const sig = sigOf(m);
    const owner = sigOwner.get(sig);
    if (owner === undefined) {
      sigOwner.set(sig, song);
      if (sigOwner.size > 30) sigOwner.delete(sigOwner.keys().next().value);
    }
    if ((owner ?? song) === song) blCache = { song, model: m };
  }
  blModel = !song ? m : blCache && blCache.song === song ? blCache.model : null;
  const on = forcedLRC ? false : !!blModel;
  if (on !== blActive) {
    blActive = on;
    blLastKey = "";
    if (!on) lastTrackKey = null; // BL dropped out — force a track resend so LRCLIB is tried
    send({ type: "mode", bl: on });
  }
}
setInterval(refreshBL, 1000);

setInterval(() => {
  try {
    const song = songNow();
    const m = parseBL();
    const sig = m ? sigOf(m) : "";
    send({ type: "diag", text: "STATE " + JSON.stringify({
      song, curSong, lines: m ? m.length : null, owner: m ? sigOwner.get(sig) ?? "(none)" : null,
      cacheSong: blCache ? blCache.song : null, blActive, forcedLRC, lastTrackKey,
      clock: clockFresh() ? { t: Math.round(clock.t), playing: clock.playing, artist: clock.artist } : "stale/none",
      videoT: document.querySelector("video") ? Math.round(document.querySelector("video").currentTime) : null,
      tab: [...document.getElementsByClassName(TAB_HEADER_CLASS)].findIndex((t) => t.getAttribute("aria-selected") === "true"),
    }) });
  } catch (e) {
    report("state", e);
  }
}, 5000);

// a tab picked by hand (trusted event) means Verse must not switch you back
document.addEventListener("click", (e) => {
  if (e.isTrusted && e.target.closest && e.target.closest(".tab-header")) {
    userTabClick = Date.now();
    cloak(false);
  }
}, true);

// While Verse borrows the Lyrics tab, keep showing what you were looking at.
// YouTube Music keeps the Up next queue on the page (just marked hidden) while
// Lyrics shows, so the queue is held visible, the lyrics render invisibly behind
// it, and the tab underline stays put. Only possible from Up next — Related and
// Comments reuse the same panel Lyrics does.
const CLOAK_ID = "verse-cloak";
function cloak(on) {
  const old = document.getElementById(CLOAK_ID);
  if (old) old.remove();
  clearTimeout(cloak.failsafe);
  if (!on) return;
  cloak.failsafe = setTimeout(() => cloak(false), 10000); // never leave the page cloaked
  const bar = document.querySelector("tp-yt-paper-tabs #selectionBar");
  const frozen = bar ? getComputedStyle(bar).transform : "none";
  const st = document.createElement("style");
  st.id = CLOAK_ID;
  st.textContent = `
    #tab-renderer { position: relative !important; }
    #tab-renderer > div:first-child { display: block !important; }
    #tab-renderer > :not(div:first-child), #blyrics-wrapper {
      position: absolute !important; inset: 0 !important;
      opacity: 0 !important; pointer-events: none !important;
    }
    tp-yt-paper-tabs #selectionBar { transform: ${frozen} !important; transition: none !important; }
    tp-yt-paper-tabs .tab-header { transition: none !important; }
  `;
  // tab label colours: pin each to what it shows right now
  const tabs = [...document.getElementsByClassName(TAB_HEADER_CLASS)];
  tabs.forEach((t, i) => {
    st.textContent += `tp-yt-paper-tabs .tab-header:nth-of-type(${i + 1}),
      tp-yt-paper-tabs .tab-header:nth-of-type(${i + 1}) * { color: ${getComputedStyle(t).color} !important; }`;
  });
  document.documentElement.appendChild(st);
}

function openLyricsBriefly(song) {
  if (forcedLRC) return;
  const tabs = document.getElementsByClassName(TAB_HEADER_CLASS);
  const lyricsTab = tabs[LYRICS_TAB];
  if (!lyricsTab) return;
  const from = [...tabs].findIndex((t) => t.getAttribute("aria-selected") === "true");
  if (from === LYRICS_TAB) return; // already there; BL loads on its own
  const openedAt = Date.now();
  // the previous song's "no lyrics" notice can still be on the page; only one
  // that appears after this click counts as an answer for this song
  const NO_LYRICS = "#tab-renderer > ytmusic-message-renderer";
  const staleNotice = document.querySelector(NO_LYRICS);
  if (from === 0) cloak(true);
  lyricsTab.click();
  const wait = setInterval(() => {
    refreshBL();
    const loaded = blCache && blCache.song === song;
    const notice = document.querySelector(NO_LYRICS);
    const ytSaysNone = !!notice && notice !== staleNotice;
    if (!loaded && !ytSaysNone && Date.now() - openedAt < 8000 && curSong === song) return;
    clearInterval(wait);
    if (curSong !== song || userTabClick > openedAt || from < 0) {
      cloak(false);
      return;
    }
    const back = document.getElementsByClassName(TAB_HEADER_CLASS)[from];
    if (back && back.getAttribute("aria-selected") !== "true") back.click();
    // lift the cloak only after YouTube Music has re-shown your tab
    setTimeout(() => cloak(false), 150);
  }, 250);
}

// ---- track detection (for menu + LRCLIB fallback) ----
function albumArt() {
  const img =
    document.querySelector("ytmusic-player-bar img") ||
    document.querySelector(".ytmusic-player-bar img");
  let src = img ? img.src : "";
  if (!src) {
    const md = navigator.mediaSession && navigator.mediaSession.metadata;
    const art = md && md.artwork ? [...md.artwork] : [];
    if (art.length) src = art[art.length - 1].src || "";
  }
  // request a crisper thumbnail (googleusercontent size suffix)
  src = src.replace(/=w\d+-h\d+[^&]*$/, "=w120-h120");
  return src;
}
function currentTrack() {
  const title = songTitle();
  const md = navigator.mediaSession && navigator.mediaSession.metadata;
  const artist = parseArtist(textOf(SEL.byline)) ||
    (clockFresh() && clock.artist) || (md && md.artist ? String(md.artist).trim() : "");
  const pb = playback();
  const duration = pb && pb.dur > 0 ? pb.dur : 0;
  return { title, artist, duration, art: albumArt() };
}
function checkTrack() {
  const t = currentTrack();
  if (!t.title) return;
  const key = t.title;
  if (key !== lastTrackKey) {
    lastTrackKey = key;
    // drop the old song's BL model immediately — the 1s re-parse is too slow and
    // timeupdate would otherwise emit stale lines into the new track
    blModel = null;
    blActive = false;
    blLastKey = "";
    checkTrack._sent = { dur: !!t.duration, artist: !!t.artist };
    send({ type: "track", title: t.title, artist: t.artist, duration: t.duration, art: t.art });
    if (key !== curSong) {
      curSong = key;
      try {
        openLyricsBriefly(key);
      } catch (e) {
        report("openLyricsBriefly", e);
      }
    }
  } else if ((t.duration && !checkTrack._sent.dur) || (t.artist && !checkTrack._sent.artist)) {
    // duration or artist showed up after the title — resend so LRCLIB can match properly
    checkTrack._sent = { dur: !!t.duration, artist: !!t.artist };
    send({ type: "track", title: t.title, artist: t.artist, duration: t.duration, art: t.art });
  }
}
setInterval(checkTrack, 1000);

// ---- playback position ----
// The song position comes from pageclock.js (YouTube Music's player API). The
// <video> element is only a fallback: on some layouts its currentTime keeps
// running across tracks instead of restarting with each song.
let clock = null; // { t, at, dur, playing, rate, title, artist }
document.addEventListener("verse-player-time", (e) => {
  try {
    clock = JSON.parse(e.detail);
  } catch (_) {}
});
function clockFresh() {
  return !!clock && Date.now() - clock.at < 3000;
}
function playback() {
  if (clockFresh()) {
    const ahead = clock.playing ? ((Date.now() - clock.at) / 1000) * (clock.rate || 1) : 0;
    return { t: clock.t + ahead, dur: clock.dur || 0, paused: !clock.playing };
  }
  // give the player clock a moment to start before trusting <video> at all
  if (!clock && performance.now() < 2000) return null;
  const video = document.querySelector("video");
  if (!video) return null;
  return { t: video.currentTime, dur: isFinite(video.duration) ? video.duration : 0, paused: video.paused };
}

let lastPaused = null;
setInterval(() => {
  const pb = playback();
  if (!pb) return;
  const now = performance.now();
  // position stream for the seek bar (~4/sec is plenty)
  if (now - lastPosTick > 250) {
    lastPosTick = now;
    send({ type: "pos", t: pb.t, dur: pb.dur, paused: pb.paused });
  }
  if (pb.paused !== lastPaused) {
    if (lastPaused !== null) send({ type: pb.paused ? "pause" : "play" });
    lastPaused = pb.paused;
  }
  if (blActive) blRender(pb.t);
  else send({ type: "time", t: pb.t, paused: pb.paused });
}, 100);
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
  if (["playpause", "next", "prev", "seek"].includes(msg.cmd) && clockFresh()) {
    document.dispatchEvent(new CustomEvent("verse-player-control", {
      detail: JSON.stringify({ cmd: msg.cmd, t: msg.t }),
    }));
    return;
  }
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
