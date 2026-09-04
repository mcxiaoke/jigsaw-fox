/**
 * studio.static.js.app — Content Studio Vue 3 主应用逻辑
 */

import {
  checkHealth,
  executeExport,
  fetchTags,
  fetchTaxonomy,
  getFileUrl,
  getThumbUrl,
  saveTags,
  scanDirectory,
} from "./api.js";

const { createApp, ref, computed, onMounted, watch } = window.Vue;

createApp({
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
    const searchQuery = ref("");
    const sortBy = ref("name"); // 'name' | 'mtime' | 'confidence'
    const sortOrder = ref("asc");
    const cardZoom = ref(190);

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
      description: "",
      displayOrder: 1,
      status: "active",
      outputMode: "zip",
    });
    const isExporting = ref(false);
    const exportLogs = ref([]);
    const exportSummary = ref("");

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

    // 标签统计计数
    const tagCounts = computed(() => {
      const map = {};
      for (const r of records.value) {
        for (const t of r.tags || []) {
          map[t] = (map[t] || 0) + 1;
        }
      }
      return map;
    });

    // 待复核总数 (含 Others 兜底)
    const unreviewedCount = computed(() => {
      let cnt = 0;
      for (const r of records.value) {
        if (r.review_required || (r.tags && r.tags.some((t) => t.toLowerCase() === "others"))) {
          cnt++;
        }
      }
      return cnt;
    });

    // 过滤后的卡片列表
    const filteredRecords = computed(() => {
      let list = records.value;

      // 1. Tag 过滤
      if (activeTag.value) {
        list = list.filter((r) => r.tags && r.tags.includes(activeTag.value));
      }

      // 2. 待复核过滤
      if (onlyUnreviewed.value) {
        list = list.filter(
          (r) => r.review_required || (r.tags && r.tags.some((t) => t.toLowerCase() === "others"))
        );
      }

      // 4. 搜索关键词过滤
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

      // 5. 排序
      list = [...list].sort((a, b) => {
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
        showToast(`扫描成功: 共发现 ${res.total || records.value.length} 张图片`);
      } catch (err) {
        showToast(`扫描失败: ${err.message}`);
      } finally {
        isScanning.value = false;
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
        title: exportConfig.value.title,
        description: exportConfig.value.description,
        displayOrder: exportConfig.value.displayOrder,
        status: exportConfig.value.status,
        outputMode: exportConfig.value.outputMode,
        tagsRecords: records.value,
      };

      try {
        const res = await executeExport(payload);
        exportLogs.value = res.logs || [];
        exportSummary.value = res.summary || "导出完成";
        showToast("导出成功！");
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

    const checkServerHealth = async (interactive = false) => {
      if (isCheckingServer.value) return;
      isCheckingServer.value = true;
      try {
        const isUp = await checkHealth(2500);
        const wasOnline = serverOnline.value;
        serverOnline.value = isUp;
        if (!wasOnline && isUp) {
          showToast("服务端连接已恢复！");
          thumbEpoch.value = Date.now();
        } else if (wasOnline && !isUp) {
          showToast("警告：与本地服务端断开连接！");
        } else if (interactive && isUp) {
          showToast("服务端运行正常 (连接畅通)");
        }
      } finally {
        isCheckingServer.value = false;
      }
    };

    const handleImageError = () => {
      if (serverOnline.value) {
        checkServerHealth();
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

    return {
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
      searchQuery,
      sortBy,
      cardZoom,
      tagCounts,
      unreviewedCount,
      filteredRecords,
      selectedCount,
      isAllFilteredSelected,
      batchTagTarget,
      exportModalOpen,
      exportType,
      exportConfig,
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
    };
  },
}).mount("#app");
