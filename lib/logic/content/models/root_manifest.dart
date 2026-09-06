/// 根路由清单模型
class RootManifest {
  const RootManifest({
    required this.schemaVersion,
    required this.updatedAt,
    required this.mainModule,
    required this.dailyModule,
    required this.eventsModule,
    this.collectionsModule = const CollectionsModuleConfig(url: '', version: 0),
    this.notice = '',
    this.minAppVersion = '1.0.0',
    this.baseUri = '',
  });

  final int schemaVersion;
  final DateTime updatedAt;
  final String notice;
  final String minAppVersion;
  final String baseUri;

  final MainModuleConfig mainModule;
  final DailyModuleConfig dailyModule;
  final EventsModuleConfig eventsModule;
  final CollectionsModuleConfig collectionsModule;

  RootManifest copyWith({
    int? schemaVersion,
    DateTime? updatedAt,
    String? notice,
    String? minAppVersion,
    String? baseUri,
    MainModuleConfig? mainModule,
    DailyModuleConfig? dailyModule,
    EventsModuleConfig? eventsModule,
    CollectionsModuleConfig? collectionsModule,
  }) {
    return RootManifest(
      schemaVersion: schemaVersion ?? this.schemaVersion,
      updatedAt: updatedAt ?? this.updatedAt,
      notice: notice ?? this.notice,
      minAppVersion: minAppVersion ?? this.minAppVersion,
      baseUri: baseUri ?? this.baseUri,
      mainModule: mainModule ?? this.mainModule,
      dailyModule: dailyModule ?? this.dailyModule,
      eventsModule: eventsModule ?? this.eventsModule,
      collectionsModule: collectionsModule ?? this.collectionsModule,
    );
  }

  factory RootManifest.fromJson(Map<String, dynamic> json) {
    final modules = json['modules'] as Map<String, dynamic>? ?? {};
    final appConfig = json['appConfig'] as Map<String, dynamic>? ?? {};

    DateTime parseDate(dynamic v) {
      if (v == null) return DateTime.now();
      try {
        return DateTime.parse(v.toString());
      } catch (_) {
        return DateTime.now();
      }
    }

    return RootManifest(
      schemaVersion: (json['schemaVersion'] as num?)?.toInt() ?? 3,
      updatedAt: parseDate(json['updatedAt']),
      notice: appConfig['notice']?.toString() ?? '',
      minAppVersion: appConfig['minAppVersion']?.toString() ?? '1.0.0',
      mainModule: MainModuleConfig.fromJson(
        modules['main'] as Map<String, dynamic>? ?? {},
      ),
      dailyModule: DailyModuleConfig.fromJson(
        modules['daily'] as Map<String, dynamic>? ?? {},
      ),
      eventsModule: EventsModuleConfig.fromJson(
        modules['events'] as Map<String, dynamic>? ?? {},
      ),
      collectionsModule: CollectionsModuleConfig.fromJson(
        modules['collections'] as Map<String, dynamic>? ?? {},
      ),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'updatedAt': updatedAt.toIso8601String(),
      'appConfig': {'notice': notice, 'minAppVersion': minAppVersion},
      'modules': {
        'main': mainModule.toJson(),
        'daily': dailyModule.toJson(),
        'events': eventsModule.toJson(),
        'collections': collectionsModule.toJson(),
      },
    };
  }
}

class MainModuleConfig {
  const MainModuleConfig({
    required this.url,
    required this.version,
    this.totalCount = 0,
    this.hash = '',
  });

  final String url;
  final int version;
  final int totalCount;
  final String hash;

  factory MainModuleConfig.fromJson(Map<String, dynamic> json) {
    return MainModuleConfig(
      url: json['url']?.toString() ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      totalCount:
          (json['totalCount'] as num?)?.toInt() ??
          (json['count'] as num?)?.toInt() ??
          0,
      hash: json['hash']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'version': version,
    if (totalCount > 0) 'totalCount': totalCount,
    if (hash.isNotEmpty) 'hash': hash,
  };
}

class DailyModuleConfig {
  const DailyModuleConfig({
    this.url = '',
    required this.currentMonth,
    this.zipUrlPattern = '',
    this.listUrlPattern = '',
    required this.version,
    this.hash = '',
    this.count = 0,
  });

  final String url;
  final String currentMonth;
  final String zipUrlPattern;
  final String listUrlPattern;
  final int version;
  final String hash;
  final int count;

  factory DailyModuleConfig.fromJson(Map<String, dynamic> json) {
    return DailyModuleConfig(
      url: json['url']?.toString() ?? '',
      currentMonth: json['currentMonth']?.toString() ?? '',
      zipUrlPattern: json['zipUrlPattern']?.toString() ?? '',
      listUrlPattern: json['listUrlPattern']?.toString() ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      hash: json['hash']?.toString() ?? '',
      count: (json['count'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    if (url.isNotEmpty) 'url': url,
    'currentMonth': currentMonth,
    'zipUrlPattern': zipUrlPattern,
    'listUrlPattern': listUrlPattern,
    'version': version,
    if (hash.isNotEmpty) 'hash': hash,
    if (count > 0) 'count': count,
  };
}

class EventsModuleConfig {
  const EventsModuleConfig({
    required this.url,
    required this.version,
    this.count = 0,
    this.hash = '',
  });

  final String url;
  final int version;
  final int count;
  final String hash;

  factory EventsModuleConfig.fromJson(Map<String, dynamic> json) {
    return EventsModuleConfig(
      url: json['url']?.toString() ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      count: (json['count'] as num?)?.toInt() ?? 0,
      hash: json['hash']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'version': version,
    if (count > 0) 'count': count,
    if (hash.isNotEmpty) 'hash': hash,
  };
}

class CollectionsModuleConfig {
  const CollectionsModuleConfig({
    required this.url,
    required this.version,
    this.count = 0,
    this.hash = '',
  });

  final String url;
  final int version;
  final int count;
  final String hash;

  factory CollectionsModuleConfig.fromJson(Map<String, dynamic> json) {
    return CollectionsModuleConfig(
      url: json['url']?.toString() ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
      count: (json['count'] as num?)?.toInt() ?? 0,
      hash: json['hash']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'version': version,
    if (count > 0) 'count': count,
    if (hash.isNotEmpty) 'hash': hash,
  };
}
