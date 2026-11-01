// NAGO 웹 확장 팝업: 콘텐츠 차단기 상태(앱 쪽에 물어봄) · 이 사이트에서 내가 숨긴 것 · 고르기 · 이 사이트 멈춤
const api = globalThis.browser || globalThis.chrome;
const $ = (id) => document.getElementById(id);
let tab = null;
let host = null;

async function blockerStatus() {
  try {
    const r = await api.runtime.sendNativeMessage("application.id", { type: "status" });
    const el = $("blocker");
    if (!r || !r.found) {
      el.textContent = "missing"; el.className = "off";
      $("blocker-note").textContent = "this build has no content blocker";
      return;
    }
    el.textContent = r.enabled ? "on" : "off";
    el.className = r.enabled ? "on" : "off";
    const rules = r.rules ? Number(r.rules).toLocaleString("en-US") + " rules · " + (r.lists || "") : "";
    $("blocker-note").textContent = r.enabled ? rules
      : "turn on: iOS Settings → Apps → Safari → Extensions → NAGO Blocker" + (r.error ? " (" + r.error + ")" : "");
  } catch (e) {
    $("blocker").textContent = "?";
    $("blocker-note").textContent = "couldn't ask the app: " + e;
  }
}

function render(info) {
  host = info.host;
  $("host").textContent = info.host || "—";
  $("count").textContent = (info.rules || []).length + " rules · " + (info.hidden || 0) + " on page";
  $("pause").checked = !!info.paused;
  const ul = $("rules");
  ul.innerHTML = "";
  for (const sel of info.rules || []) {
    const li = document.createElement("li");
    const s = document.createElement("span"); s.textContent = sel;
    const b = document.createElement("button"); b.textContent = "×"; b.title = "show again";
    b.onclick = () => removeRule(sel);
    li.append(s, b);
    ul.append(li);
  }
}

async function siteInfo() {
  try {
    const info = await api.tabs.sendMessage(tab.id, { type: "info" });
    if (info) return render(info);
  } catch (e) {}
  $("host").textContent = "not available here";
  $("pick").disabled = true;
  $("err").textContent = "allow NAGO on this website (aA → Manage Extensions, or Settings → Safari → Extensions → NAGO → All Websites)";
}

async function update(fn) {
  const key = "site:" + host;
  const got = await api.storage.local.get(key);
  const site = Object.assign({ rules: [], paused: false }, got[key] || {});
  fn(site);
  await api.storage.local.set({ [key]: site });
  setTimeout(siteInfo, 150);
}

function removeRule(sel) { update((s) => { s.rules = s.rules.filter((x) => x !== sel); }); }

$("pause").onchange = (e) => update((s) => { s.paused = e.target.checked; });

$("pick").onclick = async () => {
  try {
    await api.tabs.sendMessage(tab.id, { type: "pick" });
    window.close();
  } catch (e) {
    $("err").textContent = "couldn't start on this page: " + e;
  }
};

(async () => {
  [tab] = await api.tabs.query({ active: true, currentWindow: true });
  blockerStatus();
  if (tab) siteInfo();
})();
