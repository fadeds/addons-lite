"use strict";

const VIDEO_PATTERN = /\.(m3u8|mp4|m4v|mov|flv|webm)(\?|#|$)/i;
const SCHEME = "videosniffer";
const MAX_ITEMS = 120;
// 嗅探期一秒能命中好几次，攒够一批再落盘，避免整数组反复序列化
const FLUSH_DELAY_MS = 600;

let cache = null; // 内存中的列表，storage 只做持久化
let urlIndex = null; // O(1) 去重
let loading = null;
let flushTimer = null;

function setCache(list) {
  cache = Array.isArray(list) ? list : [];
  urlIndex = new Set(cache.map((v) => v && v.url));
}

async function loadVideos() {
  if (cache) return cache;
  if (!loading) {
    loading = browser.storage.local
      .get({ videos: [] })
      .then((data) => {
        setCache(Array.isArray(data.videos) ? data.videos.slice() : []);
        loading = null;
        return cache;
      })
      .catch(() => {
        loading = null;
        setCache([]);
        return cache;
      });
  }
  return loading;
}

function scheduleFlush() {
  if (flushTimer) return;
  flushTimer = setTimeout(function () {
    flushTimer = null;
    if (!cache) return;
    browser.storage.local
      .set({ videos: cache.slice(0, MAX_ITEMS) })
      .catch(function () {});
  }, FLUSH_DELAY_MS);
}

function isVideoURL(url) {
  if (!url || typeof url !== "string") return false;
  if (!/^https?:/i.test(url)) return false;
  return VIDEO_PATTERN.test(url);
}

function hostOf(url) {
  try {
    return new URL(url).host;
  } catch (e) {
    return "";
  }
}

async function addVideos(entries) {
  if (!entries || !entries.length) return;
  const videos = await loadVideos();
  let changed = false;

  for (const entry of entries) {
    if (!entry || !isVideoURL(entry.url)) continue;
    if (urlIndex.has(entry.url)) continue;

    let title = entry.title || "";
    let pageUrl = entry.pageUrl || "";
    const tabId = typeof entry.tabId === "number" ? entry.tabId : null;

    if (tabId !== null && (!title || !pageUrl)) {
      try {
        const tab = await browser.tabs.get(tabId);
        if (!title && tab && tab.title) title = tab.title;
        if (!pageUrl && tab && tab.url && /^https?:/i.test(tab.url)) {
          pageUrl = tab.url;
        }
      } catch (e) {
        // 标签页可能已关闭
      }
    }

    videos.unshift({
      url: entry.url,
      title: title || hostOf(entry.url),
      pageUrl: pageUrl,
      referer: entry.referer || pageUrl,
      tabId: tabId,
      detectedAt: entry.detectedAt || Date.now(),
      source: entry.source || "network"
    });
    urlIndex.add(entry.url);
    changed = true;
  }

  if (videos.length > MAX_ITEMS) {
    const dropped = videos.splice(MAX_ITEMS);
    for (const item of dropped) {
      if (item && item.url) urlIndex.delete(item.url);
    }
    changed = true;
  }

  if (changed) scheduleFlush();
}

// 网络嗅探：只关心可能承载媒体的请求类型。
// 不限 types 时每加载一个页面会回调数千次（图片/脚本/样式全进来）。
browser.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (!details || !details.url) return;
    if (!isVideoURL(details.url)) return;
    addVideos([
      {
        url: details.url,
        tabId: details.tabId,
        source: "network",
        detectedAt: details.timeStamp || Date.now()
      }
    ]).catch(() => {});
  },
  {
    urls: ["<all_urls>"],
    types: ["media", "xmlhttprequest", "object", "other"]
  }
);

// 与 popup / content script 通信
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || !message.type) return;

  let promise;
  switch (message.type) {
    case "list":
      promise = loadVideos().then((videos) => videos.slice());
      break;
    case "clear":
      promise = loadVideos().then(() => {
        setCache([]);
        scheduleFlush();
        return { ok: true };
      });
      break;
    case "remove":
      promise = loadVideos().then((videos) => {
        setCache(videos.filter((v) => v.url !== message.url));
        scheduleFlush();
        return { ok: true };
      });
      break;
    case "found":
      promise = addVideos(message.videos || []).then(() => ({ ok: true }));
      break;
    case "appInfo":
      promise = Promise.resolve({ scheme: SCHEME });
      break;
    default:
      return;
  }

  promise
    .then((result) => sendResponse(result))
    .catch((err) => sendResponse({ error: String(err) }));
  return true;
});
