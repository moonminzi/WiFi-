// NAGO 웹 확장 — 페이지 쪽. 내가 숨긴 요소(사이트마다)를 CSS로 숨기고, 팝업의 "hide an element"를 누르면
// 고르기 모드: 배너를 탭하면 빨간 테두리 → [hide]로 그 사이트에서 계속 숨긴다([↑ bigger]는 감싼 칸까지).
(() => {
  if (window.__nagoLoaded) return;
  window.__nagoLoaded = true;
  const api = globalThis.browser || globalThis.chrome;
  const host = location.hostname.replace(/^www\./, "");
  const key = "site:" + host;
  let site = { rules: [], paused: false };
  let style = null;

  function apply() {
    if (!style) {
      style = document.createElement("style");
      style.id = "nago-hide";
      (document.head || document.documentElement).appendChild(style);
    }
    style.textContent = site.paused ? "" :
      site.rules.map((s) => s + "{display:none!important;visibility:hidden!important}").join("\n");
  }

  async function load() {
    try {
      const got = await api.storage.local.get(key);
      site = Object.assign({ rules: [], paused: false }, got[key] || {});
    } catch (e) {}
    apply();
  }

  async function save() {
    await api.storage.local.set({ [key]: site });
  }

  api.storage.onChanged.addListener((changes) => {
    if (changes[key]) {
      site = Object.assign({ rules: [], paused: false }, changes[key].newValue || {});
      apply();
    }
  });

  function hiddenCount() {
    let n = 0;
    for (const s of site.rules) {
      try { n += document.querySelectorAll(s).length; } catch (e) {}
    }
    return n;
  }

  // ---- 선택자 만들기: id(무작위처럼 보이지 않을 때) → 클래스 → nth-of-type, 하나만 잡힐 때까지 위로
  const randomish = (s) => /\d{3,}|[a-f0-9]{8,}|^_|--|__[a-z0-9]{5,}/i.test(s);
  function part(el) {
    let p = el.tagName.toLowerCase();
    if (el.id && !randomish(el.id)) return p + "#" + CSS.escape(el.id);
    const cls = [...el.classList].filter((c) => !randomish(c) && c.length < 40).slice(0, 2);
    if (cls.length) p += cls.map((c) => "." + CSS.escape(c)).join("");
    const parent = el.parentElement;
    if (parent) {
      const same = [...parent.children].filter((c) => c.tagName === el.tagName);
      if (same.length > 1) p += ":nth-of-type(" + (same.indexOf(el) + 1) + ")";
    }
    return p;
  }
  function selectorFor(el) {
    const parts = [];
    let cur = el;
    for (let depth = 0; cur && cur !== document.documentElement && cur !== document.body && depth < 6; depth++) {
      parts.unshift(part(cur));
      const sel = parts.join(" > ");
      // 이 페이지에서 하나만 잡히고, 그 사이트 다른 페이지에서도 엉뚱한 걸 안 잡을 만큼 구체적일 때(id·클래스가 있거나 두 단계 이상)
      const specific = /[#.]/.test(parts[0]) || parts.length >= 3 || (parts.length >= 2 && /[#.]/.test(sel));
      try { if (specific && document.querySelectorAll(sel).length === 1) return sel; } catch (e) {}
      if (parts[0].includes("#")) break;
      cur = cur.parentElement;
    }
    return parts.join(" > ");
  }

  // ---- 고르기 모드
  let picking = null;
  function startPick() {
    if (picking) return;
    const box = document.createElement("div");
    box.style.cssText = "position:absolute;z-index:2147483646;pointer-events:none;border:2px solid #ef4444;" +
      "background:rgba(239,68,68,.15);border-radius:3px;display:none";
    const bar = document.createElement("div");
    bar.style.cssText = "position:fixed;left:8px;right:8px;bottom:max(8px,env(safe-area-inset-bottom));" +
      "z-index:2147483647;background:#0b0f0c;color:#d1fae5;border:1px solid #22c55e;border-radius:10px;" +
      "font:13px ui-monospace,Menlo,monospace;padding:10px;box-shadow:0 6px 24px rgba(0,0,0,.5)";
    bar.innerHTML = '<div id="nago-msg" style="margin-bottom:8px;color:#86efac">// tap the banner you want gone</div>' +
      '<div style="display:flex;gap:6px">' +
      '<button data-a="up" style="flex:1">↑ bigger</button>' +
      '<button data-a="hide" style="flex:1;background:#22c55e;color:#0b0f0c;font-weight:700">hide</button>' +
      '<button data-a="cancel" style="flex:1">cancel</button></div>';
    for (const b of bar.querySelectorAll("button")) {
      b.style.cssText += ";padding:9px 0;border-radius:6px;border:1px solid #22c55e;background:transparent;" +
        "color:#22c55e;font:inherit;font-size:13px";
      if (b.dataset.a === "hide") b.style.cssText += ";background:#22c55e;color:#0b0f0c;font-weight:700";
    }
    document.documentElement.appendChild(box);
    document.documentElement.appendChild(bar);
    picking = { box, bar, el: null };

    const msg = bar.querySelector("#nago-msg");
    function show(el) {
      picking.el = el;
      const r = el.getBoundingClientRect();
      Object.assign(box.style, { display: "block", left: r.left + scrollX + "px", top: r.top + scrollY + "px",
        width: r.width + "px", height: r.height + "px" });
      msg.textContent = selectorFor(el).slice(0, 120);
    }
    function onTap(e) {
      if (bar.contains(e.target)) return;
      e.preventDefault();
      e.stopPropagation();
      const el = document.elementFromPoint(e.clientX, e.clientY);
      if (el && el !== box && !bar.contains(el)) show(el);
    }
    picking.onTap = onTap;
    document.addEventListener("click", onTap, true);
    bar.addEventListener("click", async (e) => {
      const a = e.target.dataset && e.target.dataset.a;
      if (!a) return;
      e.preventDefault();
      e.stopPropagation();
      if (a === "up" && picking.el && picking.el.parentElement && picking.el.parentElement !== document.body) {
        show(picking.el.parentElement);
      } else if (a === "hide" && picking.el) {
        const sel = selectorFor(picking.el);
        if (!site.rules.includes(sel)) site.rules.push(sel);
        site.paused = false;
        apply();
        await save();
        stopPick();
      } else if (a === "cancel") {
        stopPick();
      }
    }, true);
  }
  function stopPick() {
    if (!picking) return;
    document.removeEventListener("click", picking.onTap, true);
    picking.box.remove();
    picking.bar.remove();
    picking = null;
  }

  api.runtime.onMessage.addListener((m, sender, respond) => {
    if (!m || !m.type) return;
    if (m.type === "info") {
      respond({ host, rules: site.rules, paused: site.paused, hidden: hiddenCount() });
    } else if (m.type === "pick") {
      startPick();
      respond({ ok: true });
    }
    return true;
  });

  load();
  // 늦게 생기는 head에 다시 붙인다
  document.addEventListener("DOMContentLoaded", () => { if (style && !style.isConnected) { style = null; apply(); } });
})();
