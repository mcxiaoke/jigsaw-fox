// integrations.dart — 将多平台通道方案接入现有 lib/ 的最小改动清单（非可运行，仅作落地参考）
//
// 设计原则：现有 JSON 的相对 URL（图片/索引）已由 ManifestRouter 以 baseUri 递归解析，
// 天然随「选中通道」切换；唯一需要补强的是 zip（不同平台规则不同）。本方案：
//   - 新增 zipKey（canonical key），app 端用 ChannelResolver 合成多镜像；
//   - 下载后做 sha256 兜底校验，失败即触发 downloadFileWithMirrors 的下一个镜像；
//   - manifest 发现由「顺序轮询」升级为「竞速 + 粘性 + 熔断」（content_selector.dart）。
//
// 下列 diff 仅为说明，请人工 review 后落地，本文件不参与编译。

/* ============================ 1) content_http_client.dart ============================ */
// 在 downloadFile() 成功 rename 之后、return 之前，加入 sha256 校验（可选，由调用方传入 expectSha256）：
//
//   final finalFile = await partFile.rename(destinationPath);
//   if (expectSha256 != null && expectSha256.isNotEmpty) {
//     final actual = await _sha256OfFile(finalFile);
//     if (actual.toLowerCase() != expectSha256.toLowerCase()) {
//       try { await finalFile.delete(); } catch (_) {}
//       throw HttpException('sha256 mismatch for $url: want=$expectSha256 got=$actual');
//     }
//   }
//
// 同时给 downloadFile / downloadFileWithMirrors 增加可选参数：
//   Future<File> downloadFile(..., {Duration? timeout, void Function(int,int)? onProgress, String? expectSha256}) {...}
//   Future<File> downloadFileWithMirrors(List<String> urls, String destinationPath,
//       {Duration? timeout, void Function(int,int)? onProgress, String? expectSha256}) {
//     // 把 expectSha256 透传给每个 downloadFile 调用
//   }
//
// 辅助方法：
//   static Future<String> _sha256OfFile(File f) async {
//     final bytes = await f.readAsBytes();
//     return sha256.convert(bytes).toString();   // 需 import 'dart:convert';
//   }

/* ============================ 2) manifest_router.dart ============================ */
// 注入 ChannelResolver 与 region，用 content_selector.dart 的竞速选路替换顺序轮询：
//
//   class ManifestRouter {
//     ManifestRouter({required this.bootstrapUrls, required this.cacheFilePath,
//                     this.resolver, this.region = 'cn', ContentHttpClient? httpClient})
//       : _httpClient = httpClient ?? ContentHttpClient();
//     final ChannelResolver? resolver;
//     final String region;
//
//     Future<RootManifest> resolveManifest({bool forceRefresh = false}) async {
//       if (resolver != null) {
//         try {
//           final sel = SourceSelector(resolver: resolver, region: region);
//           final (channel, body) = await sel.selectManifest();
//           final json = jsonDecode(body);
//           final m = RootManifest.fromJson(json).copyWith(baseUri: channel.keyToUrl('manifest.json',''));
//           await _saveToDiskCache({...json, 'baseUri': m.baseUri, '_channel': channel.id});
//           _cachedManifest = m;
//           return m;
//         } catch (e, st) {
//           AppLogger.manifest.warning('selectManifest failed, fallback to bootstrapUrls', e, st);
//         }
//       }
//       // 原有 bootstrapUrls 顺序轮询逻辑作为兜底保留 ...
//     }
//   }

/* ============================ 3) content_manager.dart ============================ */
// 把 resolver/region 透传给各 pipeline，并改写 zip 镜像计算：
//
//   class ContentManager {
//     ContentManager({required List<String> bootstrapUrls, required String appSupportDir,
//                     required String appDocumentsDir, this.channelResolver, this.region = 'cn',
//                     ContentHttpClient? httpClient})
//       : manifestRouter = ManifestRouter(bootstrapUrls: bootstrapUrls, ...,
//                                         resolver: channelResolver, region: region),
//         ... ;
//     final ChannelResolver? channelResolver;
//     final String region;
//
//     // events
//     Future<bool> ensureEventDownloaded(PuzzleEventItem event) =>
//       eventsPipeline.ensureEventDownloaded(event, resolver: channelResolver, region: region);
//     // collections
//     Future<bool> ensureCollectionDownloaded(PuzzleCollectionItem c, {void Function(double)? onProgress}) =>
//       collectionsPipeline.ensureCollectionDownloaded(c, resolver: channelResolver, region: region, onProgress: onProgress);
//     // daily
//     // ensureDailyMonthReady 内部同样把 resolver/region 透传到 dailyPipeline.ensureMonthReady

/* ============================ 4) pipelines: events / collections / daily ============================ */
// 以 events 为例（collections/daily 同构）。把「读 zipUrls」替换为 buildZipMirrors：
//
//   Future<bool> ensureEventDownloaded(PuzzleEventItem event,
//       {ChannelResolver? resolver, String region = 'cn'}) async {
//     final mirrors = (resolver != null)
//         ? buildZipMirrors(item: event.toJsonForResolve(), resolver: resolver, region: region)
//         : [event.zipUrl!, ...event.zipUrls];   // 旧端兼容
//     // ... 下载：
//     await _httpClient.downloadFileWithMirrors(
//       mirrors.where((u) => u.isNotEmpty).toList(),
//       zipPath,
//       expectSha256: event.zipSha256,   // 兜底校验
//       onProgress: ...,
//     );
//   }
//
// 说明：
//   - event.toJsonForResolve() 需暴露 zipKey/zipUrl/zipUrls（模型已有这些字段，组装一个 Map 即可）。
//   - downloadFileWithMirrors 已有「单镜像失败自动切下一个、全部失败抛最后异常、.part 不留残损」逻辑；
//     叠加 sha256 校验后，坏镜像会被判失败并继续下一个，真正提升主备切换可靠性。

/* ============================ 5) app_content.dart ============================ */
// 构造全局 ChannelResolver，交给 ContentManager：
//
//   _manager = ContentManager(
//     bootstrapUrls: bootstrapUrls ?? defaultBootstrapUrls,
//     appSupportDir: supportDir.path,
//     appDocumentsDir: documentsDir.path,
//     channelResolver: ChannelResolver(channels: kSeedChannels, releaseTag: kReleaseTag),
//     region: _detectRegion(),   // 'cn' 默认；可按 Locale/时区粗判，或后续用 SourceSelector 自适应
//   );
//
// 注：defaultBootstrapUrls 可保留作为极端兜底（resolver 不可用时）。

/* ============================ 6) 部署/配置注意 ============================ */
// - 发布侧 channels.json 的 releaseTag 当前为 'assets'（固定移动标签），
//   因此 app 端 kReleaseTag 也必须是 'assets'；若改标签需同步发版或在 manifest.channels 下发。
// - 新增/调整通道（如新增国内 CDN）：只需在服务端 manifest.channels 下发新表，
//   app 端用 ChannelResolver.fromJson 覆盖种子表，无需发版。
// - 旧版本 app（无 zipKey 支持）仍能工作：JSON 里保留了 zipUrl，旧端走原逻辑。
