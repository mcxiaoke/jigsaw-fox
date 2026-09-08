/**
 * studio.static.js.api — REST API 请求客户端
 */

export async function checkHealth(timeoutMs = 4000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch("/api/health?t=" + Date.now(), {
      signal: controller.signal,
      cache: "no-store",
    });
    clearTimeout(timer);
    if (!res.ok) return false;
    const data = await res.json();
    return Boolean(data && data.ok);
  } catch (_) {
    clearTimeout(timer);
    return false;
  }
}

export async function fetchTaxonomy() {
  const res = await fetch("/api/taxonomy");
  if (!res.ok) throw new Error("获取分类体系元数据失败");
  return await res.json();
}

export async function scanDirectory(dir) {
  const res = await fetch(`/api/scan?dir=${encodeURIComponent(dir)}`);
  const data = await res.json();
  if (!res.ok || !data.ok) throw new Error(data.error || "目录扫描失败");
  return data;
}

export async function fetchTags(dir) {
  const res = await fetch(`/api/tags?dir=${encodeURIComponent(dir)}`);
  const data = await res.json();
  if (!res.ok || !data.ok) throw new Error(data.error || "读取 tags.json 失败");
  return data;
}

export async function saveTags(dir, records) {
  const res = await fetch("/api/tags", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: jsonStringifySafe({ dir, records }),
  });
  const data = await res.json();
  if (!res.ok || !data.ok) throw new Error(data.error || "保存 tags.json 失败");
  return data;
}

export async function executeExport(payload) {
  const res = await fetch("/api/export", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: jsonStringifySafe(payload),
  });
  const data = await res.json();
  if (!res.ok || !data.ok) {
    const err = new Error(data.error || "导出失败");
    err.logs = data.logs || [];
    throw err;
  }
  return data;
}

export async function previewExport(payload) {
  const res = await fetch("/api/export/preview", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: jsonStringifySafe(payload),
  });
  const data = await res.json();
  if (!res.ok || !data.ok) throw new Error(data.error || "导出预检失败");
  return data;
}

export function getThumbUrl(absOrRelPath, size = 360, baseDir = "") {
  let full = absOrRelPath;
  if (baseDir && !/^[A-Za-z]:[\\/]/.test(absOrRelPath) && !absOrRelPath.startsWith("/")) {
    full = baseDir.replace(/[\\/]+$/, "") + "/" + absOrRelPath.replace(/^[\\/]+/, "");
  }
  const dirParam = baseDir ? `&dir=${encodeURIComponent(baseDir)}` : "";
  // 尺寸阶梯离散分桶 (240, 360, 480, 640, 800)，极大提高浏览器与服务端的缓存命中复用率
  const bucketSize = size <= 260 ? 240 : (size <= 380 ? 360 : (size <= 520 ? 480 : (size <= 700 ? 640 : 800)));
  return `/api/thumb?path=${encodeURIComponent(full)}&size=${bucketSize}${dirParam}`;
}

export function getFileUrl(absOrRelPath, baseDir = "") {
  let full = absOrRelPath;
  if (baseDir && !/^[A-Za-z]:[\\/]/.test(absOrRelPath) && !absOrRelPath.startsWith("/")) {
    full = baseDir.replace(/[\\/]+$/, "") + "/" + absOrRelPath.replace(/^[\\/]+/, "");
  }
  const dirParam = baseDir ? `&dir=${encodeURIComponent(baseDir)}` : "";
  return `/api/file?path=${encodeURIComponent(full)}${dirParam}`;
}

export async function fetchQuality(path, hash = "", dir = "", force = false) {
  const params = new URLSearchParams();
  if (path) params.set("path", path);
  if (hash) params.set("hash", hash);
  if (dir) params.set("dir", dir);
  if (force) params.set("force", "1");
  const res = await fetch(`/api/quality?${params.toString()}`);
  const data = await res.json();
  if (!res.ok || !data.ok) throw new Error(data.error || "获取质检数据失败");
  return data;
}

export async function fetchQualityStats(dir) {
  const res = await fetch(`/api/quality/stats?dir=${encodeURIComponent(dir)}`);
  const data = await res.json();
  if (!res.ok || !data.ok) throw new Error(data.error || "获取质检统计失败");
  return data;
}

export async function batchEvaluateQuality(dir, limit = 50, paths = []) {
  const res = await fetch("/api/quality/batch", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ dir, limit, paths }),
  });
  const data = await res.json();
  if (!res.ok || !data.ok) throw new Error(data.error || "批量质检执行失败");
  return data;
}

function jsonStringifySafe(obj) {
  // 紧凑序列化：导出 payload 可能携带上万条 slim 记录，
  // 缩进格式会令请求体体积近乎翻倍（实测 3000 张 ~2.1MB → ~1.1MB）
  return JSON.stringify(obj);
}
