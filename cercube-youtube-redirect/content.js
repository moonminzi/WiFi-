/*
 * Cercube 유튜브 앱 리다이렉트 — content script
 *
 * youtube.com / youtu.be / m.youtube.com 페이지가 "열리기 시작할 때"(document_start)
 * 바로 youtube:// URL 스킴으로 이동시켜서, 설치된 유튜브(Cercube) 앱으로 넘겨준다.
 * 앱이 설치돼 있지 않으면 스킴 이동이 무시되고 그냥 웹페이지가 계속 뜬다.
 */
(function () {
  "use strict";

  // iframe(임베드 플레이어 등) 안에서는 절대 리다이렉트하지 않는다.
  // (manifest의 all_frames:false 로도 막지만 이중 방어)
  if (window.top !== window.self) return;

  var api = (typeof browser !== "undefined" && browser.storage) ? browser : chrome;

  /**
   * 원본 유튜브 웹 URL → 유튜브 앱 URL 스킴 변환.
   * 변환 대상이 아니면 null.
   */
  function buildYouTubeAppUrl(href) {
    var url;
    try {
      url = new URL(href);
    } catch (e) {
      return null;
    }

    // http/https 외(이미 youtube:// 등)는 건드리지 않는다 → 루프 방지
    if (url.protocol !== "http:" && url.protocol !== "https:") return null;

    var host = url.hostname.toLowerCase();

    // 1) youtu.be 단축 링크 → 정식 watch URL 로 정규화
    //    https://youtu.be/VIDEO_ID?t=30  →  youtube://www.youtube.com/watch?v=VIDEO_ID&t=30
    if (host === "youtu.be") {
      var id = url.pathname.replace(/^\/+/, "").split("/")[0];
      if (!id) return null;
      var app = "youtube://www.youtube.com/watch?v=" + encodeURIComponent(id);
      var t = url.searchParams.get("t");
      if (t) app += "&t=" + encodeURIComponent(t);
      return app;
    }

    // 2) *.youtube.com (www / m / 기타 서브도메인)
    if (host === "youtube.com" || host.endsWith(".youtube.com")) {
      // music.youtube.com 은 유튜브 뮤직(별도 앱)이라 제외 (manifest에서도 제외)
      if (host === "music.youtube.com") return null;
      // 임베드/라이브챗은 제외 (manifest에서도 제외하지만 이중 방어)
      if (/^\/(embed|live_chat)/.test(url.pathname)) return null;

      // 호스트는 www.youtube.com 으로 통일하고, 경로/쿼리/해시는 그대로 유지.
      // youtube 앱은 youtube:// 스킴 뒤에 일반 웹 경로를 그대로 받는다.
      // (watch / shorts / playlist / channel / @handle / results 등 모두 처리됨)
      return "youtube://www.youtube.com" + url.pathname + url.search + url.hash;
    }

    return null;
  }

  var appUrl = buildYouTubeAppUrl(window.location.href);
  if (!appUrl) return;

  // 설정(enabled) 확인 후 리다이렉트. 기본값 on.
  try {
    api.storage.local.get({ enabled: true }, function (cfg) {
      if (cfg && cfg.enabled === false) return;
      redirect(appUrl);
    });
  } catch (e) {
    // storage 접근 실패 시에도 기본 동작(리다이렉트)은 유지
    redirect(appUrl);
  }

  function redirect(target) {
    // 아직 받고 있는 웹페이지 로딩을 멈추고 앱으로 넘긴다.
    try { window.stop(); } catch (e) {}
    window.location.href = target;
  }
})();
