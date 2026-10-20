"use strict";

const SCHEME = "videosniffer";
const listEl = document.getElementById("list");
const statusEl = document.getElementById("status");
const clearBtn = document.getElementById("clear");

function kindOf(url) {
  const u = url.toLowerCase();
  if (u.indexOf(".m3u8") !== -1) return { label: "HLS", cls: "hls" };
  if (u.indexOf(".mp4") !== -1) return { label: "MP4", cls: "mp4" };
  if (u.indexOf(".flv") !== -1) return { label: "FLV", cls: "flv" };
  if (u.indexOf(".webm") !== -1) return { label: "WEBM", cls: "webm" };
  return { label: "视频", cls: "other" };
}

function hostOf(url) {
  try {
    return new URL(url).host;
  } catch (e) {
    return "";
  }
}

function timeOf(ts) {
  try {
    const d = new Date(ts);
    const pad = (n) => (n < 10 ? "0" + n : "" + n);
    return pad(d.getHours()) + ":" + pad(d.getMinutes());
  } catch (e) {
    return "";
  }
}

function buildItem(video) {
  const kind = kindOf(video.url);

  const li = document.createElement("li");
  li.className = "item";

  const badge = document.createElement("span");
  badge.className = "badge " + kind.cls;
  badge.textContent = kind.label;

  const info = document.createElement("div");
  info.className = "info";

  const title = document.createElement("div");
  title.className = "title";
  title.textContent = video.title || hostOf(video.url);

  const sub = document.createElement("div");
  sub.className = "sub";
  let subText = hostOf(video.url);
  if (video.detectedAt) subText += " · " + timeOf(video.detectedAt);
  sub.textContent = subText;

  info.appendChild(title);
  info.appendChild(sub);

  const actions = document.createElement("div");
  actions.className = "actions";

  const openBtn = document.createElement("button");
  openBtn.className = "open-btn";
  openBtn.type = "button";
  openBtn.textContent = "在 App 打开";
  openBtn.addEventListener("click", function () {
    openInApp(video);
  });

  const delBtn = document.createElement("button");
  delBtn.className = "del-btn";
  delBtn.type = "button";
  delBtn.textContent = "移除";
  delBtn.addEventListener("click", function () {
    browser.runtime
      .sendMessage({ type: "remove", url: video.url })
      .then(function () {
        li.remove();
        updateEmptyState();
      })
      .catch(function () {});
  });

  actions.appendChild(openBtn);
  actions.appendChild(delBtn);

  li.appendChild(badge);
  li.appendChild(info);
  li.appendChild(actions);
  return li;
}

function openInApp(video) {
  const params = new URLSearchParams();
  params.set("url", video.url);
  if (video.pageUrl) params.set("referer", video.pageUrl);
  if (video.title) params.set("title", video.title);

  const target = SCHEME + "://add?" + params.toString();
  const anchor = document.createElement("a");
  anchor.href = target;
  anchor.rel = "noopener";
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();

  setTimeout(function () {
    window.close();
  }, 600);
}

function updateEmptyState() {
  const hasItems = listEl.children.length > 0;
  statusEl.style.display = hasItems ? "none" : "block";
  if (hasItems) {
    statusEl.textContent = "";
  } else {
    statusEl.textContent = "暂未检测到视频。\n播放网页中的视频后再打开本面板。";
  }
  clearBtn.disabled = !hasItems;
}

function render() {
  browser.runtime
    .sendMessage({ type: "list" })
    .then(function (videos) {
      listEl.innerHTML = "";
      const list = Array.isArray(videos) ? videos : [];
      for (let i = 0; i < list.length; i++) {
        listEl.appendChild(buildItem(list[i]));
      }
      updateEmptyState();
    })
    .catch(function (err) {
      statusEl.textContent = "读取失败: " + err;
      statusEl.style.display = "block";
      clearBtn.disabled = true;
    });
}

clearBtn.addEventListener("click", function () {
  browser.runtime
    .sendMessage({ type: "clear" })
    .then(function () {
      render();
    })
    .catch(function () {});
});

render();
