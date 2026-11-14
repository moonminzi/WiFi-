// ==UserScript==
// @name         Cercube 유튜브 앱 리다이렉트
// @namespace    https://github.com/moonminzi/WiFi-
// @version      1.0.0
// @description  유튜브 링크를 눌렀을 때 브라우저 대신 유튜브(Cercube) 앱으로 바로 열어줍니다. iOS Safari의 "Userscripts" 앱에 그대로 넣어서 쓸 수 있는 단독 버전입니다.
// @author       moonminzi
// @match        *://*.youtube.com/*
// @match        *://youtu.be/*
// @exclude      *://music.youtube.com/*
// @exclude      *://*.youtube.com/embed/*
// @exclude      *://*.youtube.com/live_chat*
// @run-at       document-start
// @grant        none
// @noframes
// ==/UserScript==

(function () {
  "use strict";

  if (window.top !== window.self) return; // 임베드/iframe 제외

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

  var appUrl = buildYouTubeAppUrl(window.location.href);
  if (!appUrl) return;

  try { window.stop(); } catch (e) {}
  window.location.href = appUrl;
})();
