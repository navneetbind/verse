// background.js — owns all network: LRCLIB fetch + the native-messaging port to
// the menu-bar app. Runs as an MV3 service worker (Chrome + Firefox 121+).

const api = globalThis.browser || globalThis.chrome;

const NATIVE_HOST = "lyra_ytm";
const LRCLIB = "https://lrclib.net";

// Lyric timing offset (seconds). LRCLIB community timestamps often sit a bit
// behind YouTube Music's own timing. Positive = show lyrics EARLIER (menu bar
// moves ahead). Bump up if the bar lags the song; lower if it runs ahead.
const OFFSET_SEC = 0.4;

// ---- state ----
let lines = []; // [{ t, text }] sorted by t (LRCLIB fallback)
let curIdx = -1;
let curWord = -1;
let trackKey = null;
let fetchToken = 0;
let blMode = false; // Better Lyrics is driving (content.js sends "bl")

// ---- native-messaging port to menu-bar app ----
// connectNative launches the Swift app and pipes JSON to it over stdin.
// No port / TLS / CSP / HTTPS-upgrade issues (unlike a WebSocket).
let port = null;
function connectNative() {
  try {
    port = api.runtime.connectNative(NATIVE_HOST);
    port.onDisconnect.addListener(() => {
      port = null; // app quit or SW slept; reconnect lazily on next send
    });
    // app -> browser: playback control commands, relayed to the YT Music tab
    port.onMessage.addListener((msg) => {
      if (msg && msg.cmd) relayToPage(msg);
    });
  } catch (e) {
    port = null;
  }
}

function relayToPage(msg) {
  api.tabs.query({ url: "https://music.youtube.com/*" }, (tabs) => {
    for (const tab of tabs) {
      try {
        const p = api.tabs.sendMessage(tab.id, msg);
        if (p && p.catch) p.catch(() => {}); // no content script in that tab yet — ignore
      } catch (_) {}
    }
  });
}

// Quit the menu-bar app when the last YouTube Music tab is gone: disconnect the
// native port -> app gets EOF -> it terminates. Reopens automatically when a YT
// Music tab loads again (connectNative on the next message).
function quitAppIfNoTabs() {
  // query ALL tabs and match manually (url-filtered query behaves differently
  // across Chrome/Firefox); needs "tabs" permission for tab.url
  api.tabs.query({}, (tabs) => {
    const hasMusic = tabs.some(
      (t) => t.url && t.url.indexOf("https://music.youtube.com") === 0);
    if (!hasMusic && port) {
      try { port.disconnect(); } catch (_) {}
      port = null;
    }
  });
}
api.tabs.onRemoved.addListener(() => setTimeout(quitAppIfNoTabs, 300));
api.tabs.onUpdated.addListener((_id, info) => {
  if (info.url) setTimeout(quitAppIfNoTabs, 300); // navigated away from YT Music
});
function send(obj) {
  if (!port) connectNative();
  if (!port) return;
  try {
    port.postMessage(obj);
  } catch (_) {
    port = null;
  }
}
connectNative();

// ---- lyrics ----
function cleanTitle(s) {
  return s
    .replace(/\((?:official|lyric|lyrics|audio|music|video|mv|hd|4k)[^)]*\)/gi, "")
    .replace(/\[(?:official|lyric|lyrics|audio|music|video|mv|hd|4k)[^\]]*\]/gi, "")
    .replace(/\b(?:official\s+)?(?:music\s+)?video\b/gi, "")
    .replace(/\bofficial\s+audio\b/gi, "")
    .replace(/\blyrics?\b/gi, "")
    .replace(/\bfeat\.?\b.*$/gi, "")
    .replace(/\bft\.?\b.*$/gi, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

function parseLRC(lrc) {
  const out = [];
  const re = /\[(\d+):(\d+)(?:[.:](\d+))?\]/g;
  for (const raw of lrc.split(/\r?\n/)) {
    re.lastIndex = 0;
    const stamps = [];
    let m;
    while ((m = re.exec(raw)) !== null) {
      const min = parseInt(m[1], 10);
      const sec = parseInt(m[2], 10);
      const frac = m[3] ? parseInt(m[3].padEnd(3, "0").slice(0, 3), 10) / 1000 : 0;
      stamps.push(min * 60 + sec + frac);
    }
    if (!stamps.length) continue;
    const text = raw.replace(re, "").trim();
    for (const t of stamps) out.push({ t, text });
  }
  out.sort((a, b) => a.t - b.t);
  return out;
}

async function fetchLyrics(title, artist, duration) {
  const q = (o) =>
    Object.entries(o)
      .filter(([, v]) => v !== undefined && v !== "" && v !== 0)
      .map(([k, v]) => `${k}=${encodeURIComponent(v)}`)
      .join("&");
  try {
    const url =
      `${LRCLIB}/api/get?` +
      q({ artist_name: artist, track_name: cleanTitle(title), duration: Math.round(duration) });
    const r = await fetch(url, { headers: { "User-Agent": "lyra-ytm v0.2" } });
    if (r.ok) {
      const d = await r.json();
      if (d && d.syncedLyrics) return d.syncedLyrics;
    }
  } catch (_) {}
  try {
    const url = `${LRCLIB}/api/search?` + q({ track_name: cleanTitle(title), artist_name: artist });
    const r = await fetch(url, { headers: { "User-Agent": "lyra-ytm v0.2" } });
    if (r.ok) {
      const arr = await r.json();
      const synced = Array.isArray(arr) ? arr.filter((x) => x.syncedLyrics) : [];
      if (synced.length && duration) {
        // prefer the version whose duration is closest to the playing track —
        // avoids grabbing a differently-timed edit/version
        synced.sort(
          (a, b) => Math.abs((a.duration || 0) - duration) - Math.abs((b.duration || 0) - duration));
      }
      if (synced.length) return synced[0].syncedLyrics;
    }
  } catch (_) {}
  return null;
}

async function onTrack(title, artist, duration, art) {
  const key = title + " " + artist + " " + Math.round(duration);
  if (key === trackKey) return;
  trackKey = key;
  const myToken = ++fetchToken;

  lines = [];
  curIdx = -1;
  curWord = -1;
  send({ type: "track", title, artist, art: art || "" }); // dropdown header (always)

  // placeholder shown until real lyrics arrive (both BL and LRCLIB modes)
  const titleArtist = title + (artist ? " — " + artist : "");
  send({ type: "line", text: titleArtist || "♪", active: -1 });

  if (blMode) return; // Better Lyrics provides the lines; skip LRCLIB

  const lrc = await fetchLyrics(title, artist, duration);
  if (myToken !== fetchToken) return; // superseded by a newer track
  if (lrc) {
    lines = parseLRC(lrc);
  } else {
    lines = [];
    send({ type: "line", text: "♪ " + titleArtist, active: -1 });
  }
}

// LRCLIB is line-level only (no real per-word timing) — show the whole line in
// one color (active: -1), never a fake/interpolated word highlight.
function onTime(rawT) {
  if (!lines.length) return;
  const t = rawT + OFFSET_SEC;
  let idx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].t <= t) idx = i;
    else break;
  }
  if (idx === curIdx) return;
  curIdx = idx;
  const text = idx < 0 ? "♪" : lines[idx].text;
  send({ type: "line", text, active: -1 });
}

api.runtime.onMessage.addListener((msg) => {
  if (!msg || !msg.type) return;
  switch (msg.type) {
    case "mode":
      blMode = !!msg.bl;
      break;
    case "bl": // Better Lyrics already computed the line + active word
      send({ type: "line", text: msg.text || "♪", active: msg.active ?? -1 });
      break;
    case "track":
      onTrack(msg.title || "", msg.artist || "", msg.duration || 0, msg.art || "");
      break;
    case "time":
      if (!blMode) onTime(msg.t || 0);
      break;
    case "pos":
      send({ type: "pos", t: msg.t || 0, dur: msg.dur || 0, paused: !!msg.paused });
      break;
    case "pause":
      send({ type: "paused", paused: true });
      break;
    case "play":
      send({ type: "paused", paused: false });
      break;
  }
});
