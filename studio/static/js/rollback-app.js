/* rollback-app.js — 导出回滚与台账独立页面（Vue 3，不依赖主页面 app.js） */
/* 约定：所有记录字段一律文本插值，禁止 v-html（保持 XSS 防护水位） */
(function () {
  "use strict";

  const { createApp, ref, computed, onMounted } = Vue;

  createApp({
    setup() {
      // ---- 目录与加载 ----
      const dirInput = ref("");
      const loading = ref(false);
      const inited = ref(false);

      // ---- 台账数据 ----
      const ops = ref([]);
      const legacyCount = ref(0);
      const totalRecords = ref(0);
      const auditEvents = ref([]);
      const backups = ref([]);
      const tab = ref("ops");

      // ---- 筛选 ----
      const moduleFilter = ref("");
      const kw = ref("");
      const allModules = computed(() => {
        const s = new Set();
        ops.value.forEach((o) => (o.modules || []).forEach((m) => s.add(m)));
        return Array.from(s).sort();
      });
      const filteredOps = computed(() => {
        // list_ops 返回升序，展示为倒序（最新在前）
        let list = ops.value.slice().reverse();
        if (moduleFilter.value) {
          list = list.filter((o) => (o.modules || []).includes(moduleFilter.value));
        }
        if (kw.value) {
          const k = kw.value.toLowerCase();
          list = list.filter(
            (o) =>
              String(o.opId || "").toLowerCase().includes(k) ||
              (o.batchIds || []).some((b) => String(b).toLowerCase().includes(k))
          );
        }
        return list;
      });

      // ---- 详情抽屉 ----
      const detailOp = ref(null);
      const detailLoading = ref(false);
      const detailKw = ref("");
      const detailRecords = ref([]);
      const detailSuperseded = ref([]);
      const filteredRecords = computed(() => {
        let list = detailRecords.value;
        if (detailKw.value) {
          const k = detailKw.value.toLowerCase();
          list = list.filter(
            (r) =>
              String(r.sourcePath || "").toLowerCase().includes(k) ||
              String(r.logicalId || "").toLowerCase().includes(k) ||
              String(r.targetFile || "").toLowerCase().includes(k)
          );
        }
        return list;
      });
      const isSuperseded = (r) =>
        r.recordId && detailSuperseded.value.includes(r.recordId);

      // ---- 回滚弹窗 ----
      const rbOp = ref(null);
      const rbStep = ref("preview");
      const rbPreviewLoading = ref(false);
      const rbPreview = ref("");
      const rbPreviewOk = ref(false);
      const rbPreviewError = ref("");
      const rbAck = ref(false);
      const rbReason = ref("");
      const rbExecLoading = ref(false);
      const rbResult = ref(null);

      // ---- Toast ----
      const toast = ref(null);
      let toastTimer = null;
      const showToast = (msg, type = "info") => {
        toast.value = { msg, type };
        clearTimeout(toastTimer);
        toastTimer = setTimeout(() => (toast.value = null), 3200);
      };

      // ---- 工具 ----
      const fmtTime = (iso, isEpoch) => {
        if (!iso) return "—";
        let d;
        if (isEpoch) d = new Date(Number(iso) * 1000);
        else {
          d = new Date(String(iso).replace("Z", "+00:00"));
        }
        if (isNaN(d.getTime())) return String(iso);
        const p = (n) => String(n).padStart(2, "0");
        return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}:${p(d.getSeconds())}`;
      };
      const fmtSize = (n) => {
        if (!n && n !== 0) return "—";
        if (n < 1024) return n + " B";
        if (n < 1024 * 1024) return (n / 1024).toFixed(1) + " KB";
        return (n / 1024 / 1024).toFixed(1) + " MB";
      };

      const api = async (url, opts) => {
        const res = await fetch(url, opts);
        let body = null;
        try {
          body = await res.json();
        } catch (_) {
          /* 非 JSON 错误页 */
        }
        if (!res.ok) {
          const msg = (body && (body.error || body.message)) || `请求失败 (HTTP ${res.status})`;
          const err = new Error(msg);
          err.status = res.status;
          throw err;
        }
        return body;
      };

      const loadLedger = async () => {
        const dir = encodeURIComponent(dirInput.value);
        const d1 = await api(`/api/ledger/ops?dir=${dir}`);
        ops.value = d1.ops || [];
        legacyCount.value = d1.legacyCount || 0;
        totalRecords.value = d1.totalRecords || 0;
      };
      const loadAudit = async () => {
        const dir = encodeURIComponent(dirInput.value);
        const d = await api(`/api/ledger/audit?dir=${dir}&limit=100`);
        auditEvents.value = (d.events || []).slice().reverse();
        backups.value = d.backups || [];
      };
      const loadAll = async () => {
        if (!dirInput.value) {
          showToast("请先填写源素材库目录", "bad");
          return;
        }
        localStorage.setItem("rb_dir", dirInput.value);
        loading.value = true;
        try {
          await loadLedger();
          inited.value = true;
          try {
            await loadAudit();
          } catch (_) {
            /* 审计读取失败不阻断主列表 */
          }
        } catch (e) {
          showToast(e.message, "bad");
        } finally {
          loading.value = false;
        }
      };

      const showDetail = async (op) => {
        detailOp.value = op;
        detailLoading.value = true;
        detailKw.value = "";
        detailRecords.value = [];
        detailSuperseded.value = [];
        try {
          const dir = encodeURIComponent(dirInput.value);
          const d = await api(`/api/ledger/records?dir=${dir}&op=${encodeURIComponent(op.opId)}`);
          detailRecords.value = d.records || [];
          detailSuperseded.value = d.supersededIds || [];
        } catch (e) {
          showToast(e.message, "bad");
          detailOp.value = null;
        } finally {
          detailLoading.value = false;
        }
      };

      const openRollback = (op) => {
        rbOp.value = op;
        rbStep.value = "preview";
        rbPreview.value = "";
        rbPreviewOk.value = false;
        rbPreviewError.value = "";
        rbAck.value = false;
        rbReason.value = "";
        rbResult.value = null;
        rbPreviewLoading.value = true;
        const dir = encodeURIComponent(dirInput.value);
        api("/api/rollback", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ dir: dirInput.value, opId: op.opId, dryRun: true }),
        })
          .then((d) => {
            if (d.ok && d.dryRun) {
              rbPreview.value = d.msg;
              rbPreviewOk.value = true;
            } else {
              rbPreviewError.value = d.msg || "预览失败";
            }
          })
          .catch((e) => (rbPreviewError.value = e.message))
          .finally(() => (rbPreviewLoading.value = false));
      };

      const execRollback = async () => {
        rbExecLoading.value = true;
        try {
          const d = await api("/api/rollback", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify({
              dir: dirInput.value,
              opId: rbOp.value.opId,
              confirm: true,
              reason: rbReason.value,
            }),
          });
          rbResult.value = d;
          rbStep.value = "result";
          if (d.ok) showToast("回滚成功", "ok");
          else showToast("回滚失败，详见结果面板", "bad");
        } catch (e) {
          showToast(e.message, "bad");
        } finally {
          rbExecLoading.value = false;
        }
      };

      const closeRollback = (refresh) => {
        rbOp.value = null;
        if (refresh) {
          loadAll();
        }
      };

      onMounted(() => {
        // ?dir= 优先于 localStorage
        const q = new URLSearchParams(location.search);
        const fromUrl = (q.get("dir") || "").trim();
        if (fromUrl) {
          dirInput.value = fromUrl;
          loadAll();
        } else {
          dirInput.value = localStorage.getItem("rb_dir") || "";
        }
      });

      return {
        dirInput, loading, inited,
        ops, legacyCount, totalRecords, auditEvents, backups, tab,
        moduleFilter, kw, allModules, filteredOps,
        detailOp, detailLoading, detailKw, filteredRecords, isSuperseded, showDetail,
        rbOp, rbStep, rbPreviewLoading, rbPreview, rbPreviewOk, rbPreviewError,
        rbAck, rbReason, rbExecLoading, rbResult,
        openRollback, execRollback, closeRollback,
        toast, loadAll, fmtTime, fmtSize,
      };
    },
  }).mount("#app");
})();
