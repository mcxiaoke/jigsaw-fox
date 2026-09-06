/**
 * studio.static.js.app — Content Studio Vue 3 主应用逻辑
 */

import {
  batchEvaluateQuality,
  checkHealth,
  executeExport,
  fetchQuality,
  fetchQualityStats,
  fetchTags,
  fetchTaxonomy,
  getFileUrl,
  getThumbUrl,
  saveTags,
  scanDirectory,
} from "./api.js";

const { createApp, ref, computed, onMounted, watch } = window.Vue;

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
      rename: "none",
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
    });
    const isExporting = ref(false);
    const exportLogs = ref([]);
    const exportSummary = ref("");

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

    // 标签统计计数 (Others 是未分类/无标签素材的虚拟 filter 集合)
    const tagCounts = computed(() => {
      const map = {};
      let othersCount = 0;
      for (const r of records.value) {
        const realTags = (r.tags || []).filter((t) => t.toLowerCase() !== "others");
        if (realTags.length === 0) {
          othersCount++;
        }
        for (const t of realTags) {
          map[t] = (map[t] || 0) + 1;
        }
      }
      map["Others"] = othersCount;
      return map;
    });

    // 待复核总数 (含无真实标签与标记待复核的素材)
    const unreviewedCount = computed(() => {
      let cnt = 0;
      for (const r of records.value) {
        const isUntagged = !r.tags || r.tags.length === 0 || r.tags.every((t) => t.toLowerCase() === "others");
        if (r.review_required || isUntagged) {
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

      // 1. Tag 过滤 (Others 对应无真实标签的集合)
      if (activeTag.value) {
        if (activeTag.value.toLowerCase() === "others") {
          list = list.filter((r) => !r.tags || r.tags.length === 0 || r.tags.every((t) => t.toLowerCase() === "others"));
        } else {
          list = list.filter((r) => r.tags && r.tags.includes(activeTag.value));
        }
      }

      // 2. 待复核过滤
      if (onlyUnreviewed.value) {
        list = list.filter(
          (r) => r.review_required || !r.tags || r.tags.length === 0 || r.tags.every((t) => t.toLowerCase() === "others")
        );
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
        records.value = res.records || [];
        selectedSet.value.clear();
        if (res.stats && res.stats.qualitySummary) {
          qualitySummary.value = res.stats.qualitySummary;
        } else {
          refreshQualitySummary();
        }
        showToast(`扫描成功: 共发现 ${res.total || records.value.length} 张图片`);
      } catch (err) {
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
        if (r.review_required || (r.tags && r.tags.some((t) => t.toLowerCase() === "others"))) {
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
      item.catalogs = item.tags && item.tags.length > 0 ? [...item.tags] : ["Others"];
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
          r.tags = [targetTag];
          r.catalogs = [targetTag];
          r.review_required = targetTag.toLowerCase() === "others";
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
          let tags = r.tags || [];
          if (!tags.includes(targetTag)) {
            // 如果追加的是具体标签，自动移除 'Others' / 'others' 兜底
            if (targetTag.toLowerCase() !== "others") {
              tags = tags.filter((t) => t.toLowerCase() !== "others");
            }
            tags.push(targetTag);
            r.tags = tags;
            r.catalogs = tags;
            r.review_required = tags.some((t) => t.toLowerCase() === "others");
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
          let tags = r.tags || [];
          if (tags.includes(targetTag)) {
            tags = tags.filter((t) => t !== targetTag);
            if (tags.length === 0) {
              tags = ["Others"];
              r.review_required = true;
            }
            r.tags = tags;
            r.catalogs = tags;
            count++;
          }
        }
      }
      showToast(`已从 ${count} 张图片中移除标签 [${tagZh.value[targetTag] || targetTag}]`);
    };

    const batchClearTags = () => {
      if (selectedCount.value === 0) return;
      for (const r of records.value) {
        if (selectedSet.value.has(r.path)) {
          r.tags = ["Others"];
          r.catalogs = ["Others"];
          r.review_required = true;
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
      let tags = [...(item.tags || [])];
      if (tags.includes(tagId)) {
        tags = tags.filter((t) => t !== tagId);
        if (tags.length === 0) tags = ["Others"];
      } else {
        if (tagId.toLowerCase() !== "others") {
          tags = tags.filter((t) => t.toLowerCase() !== "others");
        }
        tags.push(tagId);
      }
      item.tags = tags;
      item.catalogs = tags;
      item.review_required = tags.some((t) => t.toLowerCase() === "others");
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
      exportModalOpen.value = true;
    };

    const closeExport = () => {
      if (isExporting.value) return;
      exportModalOpen.value = false;
    };

    const runExport = async () => {
      if (!srcDir.value.trim() || !outDir.value.trim()) {
        showToast("请填写源目录和输出目录");
        return;
      }
      if ((exportType.value === "event" || exportType.value === "collection") && !exportConfig.value.title.trim()) {
        showToast("请填写英文标题 (Title)");
        return;
      }
      persistConfig();
      isExporting.value = true;
      exportLogs.value = [];
      exportSummary.value = "";

      const payload = {
        type: exportType.value,
        srcDir: srcDir.value.trim(),
        outDir: outDir.value.trim(),
        httpBase: httpBase.value.trim(),
        format: exportConfig.value.format,
        rename: exportConfig.value.rename,
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
        tagsRecords: records.value,
      };

      try {
        const res = await executeExport(payload);
        exportLogs.value = res.logs || [];
        exportSummary.value = res.summary || "导出完成";
        showToast("导出成功！");

        // 重新拉取以实时刷新卡片的已导出角标与统计计数
        try {
          const freshData = await scanDirectory(srcDir.value.trim());
          if (freshData && freshData.records) {
            records.value = freshData.records;
          }
        } catch (_) {
          // ignore
        }
      } catch (err) {
        exportLogs.value = err.logs || [
          { t: new Date().toLocaleTimeString(), level: "err", msg: err.message },
        ];
        showToast(`导出失败: ${err.message}`);
      } finally {
        isExporting.value = false;
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
