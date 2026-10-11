// background.js — owns all network: LRCLIB fetch + the native-messaging port to
// the menu-bar app. Runs as an MV3 service worker (Chrome + Firefox 121+).

const api = globalThis.browser || globalThis.chrome;

const NATIVE_HOST = "verse";
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
let estimateWords = true; // app setting: guess per-word timing inside LRCLIB lines
let songDur = 0;

// ---- native-messaging port to menu-bar app ----
// connectNative launches the Swift app and pipes JSON to it over stdin.
// No port / TLS / CSP / HTTPS-upgrade issues (unlike a WebSocket).
// sites Verse reads lyrics for
const MUSIC_SITES = ["https://music.youtube.com", "https://open.spotify.com"];
const isMusicUrl = (u) => !!u && MUSIC_SITES.some((site) => u.indexOf(site) === 0);

let port = null;
function connectNative() {
  try {
    port = api.runtime.connectNative(NATIVE_HOST);
    port.onDisconnect.addListener(() => {
      port = null; // app quit or SW slept; reconnect lazily on next send
    });
    // app -> browser: playback control commands, relayed to the YT Music tab
    port.onMessage.addListener((msg) => {
      if (msg && msg.cmd === "estimate") {
        estimateWords = !!msg.value;
        curIdx = -1;
        curWord = -1;
      }
      if (msg && msg.cmd) relayToPage(msg);
    });
  } catch (e) {
    port = null;
  }
}

function relayToPage(msg) {
  api.tabs.query({}, (tabs) => {
    for (const tab of tabs.filter((t) => isMusicUrl(t.url))) {
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
    const hasMusic = tabs.some((t) => isMusicUrl(t.url));
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
// No connect at startup: the app launches only when a YouTube Music page first
// sends something (send() connects on demand), not on every browser start.

// ---- lyrics ----
// Spotify titles carry suffixes LRCLIB doesn't ("- Remastered 2011",
// "(From \"Sultan\")"); those extra rules run for Spotify only, so YouTube
// Music lookups stay exactly as they were.
function cleanTitle(s, spotify) {
  if (spotify) {
    s = s
      .replace(/\s+-\s+.*\b(?:remaster(?:ed)?|live|version|edit|mono|stereo|mix|from)\b.*$/gi, "")
      .replace(/\((?:from|with)\b[^)]*\)/gi, "");
  }
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

async function fetchLyrics(title, artist, duration, spotify) {
  const q = (o) =>
    Object.entries(o)
      .filter(([, v]) => v !== undefined && v !== "" && v !== 0)
      .map(([k, v]) => `${k}=${encodeURIComponent(v)}`)
      .join("&");
  try {
    const url =
      `${LRCLIB}/api/get?` +
      q({ artist_name: artist, track_name: cleanTitle(title, spotify), duration: Math.round(duration) });
    const r = await fetch(url, { headers: { "User-Agent": "verse v0.2" } });
    if (r.ok) {
      const d = await r.json();
      if (d && d.syncedLyrics) return d.syncedLyrics;
    }
  } catch (_) {}
  try {
    const url = `${LRCLIB}/api/search?` + q({ track_name: cleanTitle(title, spotify), artist_name: artist });
    const r = await fetch(url, { headers: { "User-Agent": "verse v0.2" } });
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

async function onTrack(title, artist, duration, art, spotify) {
  // the card header always goes through: a freshly (re)started app asks for the
  // track again mid-song and has nothing to show until it arrives
  send({ type: "track", title, artist, art: art || "" });
  const key = title + " " + artist + " " + Math.round(duration);
  if (key === trackKey) return;
  trackKey = key;
  const myToken = ++fetchToken;

  lines = [];
  curIdx = -1;
  curWord = -1;
  songDur = duration || 0;

  // placeholder shown until real lyrics arrive (both BL and LRCLIB modes)
  const titleArtist = title + (artist ? " — " + artist : "");
  send({ type: "line", text: titleArtist || "♪", active: -1, src: "placeholder" });

  if (blMode) return; // Better Lyrics provides the lines; skip LRCLIB

  const lrc = await fetchLyrics(title, artist, duration, spotify);
  if (myToken !== fetchToken) return; // superseded by a newer track
  if (lrc) {
    lines = parseLRC(lrc);
  } else {
    lines = [];
    send({ type: "line", text: "♪ " + titleArtist, active: -1, src: "nolyrics" });
  }
}

// LRCLIB is line-level only. With estimateWords on, the line's span (until the
// next line starts) is split across its words by letter count, so a word
// highlight can run without real per-word timing.
function lineWords(text) {
  const words = text.split(" ");
  const weights = words.map((w) => w.replace(/[^\p{L}\p{N}]/gu, "").length + 1);
  return { words, weights, total: weights.reduce((a, b) => a + b, 0) };
}

function estimateWord(idx, t) {
  const line = lines[idx];
  if (!line.text) return -1;
  const next = idx + 1 < lines.length ? lines[idx + 1].t : (songDur || line.t + 5);
  const { words, weights, total } = line.w || (line.w = lineWords(line.text));
  const span = Math.min((next - line.t) * 0.9, words.length * 0.8);
  if (span <= 0) return words.length - 1;
  let at = ((t - line.t) / span) * total;
  for (let i = 0; i < words.length; i++) {
    at -= weights[i];
    if (at < 0) return i;
  }
  return words.length - 1;
}

function onTime(rawT) {
  if (!lines.length) return;
  const t = rawT + OFFSET_SEC;
  let idx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].t <= t) idx = i;
    else break;
  }
  const word = estimateWords && idx >= 0 ? estimateWord(idx, t) : -1;
  if (idx === curIdx && word === curWord) return;
  curIdx = idx;
  curWord = word;
  const text = idx < 0 ? "♪" : lines[idx].text;
  send({ type: "line", text, active: word, src: word >= 0 ? "lrc-est" : "lrc" });
}

api.runtime.onMessage.addListener((msg, sender) => {
  if (!msg || !msg.type) return;
  switch (msg.type) {
    case "mode":
      if (blMode && !msg.bl) trackKey = null;
      blMode = !!msg.bl;
      break;
    case "diag": // one-shot DOM report, relayed into the app's debug log
      send({ type: "diag", text: msg.text || "" });
      break;
    case "bl": // Better Lyrics already computed the line + active word
      send({ type: "line", text: msg.text || "♪", active: msg.active ?? -1, src: msg.timed ? "bl-word" : "bl-line" });
      break;
    case "track":
      if (sender && sender.tab) relayToPage({ cmd: "estimate", value: estimateWords });
      onTrack(msg.title || "", msg.artist || "", msg.duration || 0, msg.art || "",
        !!(sender && sender.tab && (sender.tab.url || "").indexOf("https://open.spotify.com") === 0));
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
