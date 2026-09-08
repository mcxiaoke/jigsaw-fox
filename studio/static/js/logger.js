/**
 * studio.static.js.logger — 前端统一日志 + 浮动查看面板
 *
 * 作用：
 *  - 接管 console.log / info / warn / error / debug，既原样输出到浏览器控制台，
 *    又缓存到内存环形缓冲（最多 500 条），供浮动面板查看；
 *  - 捕获全局 window error / unhandledrejection（与 index.html 的防白屏守卫
 *    renderFatalError 共存，互不影响；守卫负责拦截致命白屏，这里只做记录）；
 *  - 右下角提供一个浮动按钮，点击展开日志面板，可查看历史日志并一键复制全部内容。
 *
 * 设计原则：极简、零依赖、不干扰主应用；任何内部异常都不会影响业务渲染。
 */
(function () {
  'use strict';

  var MAX = 500;
  var buffer = [];
  var visible = false;
  var fabEl = null;
  var panelEl = null;
  var logEl = null;
  var statusEl = null;

  function nowStr(d) {
    d = d || new Date();
    function p(n) { return (n < 10 ? '0' : '') + n; }
    return p(d.getHours()) + ':' + p(d.getMinutes()) + ':' + p(d.getSeconds());
  }

  function fmt(a) {
    if (a == null) return 'null';
    if (a instanceof Error) return a.stack || (a.name + ': ' + a.message);
    if (typeof a === 'object') {
      try { return JSON.stringify(a); } catch (e) { return String(a); }
    }
    return String(a);
  }

  function levelOf(method) {
    if (method === 'error') return 'error';
    if (method === 'warn') return 'warn';
    if (method === 'debug') return 'debug';
    return 'info'; // log / info
  }

  function push(level, args) {
    var parts = [];
    for (var i = 0; i < args.length; i++) parts.push(fmt(args[i]));
    buffer.push({ t: nowStr(), level: level, msg: parts.join(' ') });
    if (buffer.length > MAX) buffer.shift();
    if (visible && logEl) appendLine(buffer[buffer.length - 1]);
  }

  // 缓存原始 console 方法，避免覆盖后递归调用自身
  var orig = {
    log: console.log ? console.log.bind(console) : function () {},
    info: console.info ? console.info.bind(console) : function () {},
    warn: console.warn ? console.warn.bind(console) : function () {},
    error: console.error ? console.error.bind(console) : function () {},
    debug: console.debug ? console.debug.bind(console) : function () {},
  };

  function wrap(method) {
    console[method] = function () {
      var args = Array.prototype.slice.call(arguments);
      push(levelOf(method), args);
      orig[method].apply(console, args);
    };
  }
  ['log', 'info', 'warn', 'error', 'debug'].forEach(wrap);

  // 全局异常捕获（与 index.html 的 renderFatalError 共存，互不干扰）
  window.addEventListener('error', function (e) {
    var where = e.filename ? (e.filename + ':' + e.lineno + ':' + e.colno) : 'unknown';
    push('error', ['[window.error] ' + (e.message || 'Script Error') + ' @ ' + where]);
  });
  window.addEventListener('unhandledrejection', function (e) {
    var r = e.reason;
    var detail = r && (r.stack || r.message) ? (r.stack || r.message) : fmt(r);
    push('error', ['[unhandledrejection] ' + detail]);
  });

  function appendLine(entry) {
    var line = document.createElement('div');
    line.className = 'stdlog-line stdlog-' + entry.level;

    var ts = document.createElement('span');
    ts.className = 'stdlog-ts';
    ts.textContent = '[' + entry.t + ']';

    var lv = document.createElement('span');
    lv.className = 'stdlog-lv';
    lv.textContent = entry.level.toUpperCase();

    var ms = document.createElement('span');
    ms.className = 'stdlog-msg';
    ms.textContent = entry.msg;

    line.appendChild(ts);
    line.appendChild(lv);
    line.appendChild(ms);
    logEl.appendChild(line);

    // 同步限制 DOM 行数，避免长会话内存膨胀
    while (logEl.childNodes.length > MAX) logEl.removeChild(logEl.firstChild);
    logEl.scrollTop = logEl.scrollHeight;
  }

  function renderAll() {
    logEl.innerHTML = '';
    for (var i = 0; i < buffer.length; i++) appendLine(buffer[i]);
  }

  function flash(text) {
    if (!statusEl) return;
    statusEl.textContent = text;
    statusEl.style.opacity = '1';
    setTimeout(function () { statusEl.style.opacity = '0'; }, 1500);
  }

  function copyAll() {
    var text = buffer.map(function (e) {
      return '[' + e.t + '] ' + e.level.toUpperCase() + ' ' + e.msg;
    }).join('\n');
    if (!text) { flash('暂无日志'); return; }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(
        function () { flash('已复制 ' + buffer.length + ' 条'); },
        function () { fallbackCopy(text); }
      );
    } else {
      fallbackCopy(text);
    }
  }

  function fallbackCopy(text) {
    try {
      var ta = document.createElement('textarea');
      ta.value = text;
      ta.style.position = 'fixed';
      ta.style.opacity = '0';
      document.body.appendChild(ta);
      ta.select();
      document.execCommand('copy');
      document.body.removeChild(ta);
      flash('已复制 ' + buffer.length + ' 条');
    } catch (e) {
      flash('复制失败');
    }
  }

  function clearAll() {
    buffer.length = 0;
    if (logEl) logEl.innerHTML = '';
    flash('已清空');
  }

  function show() {
    visible = true;
    panelEl.style.display = 'flex';
    fabEl.textContent = '📜 收起';
    renderAll();
  }

  function hide() {
    visible = false;
    panelEl.style.display = 'none';
    fabEl.textContent = '📜 日志';
  }

  function toggle() {
    if (visible) hide(); else show();
  }

  function injectStyle() {
    var css =
      '#stdlog-fab{position:fixed;right:14px;bottom:14px;z-index:99990;background:#0f172a;color:#e2e8f0;' +
      'font:600 12px/1 ui-monospace,Menlo,Consolas,monospace;padding:9px 13px;border-radius:18px;' +
      'cursor:pointer;box-shadow:0 6px 16px rgba(0,0,0,.35);user-select:none;}' +
      '#stdlog-fab:hover{background:#1e293b;}' +
      '#stdlog-panel{position:fixed;right:14px;bottom:58px;z-index:99991;width:440px;max-width:92vw;' +
      'height:62vh;max-height:70vh;display:none;flex-direction:column;background:#0f172a;color:#e2e8f0;' +
      'border:1px solid #334155;border-radius:10px;box-shadow:0 12px 30px rgba(0,0,0,.45);overflow:hidden;' +
      'font-family:ui-monospace,Menlo,Consolas,monospace;}' +
      '#stdlog-head{display:flex;align-items:center;gap:8px;padding:8px 10px;background:#1e293b;' +
      'border-bottom:1px solid #334155;font-size:12px;font-weight:700;}' +
      '#stdlog-head .stdlog-title{flex:1;}' +
      '#stdlog-head button{background:#334155;color:#e2e8f0;border:none;border-radius:6px;' +
      'padding:4px 9px;font-size:11px;cursor:pointer;}' +
      '#stdlog-head button:hover{background:#475569;}' +
      '#stdlog-body{flex:1;overflow:auto;padding:6px 8px;font-size:11px;line-height:1.5;}' +
      '.stdlog-line{display:flex;gap:6px;padding:1px 0;white-space:pre-wrap;word-break:break-all;}' +
      '.stdlog-ts{color:#64748b;flex:0 0 auto;}' +
      '.stdlog-lv{flex:0 0 42px;font-weight:700;}' +
      '.stdlog-msg{flex:1;}' +
      '.stdlog-error .stdlog-lv{color:#f87171;}' +
      '.stdlog-error .stdlog-msg{color:#fca5a5;}' +
      '.stdlog-warn .stdlog-lv{color:#fbbf24;}' +
      '.stdlog-warn .stdlog-msg{color:#fde68a;}' +
      '.stdlog-debug .stdlog-lv{color:#94a3b8;}' +
      '.stdlog-debug .stdlog-msg{color:#cbd5e1;}' +
      '.stdlog-info .stdlog-lv{color:#60a5fa;}' +
      '.stdlog-info .stdlog-msg{color:#e2e8f0;}' +
      '#stdlog-foot{display:flex;align-items:center;gap:8px;padding:6px 10px;background:#1e293b;' +
      'border-top:1px solid #334155;}' +
      '#stdlog-foot button{background:#334155;color:#e2e8f0;border:none;border-radius:6px;' +
      'padding:4px 10px;font-size:11px;cursor:pointer;}' +
      '#stdlog-foot button:hover{background:#475569;}' +
      '#stdlog-status{margin-left:auto;font-size:11px;color:#94a3b8;opacity:0;transition:opacity .2s;}';
    var style = document.createElement('style');
    style.textContent = css;
    document.head.appendChild(style);
  }

  function buildUI() {
    if (fabEl) return;
    injectStyle();

    fabEl = document.createElement('div');
    fabEl.id = 'stdlog-fab';
    fabEl.textContent = '📜 日志';
    fabEl.title = '查看前端日志';
    fabEl.addEventListener('click', toggle);
    document.body.appendChild(fabEl);

    panelEl = document.createElement('div');
    panelEl.id = 'stdlog-panel';
    panelEl.innerHTML =
      '<div id="stdlog-head">' +
        '<span class="stdlog-title">前端日志 (' + MAX + ' 条上限)</span>' +
        '<button id="stdlog-copy">📋 复制</button>' +
        '<button id="stdlog-clear">🗑 清空</button>' +
        '<button id="stdlog-close">✕</button>' +
      '</div>' +
      '<div id="stdlog-body"></div>' +
      '<div id="stdlog-foot"><span>点击浮动按钮可隐藏</span><span id="stdlog-status"></span></div>';
    document.body.appendChild(panelEl);

    logEl = panelEl.querySelector('#stdlog-body');
    statusEl = panelEl.querySelector('#stdlog-status');
    panelEl.querySelector('#stdlog-copy').addEventListener('click', copyAll);
    panelEl.querySelector('#stdlog-clear').addEventListener('click', clearAll);
    panelEl.querySelector('#stdlog-close').addEventListener('click', hide);
  }

  // 暴露统一 API，便于业务代码主动记录（app.js 等可在 catch 中调用 StdLog.error）
  // 注意：手动调用既写入缓冲（面板可看），也转发到原始 console（浏览器控制台可见）。
  function apiPush(level, origMethod, args) {
    push(level, args);
    origMethod.apply(console, Array.prototype.slice.call(args));
  }
  window.StdLog = {
    log: function () { apiPush('info', orig.log, arguments); },
    info: function () { apiPush('info', orig.info, arguments); },
    warn: function () { apiPush('warn', orig.warn, arguments); },
    error: function () { apiPush('error', orig.error, arguments); },
    debug: function () { apiPush('debug', orig.debug, arguments); },
    show: show,
    hide: hide,
    toggle: toggle,
    copy: copyAll,
    clear: clearAll,
    all: function () { return buffer.slice(); },
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', buildUI);
  } else {
    buildUI();
  }
})();
