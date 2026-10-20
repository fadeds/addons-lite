"use strict";

const VIDEO_PATTERN = /\.(m3u8|mp4|m4v|mov|flv|webm)(\?|#|$)/i;
const SCHEME = "videosniffer";
const MAX_ITEMS = 120;

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

async function loadVideos() {
  const data = await browser.storage.local.get({ videos: [] });
  return Array.isArray(data.videos) ? data.videos : [];
}

async function saveVideos(videos) {
  await browser.storage.local.set({ videos: videos.slice(0, MAX_ITEMS) });
}

async function addVideos(entries) {
  if (!entries || !entries.length) return;
  const videos = await loadVideos();
  let changed = false;

  for (const entry of entries) {
    if (!entry || !isVideoURL(entry.url)) continue;
    if (videos.some((v) => v.url === entry.url)) continue;

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
    changed = true;
  }

  if (changed) await saveVideos(videos);
}

// 网络嗅探：拦截 m3u8 / mp4 等媒体请求
browser.webRequest.onBeforeRequest.addListener(
  (details) => {
    if (!details || !details.url) return;
    if (isVideoURL(details.url)) {
      addVideos([
        {
          url: details.url,
          tabId: details.tabId,
          source: "network",
          detectedAt: details.timeStamp || Date.now()
        }
      ]).catch(() => {});
    }
  },
  { urls: ["<all_urls>"] }
);

// 与 popup / content script 通信
browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || !message.type) return;

  let promise;
  switch (message.type) {
    case "list":
      promise = loadVideos();
      break;
    case "clear":
      promise = saveVideos([]).then(() => ({ ok: true }));
      break;
    case "remove":
      promise = loadVideos()
        .then((videos) => saveVideos(videos.filter((v) => v.url !== message.url)))
        .then(() => ({ ok: true }));
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
