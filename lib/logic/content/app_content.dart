import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:jigsawpuzzle/logic/content/content_manager.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/collections_content_pipeline.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/events_content_pipeline.dart';
import 'package:jigsawpuzzle/logic/content/pipelines/pack_content_pipeline.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:path_provider/path_provider.dart';

/// 全局内容与扩展系统门面单例
///
/// 启动语义（v2，docs/home-network-migration-and-boot-init-design-20260907.md §3.1/3.3）：
/// - [initFromDiskCache]：纯本地缓存初始化（组1，runApp 前 await，5~15ms，不发起任何网络）；
/// - [isFirstBootReady]：同步判定"json + main 前 [kFirstBootMainLevelCount] 关原图"是否就绪，
///   决定 initialHome = MainScreen（0 闪烁秒开）还是 BootGatePage（首启初始化）；
/// - [ensureFirstBootReady]：首启严格初始化（manifest + main 元数据 + 前 N 关原图），
///   任一失败抛错 → 失败页重试，不满足条件不放行进首页（D5/D9）；
/// - 网络后台增量 sync 时机收口：MainScreen 挂载后调 [backgroundSyncOnce]
///   （init 不再自动派发，杜绝与 BootGate 的同步竞态，P1）。
class AppContent {
  AppContent._();
  static final AppContent instance = AppContent._();

  /// 首启必须落盘的 main 前 N 关原图数量（D9，暂定）
  static const int kFirstBootMainLevelCount = 4;

  /// 支持的 manifest schemaVersion 区间（当前线上 = 4；3 = 兼容的纯路由早期版本）。
  /// 超出即视为不兼容：老客户端读到未来破坏性 schema 时明确失败而非静默解析错乱。
  static const int kMinSupportedSchemaVersion = 3;
  static const int kMaxSupportedSchemaVersion = 4;

  /// 首启初始化整体预算（外层兜底；阶段：manifest+main 元数据 12s / 前 N 图各 8s）。
  /// 多源顺序轮询（每 URL 4s）最坏约 8s 失败 + 命中源耗时，12s 为 manifest/meta 阶段
  /// 预留；总预算 25s 相比 D6 原 20s 上调，用于容纳多源回退。
  static const Duration kFirstBootTotalBudget = Duration(seconds: 25);
  static const Duration kFirstBootMetaBudget = Duration(seconds: 12);
  static const Duration kFirstBootImageBudget = Duration(seconds: 8);

  ContentManager? _manager;
  ContentManager get manager {
    if (_manager == null) {
      throw StateError(
        'AppContent must be initialized by calling init() first.',
      );
    }
    return _manager!;
  }

  @visibleForTesting
  void setManagerForTest(ContentManager? m) {
    _manager = m;
    _isInitialized = m != null;
  }

  static final PackContentPipeline _fallbackPacks = PackContentPipeline(
    packsBaseDir: '',
  );

  static final CollectionsContentPipeline _fallbackCollections =
      CollectionsContentPipeline(
        cacheFilePath: '',
        collectionsStorageBaseDir: '',
      );

  static final EventsContentPipeline _fallbackEvents = EventsContentPipeline(
    cacheFilePath: '',
    eventsStorageBaseDir: '',
  );

  /// 扩展图包管线快捷访问 (带安全 Fallback)
  PackContentPipeline get packs => _manager?.packPipeline ?? _fallbackPacks;

  /// 图集管线快捷访问 (带安全 Fallback)
  CollectionsContentPipeline get collections =>
      _manager?.collectionsPipeline ?? _fallbackCollections;

  /// 活动管线快捷访问 (带安全 Fallback)
  EventsContentPipeline get events =>
      _manager?.eventsPipeline ?? _fallbackEvents;

  bool _isInitialized = false;
  bool get isInitialized => _isInitialized;

  Future<void>? _initFuture;

  /// 本地磁盘缓存初始化完成句柄（组1 await 后即可同步查询 [isFirstBootReady]）
  Future<void> get initializedFuture => _initFuture ?? Future<void>.value();

  /// 全局响应式通知：当内容更新时触发 UI 刷新
  final ValueNotifier<int> contentUpdateNotifier = ValueNotifier<int>(0);

  /// 默认主备通道端点列表（ManifestRouter 顺序轮询，单 URL 4s 超时）。
  ///
  /// v2 素材发布方案（docs/assets-publish-workflow-v2-20260910.md §3.1）：
  /// R2 主通道 → Gitee 国内备用 → GitHub 海外备用，三者均指向各自托管的
  /// `release/manifest.json`（同构目录，与本地 jigsaw-data/release/ 一致）。
  /// 测试/开发版可将首个 URL 换成 `.../_stage/manifest.json` 走预演区。
  /// ⚠️ 三条通道的内容必须同源；Gitee/GitHub 镜像仓库需与 mcxiaoke/jigsaw-data 同步。
  static const List<String> defaultBootstrapUrls = [
    'https://jigsawdata.umao.top/release/manifest.json',
    'https://gitee.com/macitee/jigsaw-data/raw/master/release/manifest.json',
    'https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/master/release/manifest.json',
  ];

  /// 组1 纯本地初始化：构建 manager + 读磁盘缓存，**不发任何网络请求**。
  /// manifest 磁盘未命中时返回 offline fallback，是否联网初始化由 BootGate 决定。
  ///
  /// **失败可重试（H4 修复）**：初始化抛错时（磁盘 manifest 损坏 / 版本不兼容 /
  /// 目录不可写）必须清除 `_initFuture` 缓存并透传错误。若像原先那样无条件缓存
  /// future，failed future 会被永久复用——此后 BootGate 或任何重试入口都命中同一
  /// 失败结果，**进程生命周期内永远失败，只能重启 App**。
  Future<void> initFromDiskCache({List<String>? bootstrapUrls}) {
    final existing = _initFuture;
    if (existing != null) return existing;
    final future = _initFromDiskCache(bootstrapUrls).onError((
      Object e,
      StackTrace st,
    ) {
      // 失败清除缓存：允许上层修复后重试（重试入口可再次调用本方法）
      _initFuture = null;
      AppLogger.content.warning(
        'AppContent initFromDiskCache failed (cache cleared for retry)',
        e,
        st,
      );
      return Future<void>.error(e, st);
    });
    _initFuture = future;
    return future;
  }

  Future<void> _initFromDiskCache(List<String>? bootstrapUrls) async {
    if (_isInitialized) return;
    AppLogger.content.info(
      'AppContent initFromDiskCache start bootstrap=${bootstrapUrls ?? defaultBootstrapUrls}',
    );
    final sw = Stopwatch()..start();
    final supportDir = await getApplicationSupportDirectory();

    _manager = ContentManager(
      bootstrapUrls: bootstrapUrls ?? defaultBootstrapUrls,
      appSupportDir: supportDir.path,
    );

    // 纯本地：offlineOnly=true 时 manifest 磁盘未命中不请求网络
    await _manager!.initialize(offlineOnly: true);
    // P0-3 补充：外层单向监听内层各管线通知，统一聚合为 contentUpdateNotifier。
    // 方向“外层监听内层”无依赖环，且覆盖直连 pipeline 的下载入口
    // （代理层自增会漏掉 collections_tab/home_tab 的直连调用）。
    _attachPipelineForwarding();
    AppLogger.content.info(
      'AppContent disk init done ${sw.elapsedMilliseconds}ms supportDir=${supportDir.path}',
    );
    _isInitialized = true;
  }

  /// P0-3：将各管线自身的更新通知聚合为全局 [contentUpdateNotifier]。
  /// 仅在初始化时挂载一次；管线只管自身状态，外层负责转发，不反向依赖。
  ///
  /// 转发必须经 microtask 延迟合并：管线通知可能在首帧构建期内同步到达
  /// （如索引构建触发 `loadAllPacks`），直接同步 bump 会导致监听页在
  /// build 期间 setState 而崩溃；microtask 将其推迟到当前同步段之后。
  bool _forwardPending = false;

  void _attachPipelineForwarding() {
    final m = _manager;
    if (m == null) return;
    m.eventsPipeline.updateNotifier.addListener(_bumpContentUpdate);
    m.collectionsPipeline.updateNotifier.addListener(_bumpContentUpdate);
    m.packPipeline.packsNotifier.addListener(_bumpContentUpdate);
  }

  void _bumpContentUpdate() {
    if (_forwardPending) return;
    _forwardPending = true;
    scheduleMicrotask(() {
      _forwardPending = false;
      contentUpdateNotifier.value++;
    });
  }

  /// 兼容入口：本地初始化 + 单次后台增量（后台 sync 不在此自动派发，见类注释；
  /// 生产路径走 [initFromDiskCache] + MainScreen/BootGate 收口）
  Future<void> init({List<String>? bootstrapUrls}) async {
    await initFromDiskCache(bootstrapUrls: bootstrapUrls);
    backgroundSyncOnce();
  }

  /// 首启就绪同步判定（D4）：本地 manifest 缓存存在 && main 前 N 关原图已落盘。
  /// 须在 [initFromDiskCache] 完成后调用（runApp 前）。
  bool isFirstBootReady() {
    final m = _manager;
    if (m == null || !_isInitialized) return false;
    // 1. manifest 磁盘缓存存在（离线 fallback 不落盘，首次/清数据必然缺失）
    final manifestCache = File(m.manifestRouter.cacheFilePath);
    if (!manifestCache.existsSync()) {
      AppLogger.content.info('isFirstBootReady false: manifest cache missing');
      return false;
    }
    // 2. main 前 N 关原图本地存在
    final levels = m.getMainLevels();
    if (levels.length < kFirstBootMainLevelCount) {
      AppLogger.content.info(
        'isFirstBootReady false: main levels=${levels.length} < $kFirstBootMainLevelCount',
      );
      return false;
    }
    for (final l in levels.take(kFirstBootMainLevelCount)) {
      final lp = l.localPath;
      if (lp == null ||
          lp.isEmpty ||
          lp.startsWith('http://') ||
          lp.startsWith('https://') ||
          !File(lp).existsSync()) {
        AppLogger.content.info(
          'isFirstBootReady false: first-level image missing id=${l.id}',
        );
        return false;
      }
    }
    AppLogger.content.info('isFirstBootReady true');
    return true;
  }

  Future<void>? _bootInitFuture;

  /// 首启严格初始化（单飞防重入：进行中直接复用同一 Future）。
  /// 成功 → 满足 [isFirstBootReady]；失败抛错 → 由 BootGate 失败页展示重试。
  Future<void> ensureFirstBootReady() {
    final existing = _bootInitFuture;
    if (existing != null) {
      AppLogger.content.info('ensureFirstBootReady already in flight, await');
      return existing;
    }
    final future = _runFirstBootInit().timeout(
      kFirstBootTotalBudget,
      onTimeout: () => throw TimeoutException('first boot init timed out'),
    );
    _bootInitFuture = future;
    future.whenComplete(() {
      if (identical(_bootInitFuture, future)) _bootInitFuture = null;
    });
    return future;
  }

  Future<void> _runFirstBootInit() async {
    AppLogger.content.info('ensureFirstBootReady start');
    final m = manager;
    final sw = Stopwatch()..start();
    // 1. manifest + main 元数据（互斥收敛于 ContentManager，预算 10s）
    final manifest = await m.syncMainContent().timeout(
      kFirstBootMetaBudget,
      onTimeout: () => throw TimeoutException('manifest/main meta timed out'),
    );
    // 1b. schemaVersion 兼容性校验（网络 fetch 成功路径；越界即不兼容）
    if (manifest.schemaVersion < kMinSupportedSchemaVersion ||
        manifest.schemaVersion > kMaxSupportedSchemaVersion) {
      throw StateError(
        'manifest schemaVersion=${manifest.schemaVersion} not supported '
        '(supported $kMinSupportedSchemaVersion~$kMaxSupportedSchemaVersion); '
        'app may be outdated',
      );
    }
    // 2. 批次完整性：远端声明的批次必须全部落本地（防部分批次静默丢失，P3）
    final localBatches = m.mainPipeline.localBatchIds;
    final remoteBatches = m.mainPipeline.lastRemoteBatchIds;
    if (!localBatches.containsAll(remoteBatches)) {
      throw StateError(
        'first boot main batches incomplete: '
        'remote=${remoteBatches.toList()} local=${localBatches.toList()}',
      );
    }
    // 3. 关卡数量满足首屏下限（以服务端 totalCount 为准，目录不足 4 关时取 min）
    final levels = m.getMainLevels();
    final expectedTotal = manifest.mainModule.totalCount;
    final required = expectedTotal > 0
        ? math.min(kFirstBootMainLevelCount, expectedTotal)
        : kFirstBootMainLevelCount;
    if (levels.length < required) {
      throw StateError(
        'first boot main levels insufficient: got=${levels.length} required=$required',
      );
    }
    // 4. 前 N 关原图落盘（timeout 透传 Dio：底层 Socket 8s 主动中断，避免
    //    外层超时后旧连接仍占用默认 60s 导致重试等待；ensure 失败 rethrow）
    await Future.wait(
      levels
          .take(required)
          .map(
            (l) =>
                m.ensureMainLevelDownloaded(l, timeout: kFirstBootImageBudget),
          ),
    );
    // 5. 最终复检（含 manifest 缓存已由 syncMainContent 落盘）
    if (!isFirstBootReady()) {
      throw StateError('first boot data still not ready after init');
    }
    AppLogger.content.info(
      'ensureFirstBootReady success ${sw.elapsedMilliseconds}ms levels=${m.getMainLevels().length}',
    );
  }

  bool _bgSyncStarted = false;

  /// 后台增量同步（单次）：MainScreen 挂载 / BootGate 成功后调用一次。
  /// 与 [ensureFirstBootReady] 共享 ContentManager 互斥，不会双写。
  void backgroundSyncOnce() {
    if (!_isInitialized || _bgSyncStarted) return;
    _bgSyncStarted = true;
    AppLogger.content.info('backgroundSyncOnce scheduled');
    Future.microtask(() async {
      final sw = Stopwatch()..start();
      try {
        await _manager?.syncAll();
        contentUpdateNotifier.value++;
        AppLogger.content.info(
          'Background sync success ${sw.elapsedMilliseconds}ms',
        );
      } catch (e, st) {
        AppLogger.content.severe('Background sync failed', e, st);
      }
    });
  }

  /// 前台全量/轻量同步（下拉刷新等）。[includeDailyZip]=false 时跳过 daily 月度 zip。
  Future<void> syncAll({bool includeDailyZip = true}) async {
    AppLogger.content.info('syncAll start includeDailyZip=$includeDailyZip');
    final sw = Stopwatch()..start();
    try {
      await _manager?.syncAll(includeDailyZip: includeDailyZip);
      contentUpdateNotifier.value++;
      AppLogger.content.info(
        'syncAll success ${sw.elapsedMilliseconds}ms notifier=${contentUpdateNotifier.value}',
      );
    } catch (e, st) {
      AppLogger.content.severe('Sync failed', e, st);
    }
  }

  /// 是否正有网络同步在跑（后台全量轮/首启）。供 UI 短路互斥等待。
  bool get isSyncing => _manager?.isSyncing ?? false;
}
