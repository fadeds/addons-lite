"use strict";

(function () {
  if (window.__videoSnifferInjected) return;
  window.__videoSnifferInjected = true;

  const VIDEO_RE = /\.(m3u8|mp4|m4v|mov|flv|webm)(\?|#|$)/i;
  const sent = new Set();
  // 常驻标签页里 Set 会随页面链接无限增长，超阈值整体清空（重复上报由后台去重兜底）
  const MAX_SENT = 400;

  function send(url, kind) {
    if (!url || typeof url !== "string") return;
    if (!/^https?:/i.test(url)) return;
    if (!VIDEO_RE.test(url)) return;
    if (sent.has(url)) return;
    if (sent.size >= MAX_SENT) sent.clear();
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

  // 变更节点批量处理：SPA / 无限滚动页面每帧都会新增大量节点，
  // 逐个节点跑 querySelectorAll 是 O(n²)，主线程直接卡死。
  let scanTimer = null;
  const scanQueue = new Set();

  function scheduleScan(node) {
    if (node && node.nodeType === 1 && node.isConnected) scanQueue.add(node);
    if (scanTimer) return;
    scanTimer = setTimeout(function () {
      scanTimer = null;
      const nodes = Array.from(scanQueue);
      scanQueue.clear();
      if (!nodes.length) return;
      for (const pending of nodes) {
        if (pending.isConnected) scan(pending);
      }
    }, 300);
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
          scheduleScan(node);
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
