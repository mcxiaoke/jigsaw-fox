/**
 * studio.static.js.api — REST API 请求客户端
 */

// 统一 JSON 解析兜底：服务端返回非 JSON（如代理错误页/HTML/空响应）时，
// 抛出可诊断的错误而不是晦涩的 "Unexpected token < in JSON"
async function parseJson(res, context) {
  try {
    return await res.json();
  } catch (_) {
    throw new Error(
      `${context || "请求"}响应不是有效 JSON (HTTP ${res.status})，服务可能未正常运行`
    );
  }
}

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
  if (!res.ok) throw new Error("获取分类体系元数据失败 (HTTP " + res.status + ")");
  return await parseJson(res, "获取分类体系");
}

export async function scanDirectory(dir) {
  const res = await fetch(`/api/scan?dir=${encodeURIComponent(dir)}`);
  const data = await parseJson(res, "目录扫描");
  if (!res.ok || !data.ok) throw new Error(data.error || "目录扫描失败");
  return data;
}

export async function fetchTags(dir) {
  const res = await fetch(`/api/tags?dir=${encodeURIComponent(dir)}`);
  const data = await parseJson(res, "读取 tags");
  if (!res.ok || !data.ok) throw new Error(data.error || "读取 tags.json 失败");
  return data;
}

export async function saveTags(dir, records) {
  const res = await fetch("/api/tags", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: jsonStringifySafe({ dir, records }),
  });
  const data = await parseJson(res, "保存 tags");
  if (!res.ok || !data.ok) throw new Error(data.error || "保存 tags.json 失败");
  return data;
}

export async function executeExport(payload) {
  const res = await fetch("/api/export", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: jsonStringifySafe(payload),
  });
  const data = await parseJson(res, "导出");
  if (!res.ok || !data.ok) {
    const err = new Error(data.error || "导出失败");
    err.logs = data.logs || [];
    throw err;
  }
  return data;
}

// 导出进度状态快照 (只读轮询)。task 未找到时返回 { ok:false, found:false }，
// 由调用方静默停止轮询并依赖 POST 自身结果，绝不抛错。
export async function fetchExportStatus(taskId) {
  return fetchJobStatus(taskId);
}

// 统一任务状态查询 (导出与质检共用)
export async function fetchJobStatus(taskId) {
  const res = await fetch(`/api/job/status?task=${encodeURIComponent(taskId)}`);
  try {
    const data = await res.json();
    return data || { ok: false, found: false };
  } catch (_) {
    // 轮询通道对非 JSON 响应静默降级：调用方按"任务未找到"处理，由重试机制兜底
    return { ok: false, found: false };
  }
}

export async function previewExport(payload) {
  const res = await fetch("/api/export/preview", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: jsonStringifySafe(payload),
  });
  const data = await parseJson(res, "导出预检");
  if (!res.ok || !data.ok) throw new Error(data.error || "导出预检失败");
  return data;
}

export async function fetchExportLimits() {
  const res = await fetch("/api/export/limits");
  const data = await parseJson(res, "导出限制");
  if (!res.ok || !data.ok) throw new Error(data.error || "读取导出限制失败");
  return data.limits || {};
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
  const data = await parseJson(res, "获取质检数据");
  if (!res.ok || !data.ok) throw new Error(data.error || "获取质检数据失败");
  return data;
}

export async function fetchQualityStats(dir) {
  const res = await fetch(`/api/quality/stats?dir=${encodeURIComponent(dir)}`);
  const data = await parseJson(res, "获取质检统计");
  if (!res.ok || !data.ok) throw new Error(data.error || "获取质检统计失败");
  return data;
}

export async function fetchQualityScores(dir) {
  const res = await fetch(`/api/quality/scores?dir=${encodeURIComponent(dir)}`);
  const data = await parseJson(res, "获取质检分数");
  if (!res.ok || !data.ok) throw new Error(data.error || "获取质检分数失败");
  return data;
}

export async function batchEvaluateQuality(dir, limit = 50, paths = [], force = false, clientTaskId = "") {
  const res = await fetch("/api/quality/batch", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ dir, limit, paths, force, clientTaskId }),
  });
  const data = await parseJson(res, "批量质检启动");
  if (!res.ok || !data.ok) throw new Error(data.error || "批量质检启动失败");
  return data;
}

export async function cancelQualityJob(taskId) {
  const res = await fetch("/api/quality/cancel", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ task: taskId }),
  });
  const data = await res.json().catch(() => ({ ok: false }));
  return data || { ok: false };
}

// 手动裁切框 API
export async function fetchManualCrops(dir) {
  const res = await fetch(`/api/crop/manual?dir=${encodeURIComponent(dir)}`);
  const data = await parseJson(res, "获取手动裁切框");
  if (!res.ok || !data.ok) throw new Error(data.error || "获取手动裁切框失败");
  return data;
}

export async function saveManualCrop(hash, box, ratio, dir = "") {
  const res = await fetch("/api/crop/manual", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      hash,
      dir,
      x0: box.x0,
      y0: box.y0,
      x1: box.x1,
      y1: box.y1,
      ratio,
    }),
  });
  const data = await parseJson(res, "保存裁切框");
  if (!res.ok || !data.ok) throw new Error(data.error || "保存裁切框失败");
  return data;
}

/**
 * 删除单张素材 (软删除: 移动到 <SourceDir>/.deleted/ 并从缓存数据库移除)
 * 已导出的图片由服务端拒绝并返回 error，前端应据此提示。
 */
export async function deleteImage(dir, path, hash = "") {
  const res = await fetch("/api/delete", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ dir, path, hash }),
  });
  const data = await res.json().catch(() => ({ ok: false, error: "删除请求失败" }));
  if (!res.ok || !data.ok) throw new Error(data.error || "删除失败");
  return data;
}

export async function deleteManualCrop(hash, dir = "") {
  const params = new URLSearchParams();
  params.set("hash", hash);
  if (dir) params.set("dir", dir);
  const res = await fetch(`/api/crop/manual?${params.toString()}`, {
    method: "DELETE",
  });
  const data = await parseJson(res, "删除裁切框");
  if (!res.ok || !data.ok) throw new Error(data.error || "删除裁切框失败");
  return data;
}

function jsonStringifySafe(obj) {
  // 紧凑序列化：导出 payload 可能携带上万条 slim 记录，
  // 缩进格式会令请求体体积近乎翻倍（实测 3000 张 ~2.1MB → ~1.1MB）
  return JSON.stringify(obj);
}
