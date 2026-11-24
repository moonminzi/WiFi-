/* Cercube 유튜브 앱 리다이렉트 — popup */
(function () {
  "use strict";

  // chrome.* 은 크롬·사파리·파이어폭스 모두 콜백 방식을 받는다(browser.* 는 프라미스 전용일 수 있음)
  var api = (typeof chrome !== "undefined" && chrome.storage) ? chrome : browser;

  var toggle = document.getElementById("toggle");
  var statusEl = document.getElementById("status");
  var openBtn = document.getElementById("openCurrent");

  // content.js 와 동일한 변환 규칙 (팝업용 복사본)
  function buildYouTubeAppUrl(href) {
    var url;
    try { url = new URL(href); } catch (e) { return null; }
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;
    var host = url.hostname.toLowerCase();

    if (host === "youtu.be") {
      var id = url.pathname.replace(/^\/+/, "").split("/")[0];
      if (!id) return null;
      var app = "youtube://www.youtube.com/watch?v=" + encodeURIComponent(id);
      var t = url.searchParams.get("t");
      if (t) app += "&t=" + encodeURIComponent(t);
      return app;
    }
    if (host === "youtube.com" || host.endsWith(".youtube.com")) {
      if (host === "music.youtube.com") return null;
      if (/^\/(embed|live_chat)/.test(url.pathname)) return null;
      return "youtube://www.youtube.com" + url.pathname + url.search + url.hash;
    }
    return null;
  }

  function setStatus(text) { statusEl.textContent = text; }

  // 저장된 설정 불러오기
  api.storage.local.get({ enabled: true }, function (cfg) {
    var on = !(cfg && cfg.enabled === false);
    toggle.checked = on;
    setStatus(on ? "켜짐 — 앱으로 리다이렉트합니다." : "꺼짐 — 브라우저에서 엽니다.");
  });

  toggle.addEventListener("change", function () {
    var on = toggle.checked;
    api.storage.local.set({ enabled: on }, function () {
      setStatus(on ? "켜짐 — 앱으로 리다이렉트합니다." : "꺼짐 — 브라우저에서 엽니다.");
    });
  });

  // 현재 탭을 앱에서 열기
  function withActiveTab(cb) {
    try {
      api.tabs.query({ active: true, currentWindow: true }, function (tabs) {
        cb(tabs && tabs[0]);
      });
    } catch (e) {
      cb(null);
    }
  }

  withActiveTab(function (tab) {
    var appUrl = tab && tab.url ? buildYouTubeAppUrl(tab.url) : null;
    if (!appUrl) {
      openBtn.disabled = true;
      openBtn.textContent = "유튜브 페이지가 아닙니다";
      return;
    }
    openBtn.addEventListener("click", function () {
      try {
        api.tabs.update(tab.id, { url: appUrl });
      } catch (e) {
        // 최후의 수단: 팝업에서 직접 이동 시도
        window.location.href = appUrl;
      }
      if (typeof window.close === "function") window.close();
    });
  });
})();
