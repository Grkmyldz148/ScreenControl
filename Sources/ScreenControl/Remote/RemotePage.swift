/// Telefonda açılan tek sayfa. Dış kaynak yok: Mac internete çıkamasa da çalışsın.
///
/// Anahtar sayfanın adresinde (`?t=`) durur ki ana ekran kısayolu onu da taşısın.
/// Sürgü değerleri gönderilirken her hedef için yalnızca en son değer bekletilir ve
/// istekler sırayla gider; böylece Wi-Fi gecikse bile eski bir değer yenisini ezemez.
enum RemotePage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<meta name="color-scheme" content="light dark">
<meta name="theme-color" content="#f2f2f5" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#101012" media="(prefers-color-scheme: dark)">
<meta name="mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="ScreenControl">
<link rel="icon" href="/icon.png">
<link rel="apple-touch-icon" href="/icon.png">
<title>ScreenControl</title>
<style>
:root {
  --bg: #f2f2f5; --card: #ffffff; --text: #1c1c1e; --muted: #6c6c72; --line: #dedee3;
  --track: #e3e3e8; --accent: #f0a020; --ok: #2fb350; --warn: #c93400;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #101012; --card: #1c1c1f; --text: #f2f2f7; --muted: #9a9aa1; --line: #2e2e33;
    --track: #38383d; --accent: #f5b041; --ok: #3ccf63; --warn: #ff8a65;
  }
}
* { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
html, body { margin: 0; background: var(--bg); color: var(--text); }
body { font: 16px/1.4 system-ui, -apple-system, Roboto, "Segoe UI", sans-serif; }
main {
  max-width: 480px; margin: 0 auto;
  padding: max(20px, env(safe-area-inset-top)) 16px max(28px, env(safe-area-inset-bottom));
}
header { display: flex; align-items: center; gap: 10px; margin: 4px 4px 16px; }
h1 { font-size: 22px; font-weight: 650; margin: 0; flex: 1; }
.dot { width: 9px; height: 9px; border-radius: 50%; background: var(--muted); transition: background .3s; }
.dot.ok { background: var(--ok); }
.card { background: var(--card); border-radius: 18px; padding: 16px 18px; margin-bottom: 12px; }
.row { display: flex; align-items: center; gap: 8px; }
.name { font-weight: 600; flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.pct { color: var(--muted); font-weight: 600; font-variant-numeric: tabular-nums; min-width: 3.2em; text-align: right; }
.badge {
  font-size: 11px; font-weight: 600; color: var(--muted);
  border: 1px solid var(--line); border-radius: 6px; padding: 1px 6px; white-space: nowrap;
}
.note { color: var(--muted); font-size: 14px; margin: 6px 0 0; }
input[type=range] {
  -webkit-appearance: none; appearance: none; display: block;
  width: 100%; height: 44px; margin: 6px 0 -6px; background: transparent; --fill: 0%;
}
input[type=range]:focus { outline: none; }
input[type=range]::-webkit-slider-runnable-track {
  height: 12px; border-radius: 6px;
  background: linear-gradient(to right, var(--accent) var(--fill), var(--track) var(--fill));
}
input[type=range]::-webkit-slider-thumb {
  -webkit-appearance: none; width: 30px; height: 30px; margin-top: -9px; border-radius: 50%;
  background: #fff; border: 0; box-shadow: 0 1px 5px rgba(0, 0, 0, .35);
}
input[type=range]::-moz-range-track { height: 12px; border-radius: 6px; background: var(--track); }
input[type=range]::-moz-range-progress { height: 12px; border-radius: 6px; background: var(--accent); }
input[type=range]::-moz-range-thumb {
  width: 30px; height: 30px; border: 0; border-radius: 50%; background: #fff;
  box-shadow: 0 1px 5px rgba(0, 0, 0, .35);
}
input[type=range]:disabled { opacity: .4; }
.buttons { display: grid; grid-template-columns: repeat(4, 1fr); gap: 8px; margin-top: 12px; }
button {
  font: inherit; font-weight: 600; color: var(--text); background: var(--bg);
  border: 0; border-radius: 12px; padding: 12px 0; min-height: 44px;
}
button:active { background: var(--line); }
.switch { display: flex; align-items: center; gap: 12px; cursor: pointer; }
.name small { display: block; color: var(--muted); font-size: 13px; font-weight: 400; overflow: hidden; text-overflow: ellipsis; }
.pill { min-height: 34px; padding: 0 14px; font-size: 14px; border-radius: 10px; }
.buttons.three { grid-template-columns: repeat(3, 1fr); }
.switch input {
  -webkit-appearance: none; appearance: none; flex: none; margin: 0;
  width: 50px; height: 30px; border-radius: 15px; background: var(--track); position: relative;
  transition: background .2s;
}
.switch input::after {
  content: ""; position: absolute; top: 3px; left: 3px; width: 24px; height: 24px;
  border-radius: 50%; background: #fff; box-shadow: 0 1px 3px rgba(0, 0, 0, .3); transition: transform .2s;
}
.switch input:checked { background: var(--ok); }
.switch input:checked::after { transform: translateX(20px); }
.msg { color: var(--warn); font-weight: 500; margin: 0 4px 14px; }
[hidden] { display: none !important; }
</style>
</head>
<body>
<main>
  <header>
    <h1>ScreenControl</h1>
    <span class="dot" id="dot" role="img" aria-label="Connection status"></span>
  </header>
  <p class="msg" id="msg" role="alert" hidden></p>
  <div id="displays"></div>
  <p class="card note" id="empty" hidden>No controllable displays found on your Mac.</p>
  <section class="card" id="volumeCard" hidden>
    <div class="row">
      <span class="name">Volume<small id="volumeDevice"></small></span>
      <span class="pct" id="volumePct"></span>
      <button type="button" class="pill" id="mute">Mute</button>
    </div>
    <input type="range" id="volume" min="0" max="100" step="1" aria-label="Volume">
    <div class="buttons three" id="volumeKeys" hidden>
      <button type="button" data-key="down" aria-label="Volume down">−</button>
      <button type="button" data-key="mute">Mute</button>
      <button type="button" data-key="up" aria-label="Volume up">+</button>
    </div>
    <p class="note" id="volumeNote" hidden>This output has no software volume, so these buttons press the Mac’s volume keys. Apps like SoundSource pick them up.</p>
  </section>
  <section class="card" id="quick" hidden>
    <div class="row"><span class="name">All displays</span></div>
    <div class="buttons">
      <button type="button" data-percent="0">Off</button>
      <button type="button" data-percent="25">25%</button>
      <button type="button" data-percent="50">50%</button>
      <button type="button" data-percent="100">100%</button>
    </div>
  </section>
  <label class="card switch" id="linkRow" hidden>
    <span class="name">Link displays<small>The monitor follows the Mac’s screen</small></span>
    <input type="checkbox" id="link">
  </label>
</main>
<script>
"use strict";
const token = new URLSearchParams(location.search).get("t") || "";
const $ = (id) => document.getElementById(id);
const rows = new Map();
let renderedKeys = null;
let dragging = null;

async function api(path, body) {
  const headers = { "Authorization": "Bearer " + token };
  if (body) headers["Content-Type"] = "application/json";
  const response = await fetch(path, {
    method: body ? "POST" : "GET", headers, cache: "no-store",
    body: body ? JSON.stringify(body) : undefined,
  });
  if (response.status === 401) throw new Error("auth");
  if (!response.ok) throw new Error("http");
  return response.json();
}

function showProblem(error) {
  const msg = $("msg");
  if (!error) {
    msg.hidden = true;
    $("dot").classList.add("ok");
    return;
  }
  $("dot").classList.remove("ok");
  msg.textContent = error.message === "auth"
    ? "This link is no longer valid. Open ScreenControl on your Mac and scan the QR code again."
    : "Can’t reach your Mac. Make sure it’s awake and on the same Wi-Fi.";
  msg.hidden = false;
}

// Aynı hedefe ait bekleyen isteklerden yalnızca en sonuncusu tutulur.
const outbox = new Map();
let pumping = false;

function post(target, path, body) {
  outbox.delete(target);
  outbox.set(target, [path, body]);
  if (!pumping) pump();
}

async function pump() {
  pumping = true;
  while (outbox.size) {
    const [target, [path, body]] = outbox.entries().next().value;
    outbox.delete(target);
    try {
      render(await api(path, body));
    } catch (error) {
      showProblem(error);
    }
  }
  pumping = false;
}

function paint(row, percent) {
  row.input.value = percent;
  row.input.style.setProperty("--fill", percent + "%");
  row.pct.textContent = Math.round(percent) + "%";
}

function build(displays) {
  const list = $("displays");
  list.replaceChildren();
  rows.clear();
  for (const display of displays) {
    const card = document.createElement("section");
    card.className = "card";
    const head = document.createElement("div");
    head.className = "row";
    const name = document.createElement("span");
    name.className = "name";
    name.textContent = display.name;
    const badge = document.createElement("span");
    badge.className = "badge";
    badge.textContent = "backlight off";
    const pct = document.createElement("span");
    pct.className = "pct";
    head.append(name, badge, pct);

    const input = document.createElement("input");
    input.type = "range";
    input.min = "0";
    input.max = "100";
    input.step = "1";
    input.disabled = !display.controllable;
    input.setAttribute("aria-label", display.name + " brightness");
    card.append(head, input);
    if (!display.controllable) {
      const note = document.createElement("p");
      note.className = "note";
      note.textContent = "This display can’t be controlled.";
      card.append(note);
    }

    const row = { input, pct, badge };
    const key = display.key;
    input.addEventListener("input", () => {
      dragging = key;
      paint(row, Number(input.value));
      post(key, "/api/brightness", { display: key, percent: Number(input.value), final: false });
    });
    input.addEventListener("change", () => {
      dragging = null;
      post(key, "/api/brightness", { display: key, percent: Number(input.value), final: true });
    });

    rows.set(key, row);
    list.append(card);
  }
}

const volumeRow = { input: $("volume"), pct: $("volumePct") };

function renderVolume(volume) {
  $("volumeCard").hidden = !volume;
  if (!volume) return;
  $("volumeDevice").textContent = volume.device;
  if (dragging !== "volume") paint(volumeRow, volume.percent);
  if (volume.muted) volumeRow.pct.textContent = "Muted";
  // Sabit sesli aygıtta (ör. düğmeli ses kartı) yüzde anlamsız; sadece açıklama kalsın.
  volumeRow.pct.hidden = !volume.controllable;
  volumeRow.input.hidden = !volume.controllable;
  $("volumeKeys").hidden = volume.controllable;
  $("volumeNote").hidden = volume.controllable;
  $("mute").hidden = !volume.canMute;
  $("mute").textContent = volume.muted ? "Unmute" : "Mute";
  $("mute").dataset.muted = String(volume.muted);
}

function render(state) {
  showProblem(null);
  const keys = state.displays.map((d) => d.key).join("|");
  if (keys !== renderedKeys) {
    build(state.displays);
    renderedKeys = keys;
  }
  for (const display of state.displays) {
    const row = rows.get(display.key);
    if (dragging !== display.key) paint(row, display.percent);
    row.badge.hidden = !display.backlightOff;
  }
  const any = state.displays.some((d) => d.controllable);
  $("empty").hidden = any;
  $("quick").hidden = !any;
  $("linkRow").hidden = !state.canLink;
  $("link").checked = state.linked;
  renderVolume(state.volume);
}

async function refresh() {
  // Bir gönderim sürerken gelen durum eski olabilir; sürgüyü geri zıplatmasın.
  if (document.hidden || pumping || dragging) return;
  try {
    const state = await api("/api/state");
    if (!pumping && !dragging) render(state);
  } catch (error) {
    showProblem(error);
  }
}

for (const button of document.querySelectorAll("[data-percent]")) {
  button.addEventListener("click", () => {
    post("all", "/api/brightness", { percent: Number(button.dataset.percent), final: true });
  });
}
volumeRow.input.addEventListener("input", () => {
  dragging = "volume";
  paint(volumeRow, Number(volumeRow.input.value));
  post("volume", "/api/volume", { percent: Number(volumeRow.input.value) });
});
volumeRow.input.addEventListener("change", () => {
  dragging = null;
  post("volume", "/api/volume", { percent: Number(volumeRow.input.value) });
});
for (const button of document.querySelectorAll("[data-key]")) {
  // Her basış bir adım; en son değeri tutan kuyruk burada basışları yutmasın diye
  // her birine ayrı hedef adı veriyoruz.
  let presses = 0;
  button.addEventListener("click", () => {
    post("key-" + button.dataset.key + "-" + presses++, "/api/volume", { key: button.dataset.key });
  });
}
$("mute").addEventListener("click", (event) => {
  post("mute", "/api/volume", { muted: event.target.dataset.muted !== "true" });
});
$("link").addEventListener("change", (event) => {
  post("link", "/api/link", { enabled: event.target.checked });
});
document.addEventListener("visibilitychange", refresh);
setInterval(refresh, 2500);

if (token) refresh();
else showProblem(new Error("auth"));
</script>
</body>
</html>
"""#
}
