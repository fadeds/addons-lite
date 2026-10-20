"use strict";

(function () {
  if (window.__videoSnifferInjected) return;
  window.__videoSnifferInjected = true;

  const VIDEO_RE = /\.(m3u8|mp4|m4v|mov|flv|webm)(\?|#|$)/i;
  const sent = new Set();

  function send(url, kind) {
    if (!url || typeof url !== "string") return;
    if (!/^https?:/i.test(url)) return;
    if (!VIDEO_RE.test(url)) return;
    if (sent.has(url)) return;
    sent.add(url);

    try {
      const result = browser.runtime.sendMessage({
        type: "found",
        videos: [
          {
            url: url,
            pageUrl: location.href,
            title: document.title || "",
            source: kind
          }
        ]
      });
      if (result && typeof result.catch === "function") result.catch(function () {});
    } catch (e) {
      // 扩展上下文已失效，忽略
    }
  }

  function scan(root) {
    if (!root || !root.querySelectorAll) return;

    const seeds = [];
    if (root.matches && root.matches("video, source")) seeds.push(root);
    const mediaList = seeds.concat(Array.prototype.slice.call(root.querySelectorAll("video, source")));
    for (const el of mediaList) {
      if (el.tagName === "VIDEO" && el.src) send(el.src, "dom");
      if (el.tagName === "VIDEO") {
        const sources = el.querySelectorAll("source[src]");
        for (const s of sources) send(s.src, "dom");
      } else if (el.tagName === "SOURCE" && el.src) {
        send(el.src, "dom");
      }
    }

    const metaSelector =
      "meta[property='og:video'], meta[property='og:video:url'], " +
      "meta[name='og:video'], meta[property='twitter:player:stream']";
    for (const meta of root.querySelectorAll(metaSelector)) {
      const content = meta.getAttribute("content");
      if (content) send(content, "meta");
    }

    for (const a of root.querySelectorAll("a[href]")) {
      const href = a.getAttribute("href");
      if (href && /^https?:/i.test(href)) send(href, "link");
    }
  }

  const observer = new MutationObserver((mutations) => {
    for (const mutation of mutations) {
      if (mutation.type === "attributes") {
        const target = mutation.target;
        if (
          (target.tagName === "VIDEO" || target.tagName === "SOURCE") &&
          target.src
        ) {
          send(target.src, "dom");
        }
      } else if (mutation.type === "childList") {
        for (const node of mutation.addedNodes) {
          if (node.nodeType !== 1) continue;
          if (
            (node.tagName === "VIDEO" || node.tagName === "SOURCE") &&
            node.src
          ) {
            send(node.src, "dom");
          }
          scan(node);
        }
      }
    }
  });

  const root = document.documentElement || document;
  observer.observe(root, {
    subtree: true,
    childList: true,
    attributes: true,
    attributeFilter: ["src"]
  });

  scan(document);
})();
