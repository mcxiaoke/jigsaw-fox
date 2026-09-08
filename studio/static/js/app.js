/**
 * studio.static.js.app — Content Studio Vue 3 主应用逻辑
 */

import {
  batchEvaluateQuality,
  checkHealth,
  executeExport,
  fetchExportStatus,
  fetchQuality,
  fetchQualityStats,
  fetchTags,
  fetchTaxonomy,
  getFileUrl,
  getThumbUrl,
  previewExport,
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
      startOrder: 101,
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
      if (activeTag.value) {
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

    const triggerBatchQuality = async () => {
      if (!srcDir.value.trim()) {
        showToast("请先指定图片源目录");
        return;
      }
      const unscored = records.value.filter((r) => !r.quality);
      if (unscored.length === 0) {
        showToast("当前所有图片均已完成质检评分");
        return;
      }

      isBatchEvaluating.value = true;
      showToast(`开始批量质检 (待评: ${unscored.length} 张)...`);
      try {
        const res = await batchEvaluateQuality(srcDir.value.trim(), 30);
        if (res.items && res.items.length > 0) {
          const map = new Map(res.items.map((it) => [it.path, it.quality]));
          for (const r of records.value) {
            if (map.has(r.path)) {
              r.quality = map.get(r.path);
            }
          }
          if (res.stats) {
            qualitySummary.value = res.stats;
          } else {
            refreshQualitySummary();
          }
          showToast(`批量质检完成: 成功评估 ${res.items.length} 张图片`);
        } else {
          showToast("没有更多待质检的图片");
        }
      } catch (err) {
        console.error("[批量质检]", err);
        showToast(`批量质检异常: ${err.message}`);
      } finally {
        isBatchEvaluating.value = false;
      }
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

    const toggleSelect = (item) => {
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
        if (!selectedSet.value.has(r.path)) {
          next.add(r.path);
        }
      }
      selectedSet.value = next;
    };

    const selectUnreviewedOnly = () => {
      const next = new Set();
      for (const r of filteredRecords.value) {
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
    const openViewer = (item) => {
      const idx = filteredRecords.value.findIndex((r) => r.path === item.path);
      if (idx !== -1) {
        viewerIndex.value = idx;
        viewerModalOpen.value = true;
      }
    };

    const closeViewer = () => {
      viewerModalOpen.value = false;
    };

    const prevViewer = () => {
      if (viewerIndex.value > 0) {
        viewerIndex.value--;
      } else {
        viewerIndex.value = filteredRecords.value.length - 1;
      }
    };

    const nextViewer = () => {
      if (viewerIndex.value < filteredRecords.value.length - 1) {
        viewerIndex.value++;
      } else {
        viewerIndex.value = 0;
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
      // 若已在浏览页勾选图片，默认只导出选中的那几张，而非全部
      exportConfig.value.exportScope = selectedSet.value.size > 0 ? "selected" : "all";
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
          st = await fetchExportStatus(taskId);
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
        sortBy: exportConfig.value.sortBy,
        startOrder: parseInt(exportConfig.value.startOrder || 101, 10),
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
          if (viewerModalOpen.value) {
            closeViewer();
          } else if (exportModalOpen.value) {
            closeExport();
          } else if (selectedCount.value > 0) {
            clearSelection();
          }
        } else if (viewerModalOpen.value) {
          if (e.key === "ArrowLeft") prevViewer();
          if (e.key === "ArrowRight") nextViewer();
        } else if (e.ctrlKey && e.key.toLowerCase() === "a") {
          e.preventDefault();
          selectAllFiltered();
        }
      });
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
      prevViewer,
      nextViewer,
      toggleViewerTag,
      toggleViewerReview,
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
      isEvaluatingQuality,
      isBatchEvaluating,
      qualitySummary,
      unscoredCount,
      scoredCount,
      evalSingleQuality,
      triggerBatchQuality,
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
