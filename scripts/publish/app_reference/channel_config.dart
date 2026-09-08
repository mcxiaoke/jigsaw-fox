// channel_config.dart — 多平台 assets 通道表与 key→URL 解算器（app 端唯一真源之一）
//
// 对应发布侧 scripts/publish/channels.json。语义必须一致：
//   canonical key（相对 dist 根的路径）经 channel 的 rules 展开为真实 URL。
//   layout=preserve -> base + key；layout=flatten -> base + basename(key)。
//
// 设计要点
// 1. 本类以「硬编码种子」形式存在，保证离线/首启也能解析；
//    远端 manifest 可携带 `channels` 字段覆盖本表（数据驱动，新增平台无需发版）。
// 2. zip 等关键 blob 的「多镜像」由本表在运行时合成（见 zipMirrors），
//    不再依赖 JSON 里写死的 zipUrls，因此同一份内容可直接发布到任意平台。

import 'dart:convert';

class ChannelRule {
  final String base;
  final String layout; // 'preserve' | 'flatten'
  final List<String> prefixes;
  const ChannelRule(this.base, this.layout, this.prefixes);
}

class Channel {
  final String id;
  final String base;
  final List<ChannelRule> rules;
  final int cnRank;
  final int globalRank;

  const Channel({
    required this.id,
    required this.base,
    this.rules = const [],
    this.cnRank = 0,
    this.globalRank = 0,
  });

  /// key -> URL（与 assetmap.py:Channel.key_to_url 等价）
  String keyToUrl(String key, String tag) {
    final rule = _matchRule(key);
    final base = rule.base.replaceAll('{tag}', tag);
    if (rule.layout == 'flatten') {
      final name = key.split('/').last;
      return base + name;
    }
    return base + key;
  }

  ChannelRule _matchRule(String key) {
    for (final r in rules) {
      if (r.prefixes.any((p) => key.startsWith(p))) return r;
    }
    return ChannelRule(base, 'preserve', const []);
  }
}

class ChannelResolver {
  ChannelResolver({required this.channels, required this.releaseTag});

  final List<Channel> channels;
  final String releaseTag;

  /// 按区域排序的通道（rank>0 才启用）
  List<Channel> ordered(String region) {
    int key(Channel c) => region == 'cn' ? c.cnRank : c.globalRank;
    final list = channels.where((c) => key(c) > 0).toList()
      ..sort((a, b) => key(a).compareTo(key(b)));
    return list;
  }

  /// 给定 canonical zip key，按区域顺序合成候选镜像 URL 列表（去重、保序）
  List<String> zipMirrors(String canonicalZipKey, String region) =>
      ordered(region).map((c) => c.keyToUrl(canonicalZipKey, releaseTag)).toSet().toList();

  /// 由远端 manifest 的 channels JSON 重建（可选覆盖种子表）
  factory ChannelResolver.fromJson(Map<String, dynamic> j, String fallbackTag) {
    final tag = (j['releaseTag'] as String?) ?? fallbackTag;
    final chans = (j['channels'] as List?)?.map((c) {
      final rules = (c['rules'] as List? ?? []).map((r) {
        final set = (r['set'] as String?) ?? '';
        // 对应 channels.json 的 prefixSets（与发布侧同一份定义，建议一并下发）
        final prefixes = set == 'zip'
            ? const ['daily/zips/', 'events/packs/', 'collections/packs/']
            : List<String>.from(r['prefixes'] as List? ?? const []);
        return ChannelRule(r['base'] as String, r['layout'] as String? ?? 'preserve', prefixes);
      }).toList();
      return Channel(
        id: c['id'] as String,
        base: c['base'] as String,
        rules: rules,
        cnRank: c['cn'] as int? ?? 0,
        globalRank: c['global'] as int? ?? 0,
      );
    }).toList();
    return ChannelResolver(channels: chans ?? const [], releaseTag: tag);
  }
}

// ---------------------------------------------------------------------------
// 种子通道表（与 channels.json 保持一致；远端 manifest.channels 可覆盖）
// 注意：modelscope 的 zip 走 R2 兜底（rules 把 zip 指到 jigsawdata.umao.top）。
// ---------------------------------------------------------------------------
const String kReleaseTag = 'assets';

const List<Channel> kSeedChannels = [
  Channel(
    id: 'gitee',
    base: 'https://gitee.com/macitee/jigsaw-data/raw/master/',
    rules: [
      ChannelRule('https://gitee.com/macitee/jigsaw-data/releases/download/{tag}/',
          'flatten', ['daily/zips/', 'events/packs/', 'collections/packs/']),
    ],
    cnRank: 1,
    globalRank: 4,
  ),
  Channel(
    id: 'r2cdn',
    base: 'https://jigsawdata.umao.top/',
    cnRank: 2,
    globalRank: 2,
  ),
  Channel(
    id: 'modelscope',
    base: 'https://modelscope.cn/datasets/scocahh/jigsaw-data/resolve/master/',
    rules: [
      ChannelRule('https://jigsawdata.umao.top/', 'preserve',
          ['daily/zips/', 'events/packs/', 'collections/packs/']),
    ],
    cnRank: 3,
    globalRank: 0, // 海外不启用
  ),
  Channel(
    id: 'jsdelivr',
    base: 'https://fastly.jsdelivr.net/gh/mcxiaoke/jigsaw-data@master/',
    rules: [
      ChannelRule('https://github.com/mcxiaoke/jigsaw-data/releases/download/{tag}/',
          'flatten', ['daily/zips/', 'events/packs/', 'collections/packs/']),
    ],
    cnRank: 4,
    globalRank: 1,
  ),
  Channel(
    id: 'github',
    base: 'https://raw.githubusercontent.com/mcxiaoke/jigsaw-data/master/',
    rules: [
      ChannelRule('https://github.com/mcxiaoke/jigsaw-data/releases/download/{tag}/',
          'flatten', ['daily/zips/', 'events/packs/', 'collections/packs/']),
    ],
    cnRank: 0, // 国内实测 Release 不通，禁用
    globalRank: 3,
  ),
  Channel(
    id: 'r2pub',
    base: 'https://pub-41cf228a82e748e18c0e54cc4f696fa0.r2.dev/',
    cnRank: 5,
    globalRank: 5,
  ),
];

// 首启 bootstrap：直接从种子表取各通道 manifest URL（竞速选路用，见 selector）
List<String> manifestCandidates(ChannelResolver r, String region) =>
    r.ordered(region).map((c) => c.keyToUrl('manifest.json', '')).toList();

// 供 studio 调试：把种子表序列化为 JSON（与 channels.json 对齐校验用，非运行时必需）
String seedChannelsToJson() => const JsonEncoder.withIndent('  ').convert({
      'releaseTag': kReleaseTag,
      'channels': kSeedChannels
          .map((c) => {
                'id': c.id,
                'base': c.base,
                'cn': c.cnRank,
                'global': c.globalRank,
                'rules': c.rules
                    .map((r) => {'base': r.base, 'layout': r.layout, 'prefixes': r.prefixes})
                    .toList(),
              })
          .toList(),
    });
