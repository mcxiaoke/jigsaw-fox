/**
 * studio.static.js.app — Content Studio Vue 3 主应用逻辑
 */

import {
  batchEvaluateQuality,
  cancelQualityJob,
  checkHealth,
  deleteImage,
  executeExport,
  fetchJobStatus,
  fetchManualCrops,
  fetchQuality,
  fetchQualityScores,
  fetchQualityStats,
  fetchTags,
  fetchTaxonomy,
  deleteManualCrop as deleteManualCropApi,
  getFileUrl,
  getThumbUrl,
  previewExport,
  saveManualCrop as saveManualCropApi,
  saveTags,
  scanDirectory,
} from "./api.js";

const { createApp, ref, computed, onMounted, watch, nextTick } = window.Vue;

const app = createApp({
  setup() {
    // -----------------------------------------------------------------------
    // 分类元数据 (从 /api/taxonomy 动态获取，前端单一事实源)
    // -----------------------------------------------------------------------
    const mainTags = ref([]);
    const catalogs = ref([]);
    const specificTags = ref([]);
    const tagZh = ref({});
    const catalogToTags = ref({});
    const tagToCatalogs = ref({});

    const tagIcon = computed(() => {
      const map = {};
      for (const t of mainTags.value) map[t.id] = t.icon;
      return map;
    });

    const tagDesc = computed(() => {
      const map = {};
      for (const t of mainTags.value) map[t.id] = t.desc;
      return map;
    });

    // 双行排布拆分 (Row 1: 前 7 个大类 + 全部共 8 项; Row 2: 后 7 个大类共 7 项)
    const mainTagsRow1 = computed(() => mainTags.value.slice(0, 7));
    const mainTagsRow2 = computed(() => mainTags.value.slice(7));

    // -----------------------------------------------------------------------
    // 标签不变量（单一事实源）
    // -----------------------------------------------------------------------
    // 约定：素材没有标签 / 标签无法归类时，tags 一律落成规范兜底标签 ["Others"]，
    // 绝不出现空数组或小写 "others"。于是「是否未分类」在任何位置都等价于
    // `r.tags.includes(OTHERS)`，筛选 / 统计 / 排序不再需要任何特判分支。
    const OTHERS = "Others";
    const isOthersTag = (t) => String(t || "").trim().toLowerCase() === "others";
    const normalizeTags = (tags) => {
      // 无标签落成规范兜底桶 ["Others"]；小写 others / 大小写混杂也统一成规范形式，
      // 保证任意位置 `tags.includes(OTHERS)` 恒等于「未分类」
      const out = [];
      for (const raw of Array.isArray(tags) ? tags : []) {
        const t = isOthersTag(raw) ? OTHERS : String(raw).trim();
        if (t && !out.includes(t)) out.push(t);
      }
      return out.length ? out : [OTHERS];
    };
    const isOthers = (r) => !!(r && Array.isArray(r.tags) && r.tags.includes(OTHERS));
    // 写入标签并同步 catalogs / 待复核态，保证不变量恒成立
    const applyTags = (r, tags, reviewRequired) => {
      r.tags = normalizeTags(tags);
      r.catalogs = [...r.tags];
      r.review_required = reviewRequired === undefined ? isOthers(r) : reviewRequired;
    };

    // -----------------------------------------------------------------------
    // 配置与路径 (本地存储持久化)
    // -----------------------------------------------------------------------
    const srcDir = ref(localStorage.getItem("studio_srcDir") || "");
    const outDir = ref(localStorage.getItem("studio_outDir") || "");
    const httpBase = ref(
      localStorage.getItem("studio_httpBase") || "http://192.168.1.118/data/www/game/test"
    );

    const persistConfig = () => {
      localStorage.setItem("studio_srcDir", srcDir.value);
      localStorage.setItem("studio_outDir", outDir.value);
      localStorage.setItem("studio_httpBase", httpBase.value);
    };

    // -----------------------------------------------------------------------
    // 数据集与选中状态
    // -----------------------------------------------------------------------
    const records = ref([]);
    const selectedSet = ref(new Set());
    const isScanning = ref(false);
    const isSaving = ref(false);

    // -----------------------------------------------------------------------
    // 过滤、排序与显示设置
    // -----------------------------------------------------------------------
    const activeTag = ref("");
    const onlyUnreviewed = ref(false);
    const hideExported = ref(false);
    const onlyDuplicates = ref(false);
    const filterGrade = ref(""); // '' | 'S' | 'A' | 'B' | 'C' | 'F' | 'unscored'
    const filterScoreMin = ref(""); // 分数下限, 空=不限
    const filterScoreMax = ref(""); // 分数上限, 空=不限
    const filterUpgradeable = ref(false); // 仅看 smart crop 可升级图片
    const searchQuery = ref("");
    const sortBy = ref("name"); // 'name' | 'quality' | 'mtime' | 'confidence' | 'size' | 'dimension'
    const sortOrder = ref("asc");

    // 质检状态与汇总
    const isEvaluatingQuality = ref(false);
    const isBatchEvaluating = ref(false);
    const qualitySummary = ref({
      total_files: 0,
      total_scored: 0,
      unscored: 0,
      grades: {},
      statuses: {},
    });
    const unscoredCount = computed(() => records.value.filter((r) => !r.quality).length);
    const scoredCount = computed(() => records.value.filter((r) => !!r.quality).length);

    // 质检后台 job 状态
    const qcTaskId = ref("");
    const qcProgress = ref({ done: 0, total: 0 });
    const qcLogs = ref([]);
    let qcPollTimer = null;

    const qcProgressPercent = computed(() => {
      const { done, total } = qcProgress.value;
      if (!total || total <= 0) return 0;
      return Math.min(100, Math.round((done / total) * 100));
    });
    const initialZoom = (() => {
      try {
        const saved = parseInt(localStorage.getItem("studio_cardZoom"), 10);
        if (!isNaN(saved) && saved >= 120 && saved <= 480) {
          return saved;
        }
      } catch (e) {
        // ignore localStorage access errors
      }
      return 190;
    })();
    const cardZoom = ref(initialZoom);

    // 持久化用户卡片缩放尺寸偏好
    watch(cardZoom, (val) => {
      try {
        if (typeof val === "number" && !isNaN(val)) {
          localStorage.setItem("studio_cardZoom", String(val));
        }
      } catch (e) {
        // ignore
      }
    });

    // -----------------------------------------------------------------------
    // 批量操作参数
    // -----------------------------------------------------------------------
    const batchTagTarget = ref("");

    // -----------------------------------------------------------------------
    // 模态框与弹窗
    // -----------------------------------------------------------------------
    const exportModalOpen = ref(false);
    const exportType = ref("main");
    const exportConfig = ref({
      format: "webp",
      // main 默认数字序号命名，让「文件名 = order」，手动拖拽的顺序在产物上直接可见
      rename: "sequence",
      startOrder: 1,
      version: "",
      month: new Date().toISOString().slice(0, 7).replace("-", ""),
      eventId: "",
      collectionId: "",
      title: "",
      titleZh: "",
      description: "",
      descZh: "",
      displayOrder: 1,
      status: "active",
      outputMode: "zip",
      excludeExported: true,
      exportScope: "all", // 'all' | 'selected'
      sortBy: "name_asc",
      quality: 70,
      // 规格化（长边固定 1920，只缩小）：目标比例族数组 + 裁切方式
      targetRatios: ["auto"], // 'auto'(1:1+4:3) 或手动子集 '1:1' / '4:3' / '2:3'
      cropMode: "smart", // 'smart' | 'center' | 'none'
      // 默认安全：试导出 (试导出=trial:true，不写账本/ID/清单/部署；正式导出需二次确认)
      trial: true,
    });
    const isExporting = ref(false);
    const exportLogs = ref([]);
    const exportSummary = ref("");
    // 本次导出是试导出 (仅前端展示用)：真确值取自服务端响应 res.trial
    const lastExportIsTrial = ref(false);
    const lastTrialDir = ref("");
    // 正式导出二次确认弹窗 (纯前端防呆)
    const confirmFormalOpen = ref(false);
    const formalConfirmChecked = ref(false);
    // 导出进度 (转码 n/total)；仅执行中填充，用于按钮/面板实时提示
    const exportProgress = ref("");
    const exportProgressText = computed(() =>
      exportProgress.value ? `正在导出 (${exportProgress.value})...` : "正在导出...",
    );
    // 本次导出已完成：停留在第③步预览视图 (统计/清单原样)，底部只留「关闭」
    const exportDone = ref(false);
    // 确认导出前的必填校验错误（输出目录等），在第③步红条展示，避免只有一闪而过的 toast
    const exportError = ref("");

    // 待导出范围内是否包含内容重复的图片 (用于弹窗提前预警)
    const hasDuplicateInExportScope = computed(() => {
      let targetRecords = records.value;
      if (exportConfig.value.exportScope === "selected" && selectedSet.value.size > 0) {
        targetRecords = records.value.filter((r) => selectedSet.value.has(r.path));
      }
      if (exportConfig.value.excludeExported) {
        targetRecords = targetRecords.filter((r) => !r.exported);
      }
      const seen = new Set();
      for (const r of targetRecords) {
        const h = (r.hash || "").trim().toLowerCase();
        if (!h) continue;
        if (seen.has(h)) return true;
        seen.add(h);
      }
      return false;
    });

    // 大图预览
    const viewerModalOpen = ref(false);
    const viewerIndex = ref(0);

    // -----------------------------------------------------------------------
    // 手动裁切框 (Cropper.js) 状态
    // -----------------------------------------------------------------------
    const cropMode = ref(false); // 是否在裁切模式
    const cropAspectRatio = ref(1); // 当前比例: 1 / 0.75 / 1.3333 / 0(自由)
    const isSavingCrop = ref(false);
    const manualCropCache = ref({}); // {hash: {crop_x0, crop_y0, crop_x1, crop_y1, crop_ratio}}
    const cropPixelW = ref(0);
    const cropPixelH = ref(0);
    let cropperInstance = null;

    // 裁切框实时像素尺寸文本（低于 1200px 时标红警告）
    const MIN_SIDE = 1200;
    const cropPixelText = computed(() => {
      const w = cropPixelW.value;
      const h = cropPixelH.value;
      if (!w || !h) return "";
      const tooSmall = Math.min(w, h) < MIN_SIDE;
      const label = `${w} × ${h} px`;
      return tooSmall ? `⚠ ${label} (短边 < ${MIN_SIDE})` : label;
    });

    // -----------------------------------------------------------------------
    // 导出三步流状态 (配置 → 顺序调整 → 预览)
    // -----------------------------------------------------------------------
    const exportStep = ref(1);
    const orderGridEl = ref(null);
    // 第②步用 ✕ 剔除的相对路径集合：预检与最终导出都必须真正排除这些图片
    const exportExcluded = ref(new Set());
    const previewState = ref({ loading: false, error: "", ordered: null, stats: null, suggested: null, estRatio: 0.2 });
    const previewLoading = computed(() => !!previewState.value.loading);
    const previewError = computed(() => previewState.value.error || "");
    const previewOrdered = computed(() => previewState.value.ordered || []);
    const previewStats = computed(() => previewState.value.stats || null);
    const suggested = computed(() => previewState.value.suggested || null);
    const suggestedStartHint = computed(() => (suggested.value && exportType.value === "main") ? suggested.value.suggestedStartOrder : null);
    const suggestedMaxOrder = computed(() => (suggested.value && suggested.value.maxOrder) || 0);
    const suggestedVersion = computed(() => (suggested.value && suggested.value.suggestedVersion) || 0);
    const listBase = computed(() => {
      if (exportType.value === "main") {
        const n = Number(exportConfig.value.startOrder);
        if (n > 0) return n;
        return (suggested.value && suggested.value.suggestedStartOrder) || 1;
      }
      return 1;
    });
    const suggestedStartForList = computed(() => listBase.value);
    const suggestedMaxForList = computed(() => (exportType.value === "main" ? listBase.value : 1));
    // 分布条刻度：标签分布与目录分布各自独立归一化，避免互相挤压
    const distMaxTags = computed(() => {
      const s = previewState.value.stats;
      if (!s) return 1;
      const vals = Object.values(s.tags || {});
      return Math.max(1, ...vals);
    });
    const distMaxDirs = computed(() => {
      const s = previewState.value.stats;
      if (!s) return 1;
      const vals = Object.values(s.dirs || {});
      return Math.max(1, ...vals);
    });
    const hbarWidth = (c, kind) => {
      const max = kind === "dirs" ? distMaxDirs.value : distMaxTags.value;
      return `${Math.round((Number(c) / max) * 100)}%`;
    };
    const fmtBytes = (n) => {
      const v = Number(n || 0);
      if (v >= 1 << 30) return (v / (1 << 30)).toFixed(1) + " GB";
      if (v >= 1 << 20) return (v / (1 << 20)).toFixed(1) + " MB";
      if (v >= 1 << 10) return (v / (1 << 10)).toFixed(0) + " KB";
      return v + " B";
    };

    // 打标记录瘦身：仅回传预检/导出真正需要的字段，
    // 避免 25k 张时把 width/height/quality/size 等全量字段塞进请求体（实测可从 MB 级降到 KB 级）
    const buildSlimRecords = () =>
      records.value.map((r) => ({
        path: r.path,
        file: r.file,
        hash: r.hash || "",
        tags: r.tags || [],
        exported: !!r.exported,
      }));

    // 规格化目标比例族选择（多选，互斥于"自动"预设自动池 1:1+4:3）
    const hasRatio = (r) => (exportConfig.value.targetRatios || []).includes(r);
    const toggleRatio = (r) => {
      const arr = exportConfig.value.targetRatios || [];
      if (r === "auto") {
        exportConfig.value.targetRatios = ["auto"];
        return;
      }
      // 显式选择时清掉"自动"预设
      const next = arr.filter((x) => x !== "auto");
      const i = next.indexOf(r);
      if (i >= 0) next.splice(i, 1);
      else next.push(r);
      // 无任何显式选择时回退"自动"
      exportConfig.value.targetRatios = next.length ? next : ["auto"];
    };

    // 构建预检 payload (与最终导出保持一致)
    const buildPreviewPayload = () => {
      const scopeSelected = exportConfig.value.exportScope === "selected" && selectedSet.value.size > 0;
      // 范围集：selected 时用勾选的图片；all 时省略(后端按全部)
      const selectedPaths = scopeSelected ? Array.from(selectedSet.value) : undefined;
      // 顺序集：手动排序时把用户拖出来的顺序单独传给后端
      const manualOrder =
        exportConfig.value.sortBy === "manual" && previewState.value.ordered && previewState.value.ordered.length
          ? previewState.value.ordered.map((o) => o.rel)
          : undefined;
      return {
        type: exportType.value,
        srcDir: srcDir.value.trim(),
        outDir: outDir.value.trim(),
        sortBy: exportConfig.value.sortBy,
        format: exportConfig.value.format,
        quality: exportConfig.value.quality,
        // 规格化（长边固定 1920）
        targetRatios: exportConfig.value.targetRatios || ["auto"],
        cropMode: exportConfig.value.cropMode || "smart",
        excludeExported: Boolean(exportConfig.value.excludeExported),
        selectedPaths,
        manualOrder,
        // ✕ 剔除清单：让后端把这些图片从待导出清单里真正移除（而非排到末尾）
        excludedPaths: exportExcluded.value.size ? Array.from(exportExcluded.value) : undefined,
        tagsRecords: buildSlimRecords(),
      };
    };

    const loadExportPreview = async () => {
      previewState.value.loading = true;
      previewState.value.error = "";
      try {
        const res = await previewExport(buildPreviewPayload());
        previewState.value.ordered = res.ordered || [];
        previewState.value.stats = res.stats || null;
        previewState.value.suggested = res.suggested || null;
        // 记录服务端给出的「预计/原图」换算比，供本地剔除单张后重算体积保持同口径
        const st = res.stats || {};
        previewState.value.estRatio =
          Number(st.sourceBytes) > 0 ? Number(st.estWebpBytes) / Number(st.sourceBytes) : 0.2;
        // 自动填充起始序号（仅 main，且当前为空/小于建议值时）
        if (exportType.value === "main" && res.suggested && res.suggested.suggestedStartOrder) {
          const cur = Number(exportConfig.value.startOrder) || 0;
          if (cur === 0 || cur < res.suggested.suggestedStartOrder) {
            exportConfig.value.startOrder = res.suggested.suggestedStartOrder;
          }
        }
      } catch (e) {
        console.error("[预览预检]", e);
        previewState.value.error = e.message || "预检失败";
      } finally {
        previewState.value.loading = false;
        // 等 loading 覆盖层移除、网格真正渲染后再绑定拖拽
        nextTick(rebuildSortable);
      }
    };

    const resetStartOrderForType = () => {
      if (exportType.value === "main" && suggested.value && suggested.value.suggestedStartOrder) {
        exportConfig.value.startOrder = suggested.value.suggestedStartOrder;
      }
    };

    // Toast 提示
    const toast = ref({ show: false, text: "", timer: null });
    const showToast = (text) => {
      if (toast.value.timer) clearTimeout(toast.value.timer);
      toast.value.text = text;
      toast.value.show = true;
      toast.value.timer = setTimeout(() => {
        toast.value.show = false;
      }, 2500);
    };

    // -----------------------------------------------------------------------
    // 计算属性 (Computed)
    // -----------------------------------------------------------------------

    // 标签统计计数：未打标素材的 tags 已归一化为 ["Others"]，直接平铺计数即可
    const tagCounts = computed(() => {
      const map = {};
      for (const r of records.value) {
        const tags = normalizeTags(r.tags);
        for (const t of tags) {
          map[t] = (map[t] || 0) + 1;
        }
      }
      if (!(OTHERS in map)) map[OTHERS] = 0;
      return map;
    });

    // 待复核总数 (无真实标签 = 落在 Others 桶，或显式标记待复核)
    const unreviewedCount = computed(() => {
      let cnt = 0;
      for (const r of records.value) {
        if (r.review_required || isOthers(r)) {
          cnt++;
        }
      }
      return cnt;
    });

    // 已导出总数
    const exportedCount = computed(() => {
      let cnt = 0;
      for (const r of records.value) {
        if (r.exported) cnt++;
      }
      return cnt;
    });

    // 未导出库存数
    const unexportedCount = computed(() => {
      return Math.max(0, records.value.length - exportedCount.value);
    });

    // 不合格（像素不足 / 分辨率不足）总数：长边 <1920，导出会被规格化阻断
    const smallLongCount = computed(() => {
      let cnt = 0;
      for (const r of records.value) {
        if (r.too_small_long) cnt++;
      }
      return cnt;
    });

    // 重复图片统计
    const duplicateRecords = computed(() => records.value.filter((r) => r.is_duplicate));
    const duplicateCount = computed(() => duplicateRecords.value.length);
    const duplicateGroupsCount = computed(() => {
      const hashes = new Set();
      for (const r of duplicateRecords.value) {
        if (r.hash) hashes.add(r.hash);
      }
      return hashes.size;
    });

    // 过滤后的卡片列表
    const filteredRecords = computed(() => {
      let list = records.value;

      // 1. Tag 过滤 (Others 桶 = tags 里含兜底标签的记录，与真实标签完全同一规则)
      // 侧边栏伪分类："已导出"(__exported) / "不合格"(__small_long)。仅在当前选中时为特例，否则走正常 tag/搜索过滤
      if (activeTag.value === "__exported") {
        list = list.filter((r) => !!r.exported);
      } else if (activeTag.value === "__small_long") {
        list = list.filter((r) => !!r.too_small_long);
      } else if (activeTag.value) {
        if (activeTag.value.toLowerCase() === "others") {
          list = list.filter((r) => isOthers(r));
        } else {
          list = list.filter((r) => r.tags && r.tags.includes(activeTag.value));
        }
      }

      // 2. 待复核过滤
      if (onlyUnreviewed.value) {
        list = list.filter((r) => r.review_required || isOthers(r));
      }

      // 2.5 仅看重复素材过滤
      if (onlyDuplicates.value) {
        list = list.filter((r) => r.is_duplicate);
      }

      // 3. 隐藏已导出 (筛选纯新图)
      if (hideExported.value) {
        list = list.filter((r) => !r.exported);
      }

      // 4. 品质评级过滤
      if (filterGrade.value) {
        if (filterGrade.value === "unscored") {
          list = list.filter((r) => !r.quality);
        } else {
          list = list.filter((r) => r.quality && (r.quality.grade || "").toUpperCase() === filterGrade.value.toUpperCase());
        }
      }

      // 4.5 分数区间过滤
      if (filterScoreMin.value !== "") {
        const minVal = Number(filterScoreMin.value);
        if (!isNaN(minVal)) {
          list = list.filter((r) => r.quality && r.quality.score >= minVal);
        }
      }
      if (filterScoreMax.value !== "") {
        const maxVal = Number(filterScoreMax.value);
        if (!isNaN(maxVal)) {
          list = list.filter((r) => r.quality && r.quality.score <= maxVal);
        }
      }

      // 4.6 可升级过滤 (smart crop score_boosted)
      if (filterUpgradeable.value) {
        list = list.filter((r) => r.quality && r.quality.details && r.quality.details.score_boosted === true);
      }

      // 5. 搜索关键词过滤
      const q = searchQuery.value.trim().toLowerCase();
      if (q) {
        list = list.filter((r) => {
          if (r.file && r.file.toLowerCase().includes(q)) return true;
          if (r.path && r.path.toLowerCase().includes(q)) return true;
          if (r.subject && r.subject.toLowerCase().includes(q)) return true;
          if (r.scene && r.scene.toLowerCase().includes(q)) return true;
          if (r.reason && r.reason.toLowerCase().includes(q)) return true;
          if (
            r.tags &&
            r.tags.some(
              (t) => t.includes(q) || (tagZh.value[t] && tagZh.value[t].includes(q))
            )
          )
            return true;
          return false;
        });
      }

      // 6. 排序
      list = [...list].sort((a, b) => {
        if (sortBy.value === "quality") {
          const qa = a.quality ? (a.quality.score || 0) : -1;
          const qb = b.quality ? (b.quality.score || 0) : -1;
          return sortOrder.value === "asc" ? qa - qb : qb - qa;
        }
        if (sortBy.value === "mtime") {
          return sortOrder.value === "asc"
            ? (a.mtime || 0) - (b.mtime || 0)
            : (b.mtime || 0) - (a.mtime || 0);
        }
        if (sortBy.value === "confidence") {
          return sortOrder.value === "asc"
            ? (a.confidence || 0) - (b.confidence || 0)
            : (b.confidence || 0) - (a.confidence || 0);
        }
        if (sortBy.value === "size") {
          return sortOrder.value === "asc"
            ? (a.size || 0) - (b.size || 0)
            : (b.size || 0) - (a.size || 0);
        }
        if (sortBy.value === "dimension") {
          const da = (a.width || 0) * (a.height || 0);
          const db = (b.width || 0) * (b.height || 0);
          return sortOrder.value === "asc" ? da - db : db - da;
        }
        // 默认按文件名升序
        const fa = (a.file || "").toLowerCase();
        const fb = (b.file || "").toLowerCase();
        return sortOrder.value === "asc" ? fa.localeCompare(fb) : fb.localeCompare(fa);
      });

      return list;
    });

    const selectedCount = computed(() => selectedSet.value.size);

    const isAllFilteredSelected = computed(() => {
      if (filteredRecords.value.length === 0) return false;
      return filteredRecords.value.every((r) => selectedSet.value.has(r.path));
    });

    const currentViewerItem = computed(() => {
      if (viewerIndex.value >= 0 && viewerIndex.value < filteredRecords.value.length) {
        return filteredRecords.value[viewerIndex.value];
      }
      return null;
    });

    // Smart crop 裁切框 overlay 样式: 基于原图尺寸百分比定位
    const cropOverlayStyle = computed(() => {
      const item = currentViewerItem.value;
      if (!item || !item.quality || !item.quality.details || !item.quality.details.crop_box) {
        return {};
      }
      const imgW = item.width || 0;
      const imgH = item.height || 0;
      if (!imgW || !imgH) return {};
      const cb = item.quality.details.crop_box;
      if (!Array.isArray(cb) || cb.length !== 4) return {};
      const [x0, y0, x1, y1] = cb;
      const leftPct = (x0 / imgW) * 100;
      const topPct = (y0 / imgH) * 100;
      const widthPct = ((x1 - x0) / imgW) * 100;
      const heightPct = ((y1 - y0) / imgH) * 100;
      return {
        left: leftPct + "%",
        top: topPct + "%",
        width: widthPct + "%",
        height: heightPct + "%",
      };
    });

    // 手动裁切框: 当前 viewer 图片是否有手动裁切框
    const hasManualCrop = computed(() => {
      const item = currentViewerItem.value;
      if (!item || !item.hash) return false;
      const entry = manualCropCache.value[item.hash];
      return !!(entry && entry.crop_x0 != null);
    });

    // 手动裁切框 overlay 样式 (蓝色框)
    const manualCropOverlayStyle = computed(() => {
      const item = currentViewerItem.value;
      if (!item || !item.hash) return {};
      const entry = manualCropCache.value[item.hash];
      if (!entry || entry.crop_x0 == null) return {};
      return {
        left: (entry.crop_x0 * 100) + "%",
        top: (entry.crop_y0 * 100) + "%",
        width: ((entry.crop_x1 - entry.crop_x0) * 100) + "%",
        height: ((entry.crop_y1 - entry.crop_y0) * 100) + "%",
      };
    });

    // 手动裁切框比例标签
    const manualCropRatio = computed(() => {
      const item = currentViewerItem.value;
      if (!item || !item.hash) return "";
      const entry = manualCropCache.value[item.hash];
      return entry ? (entry.crop_ratio || "") : "";
    });

    // -----------------------------------------------------------------------
    // 交互操作逻辑
    // -----------------------------------------------------------------------

    const doScan = async () => {
      if (!srcDir.value.trim()) {
        showToast("请先指定图片源目录");
        return;
      }
      persistConfig();
      isScanning.value = true;
      try {
        const res = await scanDirectory(srcDir.value.trim());
        // 加载即强制标签不变量：空/缺失 tags 一律落成 ["Others"]，后续全链路无需特判
        records.value = (res.records || []).map((r) => {
          r.tags = normalizeTags(r.tags);
          return r;
        });
        selectedSet.value.clear();
        if (res.stats && res.stats.qualitySummary) {
          qualitySummary.value = res.stats.qualitySummary;
        } else {
          refreshQualitySummary();
        }
        showToast(`扫描成功: 共发现 ${res.total || records.value.length} 张图片`);
        // 后台拉取手动裁切框 (不阻塞 UI)
        fetchManualCropsAfterScan();
      } catch (err) {
        console.error("[扫描目录]", err);
        showToast(`扫描失败: ${err.message}`);
      } finally {
        isScanning.value = false;
      }
    };

    const refreshQualitySummary = () => {
      const grades = {};
      const statuses = {};
      let scored = 0;
      for (const r of records.value) {
        if (r.quality) {
          scored++;
          const g = (r.quality.grade || "C").toUpperCase();
          grades[g] = (grades[g] || 0) + 1;
          const s = (r.quality.status || "PASS").toUpperCase();
          statuses[s] = (statuses[s] || 0) + 1;
        }
      }
      qualitySummary.value = {
        total_files: records.value.length,
        total_scored: scored,
        unscored: Math.max(0, records.value.length - scored),
        grades,
        statuses,
      };
    };

    const evalSingleQuality = async (item, force = false) => {
      if (!item) return;
      isEvaluatingQuality.value = true;
      try {
        const data = await fetchQuality(item.path, item.hash || "", srcDir.value.trim(), force);
        if (data.quality) {
          item.quality = data.quality;
          if (data.hash && !item.hash) {
            item.hash = data.hash;
          }
          refreshQualitySummary();
          showToast(`质检完成: ${item.file} -> ${data.quality.grade}级 (${data.quality.score}分)`);
        }
      } catch (err) {
        console.error("[单张质检]", err);
        showToast(`质检失败: ${err.message}`);
      } finally {
        isEvaluatingQuality.value = false;
      }
    };

    const stopQcPolling = () => {
      if (qcPollTimer !== null) {
        clearTimeout(qcPollTimer);
        qcPollTimer = null;
      }
    };

    const finalizeQualityJob = async (success, info) => {
      stopQcPolling();
      isBatchEvaluating.value = false;
      if (success) {
        const msg = (info && info.summary) || "质检完成";
        showToast(msg);
        // 轻量刷新：只从 SQLite 拉取质检分数，merge 到已有 records，不触发文件系统 rescan
        try {
          const data = await fetchQualityScores(srcDir.value.trim());
          if (data.scores) {
            for (const r of records.value) {
              const rel = (r.relPath || r.path || "").replace(/\\/g, "/");
              const q = data.scores[rel];
              if (q) {
                r.quality = q;
              } else if (!r.quality) {
                r.quality = null;
              }
            }
          }
          if (data.stats) {
            qualitySummary.value = data.stats;
          } else {
            refreshQualitySummary();
          }
        } catch (_) {
          refreshQualitySummary();
        }
      } else {
        const errMsg = (info && info.error) || "质检失败";
        showToast(errMsg === "cancelled" ? "质检已取消" : `质检失败: ${errMsg}`);
      }
      qcTaskId.value = "";
      qcProgress.value = { done: 0, total: 0 };
      qcLogs.value = [];
      try {
        localStorage.removeItem("activeQualityTask");
      } catch (_) {}
    };

    const pollQualityStatus = async () => {
      if (!qcTaskId.value) return;
      let st = null;
      try {
        st = await fetchJobStatus(qcTaskId.value);
      } catch (_) {
        return;
      }
      if (!st || !st.found) {
        // job 丢失（超时/重启）：rescan 装配已落库结果
        await finalizeQualityJob(true, { summary: "任务恢复: 已从缓存装配结果" });
        return;
      }
      qcProgress.value = { done: st.done || 0, total: st.total || 0 };
      if (st.logs && st.logs.length > 0) {
        qcLogs.value = st.logs.slice(-20);
      }
      if (st.state === "done") {
        await finalizeQualityJob(true, { summary: st.summary || "质检完成" });
      } else if (st.state === "error") {
        await finalizeQualityJob(false, { error: st.error || "未知错误" });
      } else {
        // running: 继续轮询
        qcPollTimer = setTimeout(pollQualityStatus, 700);
      }
    };

    const triggerBatchQuality = async (force = false) => {
      if (!srcDir.value.trim()) {
        showToast("请先指定图片源目录");
        return;
      }
      if (isBatchEvaluating.value) {
        showToast("质检任务进行中，请等待完成或取消");
        return;
      }
      const unscored = force ? records.value : records.value.filter((r) => !r.quality);
      if (unscored.length === 0 && !force) {
        showToast("当前所有图片均已完成质检评分");
        return;
      }

      const taskId = "qc_" + Date.now().toString(36) + "_" + Math.random().toString(36).slice(2, 10);
      isBatchEvaluating.value = true;
      qcTaskId.value = taskId;
      qcProgress.value = { done: 0, total: unscored.length };
      qcLogs.value = [];

      try {
        localStorage.setItem("activeQualityTask", JSON.stringify({
          taskId,
          dir: srcDir.value.trim(),
        }));
      } catch (_) {}

      showToast(`开始批量质检 (待评: ${unscored.length} 张)...`);

      try {
        const res = await batchEvaluateQuality(
          srcDir.value.trim(), 500, [], force, taskId
        );
        if (res.total !== undefined) {
          qcProgress.value = { done: 0, total: res.total };
        }
        // 启动轮询
        qcPollTimer = setTimeout(pollQualityStatus, 700);
      } catch (err) {
        console.error("[批量质检]", err);
        await finalizeQualityJob(false, { error: err.message });
      }
    };

    const cancelQuality = async () => {
      if (!qcTaskId.value) return;
      try {
        await cancelQualityJob(qcTaskId.value);
        showToast("正在取消质检任务...");
      } catch (err) {
        console.error("[取消质检]", err);
        showToast(`取消失败: ${err.message}`);
      }
    };

    const resumeQualityJob = async () => {
      let saved = null;
      try {
        saved = JSON.parse(localStorage.getItem("activeQualityTask") || "null");
      } catch (_) {}
      if (!saved || !saved.taskId) return;
      if (saved.dir !== srcDir.value.trim()) return;

      // 检查 job 是否仍在
      try {
        const st = await fetchJobStatus(saved.taskId);
        if (st && st.found && st.state === "running") {
          qcTaskId.value = saved.taskId;
          isBatchEvaluating.value = true;
          qcProgress.value = { done: st.done || 0, total: st.total || 0 };
          qcLogs.value = (st.logs || []).slice(-20);
          qcPollTimer = setTimeout(pollQualityStatus, 700);
        } else {
          // job 已结束或丢失，清理并 rescan
          localStorage.removeItem("activeQualityTask");
          try {
            const freshData = await scanDirectory(srcDir.value.trim());
            if (freshData && freshData.records) {
              records.value = freshData.records.map((r) => {
                r.tags = normalizeTags(r.tags);
                return r;
              });
            }
          } catch (_) {}
        }
      } catch (_) {}
    };

    const doSave = async () => {
      if (!srcDir.value.trim()) {
        showToast("请先指定图片源目录");
        return;
      }
      if (records.value.length === 0) {
        showToast("当前没有需要保存的打标记录");
        return;
      }
      isSaving.value = true;
      try {
        const res = await saveTags(srcDir.value.trim(), records.value);
        showToast(`已成功保存 tags.json (共 ${res.count} 条记录)`);
      } catch (err) {
        console.error("[保存tags]", err);
        showToast(`保存失败: ${err.message}`);
      } finally {
        isSaving.value = false;
      }
    };

    // 选择控制
    const isSelected = (item) => selectedSet.value.has(item.path);

    // 不可选判定：分辨率不足(长边<1920，导出会被规格化阻断) 或 已导出(导出面板会拦截)。
    // 凡命中此判定的图在选图阶段就置灰，禁止通过任何选择入口(点击/全选/反选/待复核/未导出)入选。
    const isUnselectable = (item) => !!item.too_small_long || !!item.exported;

    const toggleSelect = (item) => {
      // 不可选：分辨率不足或已导出的图直接放弃
      if (isUnselectable(item)) return;
      const next = new Set(selectedSet.value);
      if (next.has(item.path)) {
        next.delete(item.path);
      } else {
        next.add(item.path);
      }
      selectedSet.value = next;
    };

    const selectAllFiltered = () => {
      const next = new Set(selectedSet.value);
      for (const r of filteredRecords.value) {
        if (isUnselectable(r)) continue; // 跳过分辨率不足/已导出
        next.add(r.path);
      }
      selectedSet.value = next;
    };

    const clearSelection = () => {
      selectedSet.value = new Set();
    };

    const invertSelection = () => {
      const next = new Set();
      for (const r of filteredRecords.value) {
        if (isUnselectable(r)) continue; // 跳过分辨率不足/已导出
        if (!selectedSet.value.has(r.path)) {
          next.add(r.path);
        }
      }
      selectedSet.value = next;
    };

    const selectUnreviewedOnly = () => {
      const next = new Set();
      for (const r of filteredRecords.value) {
        if (isUnselectable(r)) continue; // 跳过分辨率不足/已导出
        if (r.review_required || isOthers(r)) {
          next.add(r.path);
        }
      }
      selectedSet.value = next;
      showToast(`已选中 ${next.size} 项待复核图片`);
    };

    const selectUnexportedOnly = () => {
      const next = new Set();
      for (const r of filteredRecords.value) {
        if (isUnselectable(r)) continue; // 跳过分辨率不足(已导出天然 >= 已导出分支)
        if (!r.exported) {
          next.add(r.path);
        }
      }
      selectedSet.value = next;
      showToast(`已选中 ${next.size} 项未导出图片`);
    };

    const formatExportShort = (exp) => {
      if (!exp) return "";
      if (exp.export_type === "main") {
        return exp.order ? `Main #${exp.order}` : "Main";
      }
      if (exp.export_type === "daily") {
        return exp.month ? `Daily ${exp.month}` : "Daily";
      }
      if (exp.export_type === "event") {
        return exp.event_id ? `Event ${exp.event_id}` : "Event";
      }
      if (exp.export_type === "collection") {
        return exp.collection_id ? `Col ${exp.collection_id}` : "Col";
      }
      return exp.export_type || "已导出";
    };

    const getExportTooltip = (exp) => {
      if (!exp) return "";
      const lines = [
        `已导出模块: ${formatExportShort(exp)}`,
        `目标路径: ${exp.target || "-"}`,
        `导出时间: ${exp.exported_at ? exp.exported_at.replace("T", " ").slice(0, 19) : "-"}`,
      ];
      if (exp.hash) {
        lines.push(`SHA-256: ${exp.hash.slice(0, 16)}...`);
      }
      return lines.join("\n");
    };

    // 辅助同步单个 record 的 catalogs
    const updateRecordCatalogs = (item) => {
      item.catalogs = [...normalizeTags(item.tags)];
    };

    // -----------------------------------------------------------------------
    // 用户手动批量增删改 Tags 核心功能
    // -----------------------------------------------------------------------

    const batchSetTag = (targetTag) => {
      if (!targetTag) return;
      if (selectedCount.value === 0) {
        showToast("请先在网格中勾选图片");
        return;
      }
      let count = 0;
      for (const r of records.value) {
        if (selectedSet.value.has(r.path)) {
          // 覆盖为 Others 时保持 ["Others"] 规范形式，review_required 由不变量推导
          applyTags(r, [targetTag], isOthersTag(targetTag));
          count++;
        }
      }
      showToast(`已将 ${count} 张图片的标签覆盖设置为 [${tagZh.value[targetTag] || targetTag}]`);
    };

    const batchAddTag = (targetTag) => {
      if (!targetTag) return;
      if (selectedCount.value === 0) {
        showToast("请先在网格中勾选图片");
        return;
      }
      let count = 0;
      for (const r of records.value) {
        if (selectedSet.value.has(r.path)) {
          let tags = normalizeTags(r.tags);
          if (!tags.includes(targetTag)) {
            // 追加具体标签时自动移除 Others 兜底（两者互斥）
            if (!isOthersTag(targetTag)) {
              tags = tags.filter((t) => !isOthersTag(t));
            }
            tags.push(targetTag);
            applyTags(r, tags);
            count++;
          }
        }
      }
      showToast(`已为 ${count} 张图片追加标签 [${tagZh.value[targetTag] || targetTag}]`);
    };

    const batchRemoveTag = (targetTag) => {
      if (!targetTag) return;
      if (selectedCount.value === 0) {
        showToast("请先在网格中勾选图片");
        return;
      }
      let count = 0;
      for (const r of records.value) {
        if (selectedSet.value.has(r.path)) {
          const before = normalizeTags(r.tags);
          if (!before.includes(targetTag)) continue;
          const tags = before.filter((t) => t !== targetTag);
          // 移空即退回规范兜底桶 ["Others"]（不变量保证非空）
          if (tags.length === 0) {
            applyTags(r, [OTHERS], true);
          } else {
            applyTags(r, tags);
          }
          count++;
        }
      }
      showToast(`已从 ${count} 张图片中移除标签 [${tagZh.value[targetTag] || targetTag}]`);
    };

    const batchClearTags = () => {
      if (selectedCount.value === 0) return;
      for (const r of records.value) {
        if (selectedSet.value.has(r.path)) {
          applyTags(r, [OTHERS], true);
        }
      }
      showToast(`已将选中的 ${selectedCount.value} 张图片重置为 [Others] 并标记待复核`);
    };

    const batchSetReviewed = (isReviewed) => {
      if (selectedCount.value === 0) return;
      for (const r of records.value) {
        if (selectedSet.value.has(r.path)) {
          r.review_required = !isReviewed;
        }
      }
      showToast(
        `已将选中的 ${selectedCount.value} 张图片标记为 [${isReviewed ? "已复核" : "待复核"}]`
      );
    };

    // -----------------------------------------------------------------------
    // 大图查看器 (Viewer) 与单张快捷打标
    // -----------------------------------------------------------------------
    // 删除素材: 软删除至 <SourceDir>/Deleted/ (服务端同侧拦截已导出图片)
    const deleteConfirmOpen = ref(false);
    const isDeletingImage = ref(false);

    const canDeleteViewerItem = computed(
      () => !!currentViewerItem.value && !currentViewerItem.value.exported
    );

    const toggleViewerTag = (tagId) => {
      if (!currentViewerItem.value) return;
      const item = currentViewerItem.value;
      let tags = normalizeTags(item.tags);
      if (tags.includes(tagId)) {
        tags = tags.filter((t) => t !== tagId);
        // 移空即退回规范兜底桶 ["Others"]
        if (tags.length === 0) tags = [OTHERS];
      } else {
        // 追加具体标签时自动移除 Others 兜底（两者互斥）
        if (!isOthersTag(tagId)) {
          tags = tags.filter((t) => !isOthersTag(t));
        }
        tags.push(tagId);
      }
      applyTags(item, tags);
    };

    const toggleViewerReview = () => {
      if (!currentViewerItem.value) return;
      currentViewerItem.value.review_required = !currentViewerItem.value.review_required;
    };

    // -----------------------------------------------------------------------
    // 删除素材 (二次确认 -> 移动至 Deleted/ -> 从列表与数据库移除)
    // -----------------------------------------------------------------------
    const requestDeleteViewerItem = () => {
      const item = currentViewerItem.value;
      if (!item || isDeletingImage.value) return;
      if (item.exported) {
        showToast("已导出的图片不能删除");
        return;
      }
      deleteConfirmOpen.value = true;
    };

    const cancelDeleteViewerItem = () => {
      if (isDeletingImage.value) return;
      deleteConfirmOpen.value = false;
    };

    const confirmDeleteViewerItem = async () => {
      const item = currentViewerItem.value;
      if (!item || isDeletingImage.value) return;
      const dir = srcDir.value.trim();
      if (!dir) {
        showToast("缺少源目录配置，无法删除");
        return;
      }
      if (item.exported) {
        showToast("已导出的图片不能删除");
        deleteConfirmOpen.value = false;
        return;
      }
      // 若在裁切模式中删除，先退出裁切避免 Cropper 实例残留
      if (cropMode.value) exitCropMode(false);

      isDeletingImage.value = true;
      const removedPath = item.path;
      try {
        const res = await deleteImage(dir, removedPath, item.hash || "");
        // 1) 从前端数据列表移除
        records.value = records.value.filter((r) => r.path !== removedPath);
        // 2) 同步清理勾选集合
        if (selectedSet.value.has(removedPath)) {
          const next = new Set(selectedSet.value);
          next.delete(removedPath);
          selectedSet.value = next;
        }
        deleteConfirmOpen.value = false;
        showToast("已删除，文件已移动到 Deleted/ 目录");
        // 3) 修正 viewer 指针：列表空则关闭，越界则收敛到末位
        if (filteredRecords.value.length === 0) {
          closeViewer();
        } else {
          if (viewerIndex.value >= filteredRecords.value.length) {
            viewerIndex.value = filteredRecords.value.length - 1;
          }
          syncViewerImg();
        }
        console.log("[DELETE] 删除成功:", {
          path: removedPath,
          deletedTo: res.deletedTo,
        });
      } catch (err) {
        // 失败时保留确认框，便于用户看到原因后重试
        showToast("删除失败: " + err.message);
        console.error("[DELETE] 删除失败:", removedPath, err);
      } finally {
        isDeletingImage.value = false;
      }
    };

    const openViewer = (item) => {
      const idx = filteredRecords.value.findIndex((r) => r.path === item.path);
      if (idx !== -1) {
        viewerIndex.value = idx;
        viewerModalOpen.value = true;
        syncViewerImg();
      }
    };

    const closeViewer = () => {
      if (cropMode.value) exitCropMode(false);
      viewerModalOpen.value = false;
    };

    // 同步 wrapper 尺寸到 img 实际渲染尺寸，确保 overlay 百分比定位准确
    // 根因：CSS inline-block wrapper 的 max-height: 100% 在 flex 容器内不生效（循环高度依赖），
    // 导致竖图溢出、overlay 百分比错位。改由 JS 设定 img max-height + wrapper 宽高。
    const syncViewerImg = () => {
      nextTick(() => {
        const content = document.querySelector(".viewer-content");
        const img = document.querySelector(".viewer-img");
        const wrapper = document.querySelector(".viewer-img-wrapper");
        if (!content || !img || !wrapper) return;
        // 1. 设定 img max-height = viewer-content 高度，让图片缩放适配
        img.style.maxHeight = content.clientHeight + "px";
        // 2. 等 img 重新布局后，同步 wrapper 尺寸
        requestAnimationFrame(() => {
          const w = img.offsetWidth;
          const h = img.offsetHeight;
          if (w > 0 && h > 0) {
            wrapper.style.width = w + "px";
            wrapper.style.height = h + "px";
          }
        });
      });
    };

    const prevViewer = () => {
      if (cropMode.value) exitCropMode(false);
      if (viewerIndex.value > 0) {
        viewerIndex.value--;
      } else {
        viewerIndex.value = filteredRecords.value.length - 1;
      }
      syncViewerImg();
    };

    const nextViewer = () => {
      if (cropMode.value) exitCropMode(false);
      if (viewerIndex.value < filteredRecords.value.length - 1) {
        viewerIndex.value++;
      } else {
        viewerIndex.value = 0;
      }
      syncViewerImg();
    };

    // -----------------------------------------------------------------------
    // 手动裁切框 (Cropper.js v1) 交互逻辑
    // -----------------------------------------------------------------------
    const initCropper = () => {
      if (typeof window.Cropper === "undefined") {
        showToast("Cropper.js 未加载，请检查网络连接");
        return;
      }
      const img = document.querySelector(".viewer-img");
      if (!img || !img.complete) {
        // 图片未加载完成时等 onload
        img.addEventListener("load", () => initCropper(), { once: true });
        return;
      }
      // 清理旧实例
      if (cropperInstance) {
        try { cropperInstance.destroy(); } catch (_) {}
        cropperInstance = null;
      }
      const opts = {
        viewMode: 1,
        autoCropArea: 0.9,
        movable: true,
        zoomable: false,
        rotatable: false,
        scalable: false,
        background: false,
        responsive: true,
      };
      // 预载已有手动裁切框
      const item = currentViewerItem.value;
      if (item && item.hash) {
        const entry = manualCropCache.value[item.hash];
        if (entry && entry.crop_x0 != null && item.width && item.height) {
          opts.data = {
            x: entry.crop_x0 * item.width,
            y: entry.crop_y0 * item.height,
            width: (entry.crop_x1 - entry.crop_x0) * item.width,
            height: (entry.crop_y1 - entry.crop_y0) * item.height,
          };
        }
      }
      if (cropAspectRatio.value > 0) {
        opts.aspectRatio = cropAspectRatio.value;
      }
      opts.crop = (event) => {
        if (!cropperInstance) return;
        const d = cropperInstance.getData(true);
        cropPixelW.value = Math.round(d.width);
        cropPixelH.value = Math.round(d.height);
      };
      cropperInstance = new window.Cropper(img, opts);
    };

    const enterCropMode = () => {
      if (!currentViewerItem.value) return;
      cropMode.value = true;
      nextTick(() => initCropper());
    };

    const exitCropMode = (save) => {
      if (cropperInstance) {
        if (save) {
          // save 由 saveManualCrop 单独处理, 这里只销毁
        }
        try { cropperInstance.destroy(); } catch (_) {}
        cropperInstance = null;
      }
      cropMode.value = false;
      cropPixelW.value = 0;
      cropPixelH.value = 0;
    };

    const setCropRatio = (ratio) => {
      cropAspectRatio.value = ratio;
      if (cropperInstance) {
        if (ratio > 0) {
          cropperInstance.setAspectRatio(ratio);
        } else {
          cropperInstance.setAspectRatio(NaN);
        }
      }
    };

    const saveManualCrop = async () => {
      if (!cropperInstance || !currentViewerItem.value) return;
      const item = currentViewerItem.value;
      if (!item.hash) {
        showToast("无法获取图片哈希，请重新扫描目录");
        return;
      }
      const data = cropperInstance.getData(true);
      const imgData = cropperInstance.getImageData();
      if (!imgData.naturalWidth || !imgData.naturalHeight) {
        showToast("无法获取图片尺寸");
        return;
      }
      const box = {
        x0: data.x / imgData.naturalWidth,
        y0: data.y / imgData.naturalHeight,
        x1: (data.x + data.width) / imgData.naturalWidth,
        y1: (data.y + data.height) / imgData.naturalHeight,
      };
      // 比例字符串
      let ratioStr = "";
      if (cropAspectRatio.value === 1) ratioStr = "1:1";
      else if (Math.abs(cropAspectRatio.value - 0.75) < 0.01) ratioStr = "3:4";
      else if (Math.abs(cropAspectRatio.value - 1.3333) < 0.01) ratioStr = "4:3";
      else if (cropAspectRatio.value === 0) ratioStr = "free";

      isSavingCrop.value = true;
      console.log("[MANUAL_CROP] saveManualCrop:", {
        hash: item.hash,
        file: item.file,
        naturalW: imgData.naturalWidth,
        naturalH: imgData.naturalHeight,
        cropData: data,
        box,
        ratioStr,
      });
      try {
        const res = await saveManualCropApi(item.hash, box, ratioStr, srcDir.value.trim());
        if (res.ok) {
          manualCropCache.value = {
            ...manualCropCache.value,
            [item.hash]: {
              crop_x0: box.x0, crop_y0: box.y0,
              crop_x1: box.x1, crop_y1: box.y1,
              crop_ratio: ratioStr,
            },
          };
          item.manualCrop = true;
          showToast("裁切框已保存");
          exitCropMode(false);
        }
      } catch (err) {
        showToast("保存失败: " + err.message);
      } finally {
        isSavingCrop.value = false;
      }
    };

    const deleteManualCrop = async () => {
      const item = currentViewerItem.value;
      if (!item || !item.hash) return;
      console.log("[MANUAL_CROP] deleteManualCrop:", { hash: item.hash, file: item.file });
      try {
        const res = await deleteManualCropApi(item.hash, srcDir.value.trim());
        if (res.ok) {
          const next = { ...manualCropCache.value };
          delete next[item.hash];
          manualCropCache.value = next;
          item.manualCrop = false;
          showToast("手动裁切框已删除");
          exitCropMode(false);
        }
      } catch (err) {
        showToast("删除失败: " + err.message);
      }
    };

    // 扫描后拉取手动裁切框缓存
    const fetchManualCropsAfterScan = async () => {
      if (!srcDir.value.trim()) return;
      try {
        const data = await fetchManualCrops(srcDir.value.trim());
        manualCropCache.value = data.overrides || {};
        for (const r of records.value) {
          r.manualCrop = !!(r.hash && manualCropCache.value[r.hash]);
        }
      } catch (err) {
        console.error("[获取手动裁切框]", err);
      }
    };

    // -----------------------------------------------------------------------
    // 资产导出 (Asset Export)
    // -----------------------------------------------------------------------
    const openExport = () => {
      exportSummary.value = "";
      exportLogs.value = [];
      exportProgress.value = "";
      exportDone.value = false;
      exportStep.value = 1;
      exportExcluded.value = new Set(); // 每次新导出会话清空上一次的剔除记录
      exportError.value = "";
      // 仅支持按勾选导出（"全部"已废弃，防止混入未勾选/分辨率不足/已导出的图）
      exportConfig.value.exportScope = "selected";
      lastExportIsTrial.value = false;
      lastTrialDir.value = "";
      exportModalOpen.value = true;
      // 后台预检，自动填充建议序号/版本并预热第二步清单（不阻塞进入第一步）
      loadExportPreview();
    };

    const closeExport = () => {
      if (isExporting.value) return;
      exportModalOpen.value = false;
    };

    // 结果态重新导出（当前 UI 不再暴露；重导=关闭后再打开，函数保留防回归/未来复用）
    const restartExport = () => {
      if (isExporting.value) return;
      exportLogs.value = [];
      exportSummary.value = "";
      exportProgress.value = "";
      exportDone.value = false;
      exportStep.value = 1;
    };

    const goExportStep = async (n) => {
      // 完成态点击步骤条 = 开启新一轮配置，先清空上一次结果
      if (exportDone.value) {
        exportDone.value = false;
        exportLogs.value = [];
        exportSummary.value = "";
        exportProgress.value = "";
      }
      exportError.value = "";
      if (exportType.value === "event" || exportType.value === "collection") {
        if ((n === 2 || n === 3) && !exportConfig.value.title.trim()) {
          showToast("请填写英文标题 (Title)");
          return;
        }
      }
      if (n === 2 || n === 3) {
        await loadExportPreview();
      }
      exportStep.value = n;
    };

    // 输出目录 / HTTP 根地址从主界面移入导出流程后：
    // 填写即记忆(localStorage)，并重跑预检让「建议序号/版本」基于真实产物目录
    const onOutputChange = () => {
      persistConfig();
      exportError.value = "";
      if (exportModalOpen.value && exportStep.value === 3) {
        loadExportPreview();
      }
    };

    const goPrevStep = () => {
      if (isExporting.value) return;
      if (exportStep.value === 1) return;
      if (exportStep.value === 4) { exportStep.value = 1; return; }
      exportStep.value -= 1;
    };

    const toManualSort = () => {
      exportConfig.value.sortBy = "manual";
      goExportStep(2);
    };
    const reverseOrder = () => {
      previewState.value.ordered = [...(previewState.value.ordered || [])].reverse();
      nextTick(rebuildSortable);
    };

    // -----------------------------------------------------------------------
    // 一键随机排序（tag 均分）：同 tag 尽量不相邻、尽量均匀分布，组间按 taxonomy 顺序轮排
    // -----------------------------------------------------------------------
    const randomShuffleOrder = () => {
      const arr = previewState.value.ordered;
      if (!arr || arr.length < 2) return;
      previewState.value.ordered = fairTagShuffle([...arr]);
      exportConfig.value.sortBy = "manual"; // 随机后允许继续手动拖拽/↑↓调整
      nextTick(rebuildSortable);
      showToast(`已按标签均匀打乱 (${previewState.value.ordered.length} 张)，可继续手动调整`);
    };

    // 主标签：优先取首个真实标签，没有则视为 Others 兜底桶
    // 欠账优先贪心混排：
    //   每个 tag 的目标份额 = pos/N × count，谁「欠得最多」谁下一个出列（同分按 taxonomy 顺序破平），
    //   且不连续放同一 tag（除非只剩它可选）。结果满足：同 tag 尽量不相邻、数量悬殊也均匀分布；
    //   首个位置强制从 taxonomy 顺序第一个非空组开始，保证观感顺序。
    const fairTagShuffle = (items) => {
      const N = items.length;
      const groups = new Map();
      const tagIdx = new Map((mainTags.value || []).map((t, i) => [t.id, i]));
      for (const it of items) {
        const real = (it.tags || []).find((t) => !isOthersTag(t));
        const tag = real || OTHERS;
        if (!groups.has(tag)) groups.set(tag, []);
        groups.get(tag).push(it);
      }
      // 组内洗牌 (Fisher-Yates)
      for (const g of groups.values()) {
        for (let i = g.length - 1; i > 0; i--) {
          const j = Math.floor(Math.random() * (i + 1));
          [g[i], g[j]] = [g[j], g[i]];
        }
      }
      // 组序：按 taxonomy 顺序，Others 恒在最后，未知名标签排在 Others 前
      const keys = [...groups.keys()].sort((a, b) => {
        const ia = tagIdx.has(a) ? tagIdx.get(a) : 1e6 - 1;
        const ib = tagIdx.has(b) ? tagIdx.get(b) : 1e6 - 1;
        return ia - ib;
      });
      const cycle = keys.filter((k) => k !== OTHERS);
      if (groups.has(OTHERS)) cycle.push(OTHERS);
      if (!cycle.length) return [...items];

      const count = new Map(cycle.map((k) => [k, groups.get(k).length]));
      const placed = new Map(cycle.map((k) => [k, 0]));
      const out = [];

      // 强制头部：taxonomy 顺序的第一个非空组
      const head = cycle.find((k) => count.get(k) > 0);
      out.push(head);
      count.set(head, count.get(head) - 1);
      placed.set(head, placed.get(head) + 1);

      for (let pos = 1; pos < N; pos++) {
        const cand = [];
        cycle.forEach((k, ki) => {
          if (count.get(k) <= 0) return;
          // 欠账 = 理论应出数量 - 已出数量（同分让 taxonomy 更靠前的组先出）
          const deficit = ((pos + 1) / N) * groups.get(k).length - placed.get(k);
          cand.push({ k, deficit, ki });
        });
        cand.sort((a, b) => b.deficit - a.deficit || a.ki - b.ki);
        let pick = cand[0];
        const prev = out[out.length - 1];
        // 避免与上一个同 tag；若还有别的组可选就换次优组
        if (pick && pick.k === prev && cand.length > 1) {
          const alt = cand.find((c) => c.k !== prev);
          if (alt) pick = alt;
        }
        out.push(pick.k);
        count.set(pick.k, count.get(pick.k) - 1);
        placed.set(pick.k, placed.get(pick.k) + 1);
      }

      // 按生成的 tag 顺序取出各组图片
      const seqTags = out;
      const ptr = new Map(cycle.map((k) => [k, 0]));
      return seqTags.map((tag) => {
        const g = groups.get(tag);
        const item = g[ptr.get(tag)];
        ptr.set(tag, ptr.get(tag) + 1);
        return item;
      });
    };
    const moveExportItem = (i, dir) => {
      const arr = previewState.value.ordered;
      if (!arr) return;
      const j = i + dir;
      if (j < 0 || j >= arr.length) return;
      const tmp = arr[i]; arr[i] = arr[j]; arr[j] = tmp;
      previewState.value.ordered = [...arr];
    };

    // 按当前 ordered 重算统计（剔除单张后保持 KPI/分布与清单同口径）
    const recalcPreviewStats = () => {
      const arr = previewState.value.ordered || [];
      const s = previewState.value.stats || {};
      const tags = {};
      const dirs = {};
      let sourceBytes = 0;
      let already = 0;
      for (const it of arr) {
        sourceBytes += Number(it.size || 0);
        if (it.isExported) already++;
        const tagList = it.tags && it.tags.length ? it.tags : [OTHERS];
        for (const tg of tagList) tags[tg] = (tags[tg] || 0) + 1;
        const d = it.dir || "(根目录)";
        dirs[d] = (dirs[d] || 0) + 1;
      }
      previewState.value.stats = {
        ...s,
        total: arr.length,
        sourceBytes,
        estWebpBytes: Math.round(sourceBytes * (Number(previewState.value.estRatio) || 0.2)),
        tags,
        dirs,
        alreadyExported: already,
      };
    };

    const removeFromPreview = (i) => {
      const arr = previewState.value.ordered;
      if (!arr) return;
      const it = arr[i];
      if (it && it.rel) {
        const next = new Set(exportExcluded.value);
        next.add(it.rel);
        exportExcluded.value = next;
      }
      previewState.value.ordered = arr.filter((_, idx) => idx !== i);
      recalcPreviewStats();
      nextTick(rebuildSortable);
    };

    // -----------------------------------------------------------------------
    // 缩略图网格拖拽排序 (SortableJS)
    // -----------------------------------------------------------------------
    let sortable = null;
    const destroySortable = () => {
      if (sortable) { try { sortable.destroy(); } catch (_) {} sortable = null; }
    };
    const rebuildSortable = () => {
      destroySortable();
      if (exportStep.value !== 2) return;
      if (exportConfig.value.sortBy !== "manual") return;
      const el = orderGridEl.value;
      if (!el || typeof window.Sortable === "undefined") return;
      sortable = window.Sortable.create(el, {
        animation: 150,
        ghostClass: "sortable-ghost",
        chosenClass: "sortable-chosen",
        onEnd(evt) {
          const arr = previewState.value.ordered;
          if (!arr || evt.oldIndex == null || evt.newIndex == null) return;
          const moved = arr.splice(evt.oldIndex, 1)[0];
          arr.splice(evt.newIndex, 0, moved);
          previewState.value.ordered = [...arr];
        },
      });
    };

    // 进入第二步 / 切换排序方式 / 预检重建列表 时同步拖拽
    watch(
      [exportStep, () => exportConfig.value.sortBy, () => (previewState.value.ordered || []).length],
      () => {
        nextTick(rebuildSortable);
      },
    );

    // 切换导出范围后清单完全不同，剔除记录一并作废
    watch(
      () => exportConfig.value.exportScope,
      () => {
        exportExcluded.value = new Set();
      },
    );

    const startExport = async () => {
      // 纯前端防呆：试导出直接执行；正式导出必须先过二次确认弹窗
      if (exportConfig.value.trial) {
        await runExport();
      } else {
        formalConfirmChecked.value = false;
        confirmFormalOpen.value = true;
      }
    };

    const confirmFormalExport = async () => {
      confirmFormalOpen.value = false;
      await runExport();
    };

    const runExport = async () => {
      // 必填校验：错误在第③步红条持久展示（不再只有一闪而过的 toast）
      exportError.value = "";
      if (!srcDir.value.trim()) {
        exportError.value = "图片源目录为空：请回到主界面填写源目录后再导出。";
        showToast("导出中止：未填写图片源目录");
        return;
      }
      if (!outDir.value.trim()) {
        exportError.value = "输出目录为空：导出前请先在上方填写 输出目录 (Output Directory)。";
        showToast("导出中止：未填写输出目录");
        return;
      }
      // 仅支持按勾选导出：必须先在素材库勾选要导出的图片
      if (selectedSet.value.size === 0) {
        exportError.value = "未勾选任何图片：请在素材库中勾选要导出的图片后再导出（分辨率不足/已导出的图已置灰不可选）。";
        showToast("导出中止：未勾选任何图片");
        return;
      }
      if ((exportType.value === "event" || exportType.value === "collection") && !exportConfig.value.title.trim()) {
        exportError.value = "缺少英文标题：Event / Collection 导出前请填写英文标题 (Title)。";
        showToast("导出中止：请填写英文标题 (Title)");
        return;
      }
      persistConfig();
      isExporting.value = true;
      exportLogs.value = [];
      exportSummary.value = "";
      exportProgress.value = "";
      exportDone.value = false;
      lastExportIsTrial.value = Boolean(exportConfig.value.trial);
      lastTrialDir.value = "";

      // 进度感知：前端生成任务 id；POST 与状态轮询并行，
      // 任一通道先到达终态即收尾 (finalize 幂等，后到者忽略)
      const taskId =
        "exp_" + Date.now().toString(36) + "_" + Math.random().toString(36).slice(2, 10);
      let finalized = false;
      let pollTimer = null;

      const stopPolling = () => {
        if (pollTimer !== null) {
          clearTimeout(pollTimer);
          pollTimer = null;
        }
      };

      const rescanAfterSuccess = async () => {
        try {
          const freshData = await scanDirectory(srcDir.value.trim());
          if (freshData && freshData.records) {
            records.value = freshData.records.map((r) => {
              r.tags = normalizeTags(r.tags);
              return r;
            });
          }
        } catch (_) {
          // ignore
        }
      };

      const finalize = (success, info) => {
        if (finalized) return;
        finalized = true;
        stopPolling();
        isExporting.value = false;
        exportDone.value = true; // 完成后停留第③步预览视图，不跳转、不刷新统计
        if (success) {
          exportSummary.value = (info && info.summary) || "导出完成";
          lastExportIsTrial.value = Boolean(info && info.isTrial);
          lastTrialDir.value = (info && info.trialDir) || lastTrialDir.value;
          if (info && info.isTrial) {
            showToast("试导出完成：未写入账本/ID/清单，未部署");
          } else {
            showToast("导出成功！");
          }
          // 试导出不触碰账本，跳过重新扫描，避免用户误以为失败
          if (!(info && info.skipRescan)) {
            rescanAfterSuccess();
          }
        } else {
          const msg = (info && info.error) || "导出失败";
          exportSummary.value = "";
          exportLogs.value = (info && info.logs) || exportLogs.value;
          showToast(`导出失败: ${msg}`);
        }
      };

      const pollStatus = async () => {
        let st = null;
        try {
          st = await fetchJobStatus(taskId);
        } catch (_) {
          return; // 网络错误：静默停止轮询，POST 自身结果兜底
        }
        if (!st || !st.found || finalized) return; // 任务不存在/已收尾：静默停止
        if (st.state === "done") {
          finalize(true, {
            summary: st.summary,
            isTrial: lastExportIsTrial.value,
            skipRescan: lastExportIsTrial.value,
          });
          return;
        }
        if (st.state === "error") {
          finalize(false, { error: st.error || "导出失败", logs: st.logs });
          return;
        }
        if (Array.isArray(st.logs) && st.logs.length) exportLogs.value = st.logs;
        exportProgress.value =
          typeof st.total === "number" && st.total > 0 ? `${st.done}/${st.total}` : "";
        pollTimer = setTimeout(pollStatus, 700);
      };
      pollTimer = setTimeout(pollStatus, 150);

      const payload = {
        clientTaskId: taskId,
        type: exportType.value,
        srcDir: srcDir.value.trim(),
        outDir: outDir.value.trim(),
        httpBase: httpBase.value.trim(),
        format: exportConfig.value.format,
        rename: exportConfig.value.rename,
        quality: exportConfig.value.quality,
        targetRatios: exportConfig.value.targetRatios || ["auto"],
        cropMode: exportConfig.value.cropMode || "smart",
        sortBy: exportConfig.value.sortBy,
        startOrder: parseInt(exportConfig.value.startOrder || 1, 10),
        version: exportConfig.value.version,
        month: exportConfig.value.month,
        eventId: exportConfig.value.eventId,
        collectionId: exportConfig.value.collectionId,
        title: exportConfig.value.title.trim(),
        titleZh: exportConfig.value.titleZh.trim(),
        description: exportConfig.value.description.trim(),
        descZh: exportConfig.value.descZh.trim(),
        displayOrder: exportConfig.value.displayOrder,
        status: exportConfig.value.status,
        outputMode: exportConfig.value.outputMode,
        excludeExported: Boolean(exportConfig.value.excludeExported),
        selectedPaths:
          exportConfig.value.exportScope === "selected" && selectedSet.value.size > 0
            ? Array.from(selectedSet.value)
            : undefined,
        manualOrder:
          exportConfig.value.sortBy === "manual" && previewState.value.ordered?.length
            ? previewState.value.ordered.map((o) => o.rel)
            : undefined,
        excludedPaths: exportExcluded.value.size ? Array.from(exportExcluded.value) : undefined,
        trial: Boolean(exportConfig.value.trial),
        tagsRecords: buildSlimRecords(),
      };

      try {
        const res = await executeExport(payload);
        if (!finalized) {
          if (res && res.ok) {
            if (res.trial) {
              lastExportIsTrial.value = true;
              lastTrialDir.value = res.trialDir || "";
              finalize(true, { summary: res.summary, skipRescan: true, isTrial: true, trialDir: res.trialDir || "" });
            } else {
              lastExportIsTrial.value = false;
              lastTrialDir.value = "";
              finalize(true, { summary: res.summary });
            }
          } else {
            finalize(false, {
              error: (res && res.error) || "导出失败",
              logs: res && res.logs,
            });
          }
        }
      } catch (err) {
        console.error("[导出]", err);
        if (!finalized) {
          finalize(false, {
            error: err.message,
            logs:
              err.logs ||
              [{ t: new Date().toLocaleTimeString(), level: "err", msg: err.message }],
          });
        }
      }
    };

    const copyExportLogs = () => {
      const text = exportLogs.value.map((l) => `[${l.t}] [${l.level}] ${l.msg}`).join("\n");
      navigator.clipboard.writeText(text);
      showToast("已复制导出日志到剪贴板");
    };

    // -----------------------------------------------------------------------
    // 服务端连通状态与心跳监测
    // -----------------------------------------------------------------------
    const serverOnline = ref(true);
    const isCheckingServer = ref(false);
    const thumbEpoch = ref(0);
    let consecutiveFailures = 0;
    let imgErrorTimer = null;

    const checkServerHealth = async (interactive = false) => {
      if (isCheckingServer.value) return;
      isCheckingServer.value = true;
      try {
        const isUp = await checkHealth(4000);
        const wasOnline = serverOnline.value;
        if (isUp) {
          consecutiveFailures = 0;
          serverOnline.value = true;
          if (!wasOnline) {
            showToast("服务端连接已恢复！");
            thumbEpoch.value = Date.now();
          } else if (interactive) {
            showToast("服务端运行正常 (连接畅通)");
          }
        } else {
          consecutiveFailures++;
          // 连续两次检测超时/失败才判定离线，消除瞬时高并发或网络抖动误报
          if (consecutiveFailures >= 2) {
            serverOnline.value = false;
            if (wasOnline) {
              showToast("警告：与本地服务端断开连接！");
            }
          }
        }
      } finally {
        isCheckingServer.value = false;
      }
    };

    const handleImageError = () => {
      // 防抖触发健康检测，避免大量缩略图并发加载慢时引发重复无意义请求
      if (serverOnline.value) {
        if (imgErrorTimer) clearTimeout(imgErrorTimer);
        imgErrorTimer = setTimeout(() => {
          checkServerHealth();
        }, 800);
      }
    };

    // -----------------------------------------------------------------------
    // 键盘快捷键监听
    // -----------------------------------------------------------------------
    onMounted(async () => {
      checkServerHealth();
      setInterval(() => {
        checkServerHealth();
      }, 3000);

      try {
        const tax = await fetchTaxonomy();
        mainTags.value = tax.main_tags || tax.tags || tax.catalogs || [];
        catalogs.value = mainTags.value;
        specificTags.value = mainTags.value;
        tagZh.value = tax.tag_zh || {};
        catalogToTags.value = tax.catalog_to_tags || {};
        tagToCatalogs.value = tax.tag_to_catalogs || {};
      } catch (err) {
        console.error("[初始化分类体系]", err);
        if (window.TAXONOMY && window.TAXONOMY.main_tags) {
          mainTags.value = window.TAXONOMY.main_tags || [];
          catalogs.value = mainTags.value;
          specificTags.value = mainTags.value;
          tagZh.value = window.TAXONOMY.tag_zh || {};
        } else {
          showToast(`初始化分类体系失败: ${err.message}`);
        }
      }

      window.addEventListener("keydown", (e) => {
        // 如果在输入框中，不触发全局快捷键
        if (["INPUT", "TEXTAREA", "SELECT"].includes(e.target.tagName)) return;

        if (e.key === "Escape") {
          if (deleteConfirmOpen.value) {
            cancelDeleteViewerItem();
          } else if (viewerModalOpen.value) {
            closeViewer();
          } else if (exportModalOpen.value) {
            closeExport();
          } else if (selectedCount.value > 0) {
            clearSelection();
          }
        } else if (viewerModalOpen.value) {
          if (e.key === "ArrowLeft") prevViewer();
          if (e.key === "ArrowRight") nextViewer();
          // Delete 快捷键：同样走二次确认，裁切模式下不触发避免误删
          if (e.key === "Delete" && !deleteConfirmOpen.value && !cropMode.value) {
            e.preventDefault();
            requestDeleteViewerItem();
          }
        } else if (e.ctrlKey && e.key.toLowerCase() === "a") {
          e.preventDefault();
          selectAllFiltered();
        }
      });

      // 窗口缩放时同步 viewer 图片尺寸
      window.addEventListener("resize", () => {
        if (viewerModalOpen.value) syncViewerImg();
      });

      // 尝试恢复未完成的质检任务
      resumeQualityJob();
    });

    const thumbUrl = (path, size = 360) => {
      const base = getThumbUrl(path, size, srcDir.value);
      return thumbEpoch.value ? `${base}&_e=${thumbEpoch.value}` : base;
    };
    const fileUrl = (path) => getFileUrl(path, srcDir.value);
    const formatFileSize = (bytes) => {
      if (!bytes || bytes <= 0) return "";
      if (bytes < 1024) return bytes + " B";
      if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
      return (bytes / (1024 * 1024)).toFixed(1) + " MB";
    };
    const getSubDir = (path) => {
      if (!path) return "";
      const s = String(path).replace(/\\/g, "/");
      const idx = s.lastIndexOf("/");
      if (idx === -1) return "";
      return s.substring(0, idx);
    };

    return {
      formatFileSize,
      getSubDir,
      serverOnline,
      isCheckingServer,
      checkServerHealth,
      handleImageError,
      viewerIndex,
      mainTags,
      mainTagsRow1,
      mainTagsRow2,
      tagIcon,
      tagDesc,
      catalogs,
      specificTags,
      tagZh,
      srcDir,
      outDir,
      httpBase,
      records,
      selectedSet,
      isScanning,
      isSaving,
      activeTag,
      onlyUnreviewed,
      hideExported,
      onlyDuplicates,
      duplicateCount,
      duplicateGroupsCount,
      searchQuery,
      sortBy,
      sortOrder,
      cardZoom,
      tagCounts,
      unreviewedCount,
      exportedCount,
      unexportedCount,
      smallLongCount,
      filteredRecords,
      selectedCount,
      isAllFilteredSelected,
      batchTagTarget,
      exportModalOpen,
      exportType,
      exportConfig,
      hasDuplicateInExportScope,
      isExporting,
      exportLogs,
      exportSummary,
      exportProgressText,
      exportDone,
      exportStep,
      orderGridEl,
      exportExcluded,
      previewLoading,
      previewError,
      previewOrdered,
      previewStats,
      suggestedStartHint,
      suggestedMaxOrder,
      suggestedVersion,
      suggestedStartForList,
      suggestedMaxForList,
      fmtBytes,
      hbarWidth,
      goExportStep,
      goPrevStep,
      toManualSort,
      reverseOrder,
      randomShuffleOrder,
      moveExportItem,
      removeFromPreview,
      restartExport,
      onOutputChange,
      exportError,
      persistConfig,
      resetStartOrderForType,
      viewerModalOpen,
      currentViewerItem,
      cropOverlayStyle,
      toast,
      getThumbUrl: thumbUrl,
      getFileUrl: fileUrl,
      doScan,
      doSave,
      isSelected,
      toggleSelect,
      selectAllFiltered,
      clearSelection,
      invertSelection,
      selectUnreviewedOnly,
      selectUnexportedOnly,
      formatExportShort,
      getExportTooltip,
      batchSetTag,
      batchAddTag,
      batchRemoveTag,
      batchClearTags,
      batchSetReviewed,
      openViewer,
      closeViewer,
      syncViewerImg,
      prevViewer,
      nextViewer,
      toggleViewerTag,
      toggleViewerReview,
      deleteConfirmOpen,
      isDeletingImage,
      canDeleteViewerItem,
      requestDeleteViewerItem,
      cancelDeleteViewerItem,
      confirmDeleteViewerItem,
      openExport,
      closeExport,
      runExport,
      startExport,
      confirmFormalExport,
      confirmFormalOpen,
      formalConfirmChecked,
      lastExportIsTrial,
      lastTrialDir,
      copyExportLogs,
      filterGrade,
      filterScoreMin,
      filterScoreMax,
      filterUpgradeable,
      isEvaluatingQuality,
      isBatchEvaluating,
      qualitySummary,
      unscoredCount,
      scoredCount,
      evalSingleQuality,
      triggerBatchQuality,
      cancelQuality,
      resumeQualityJob,
      qcTaskId,
      qcProgress,
      qcProgressPercent,
      qcLogs,
      hasRatio,
      toggleRatio,
      isUnselectable,
      // 手动裁切框
      cropMode,
      cropAspectRatio,
      isSavingCrop,
      cropPixelText,
      hasManualCrop,
      manualCropOverlayStyle,
      manualCropRatio,
      enterCropMode,
      exitCropMode,
      setCropRatio,
      saveManualCrop,
      deleteManualCrop,
    };
  },
});

app.config.errorHandler = (err, vm, info) => {
  console.error('[Studio Vue Error]:', err, info);
  if (typeof window.renderFatalError === 'function') {
    window.renderFatalError(err ? (err.message || String(err)) : 'Vue Component Error', 'VueComponent', 0, 0, err);
  }
};

window.__STUDIO_VM__ = app.mount("#app");
