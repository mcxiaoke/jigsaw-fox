/// 根路由清单模型
class RootManifest {
  const RootManifest({
    required this.schemaVersion,
    required this.updatedAt,
    required this.mainModule,
    required this.dailyModule,
    required this.eventsModule,
    this.notice = '',
    this.minAppVersion = '1.0.0',
  });

  final int schemaVersion;
  final DateTime updatedAt;
  final String notice;
  final String minAppVersion;

  final MainModuleConfig mainModule;
  final DailyModuleConfig dailyModule;
  final EventsModuleConfig eventsModule;

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
      mainModule: MainModuleConfig.fromJson(modules['main'] as Map<String, dynamic>? ?? {}),
      dailyModule: DailyModuleConfig.fromJson(modules['daily'] as Map<String, dynamic>? ?? {}),
      eventsModule: EventsModuleConfig.fromJson(modules['events'] as Map<String, dynamic>? ?? {}),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'schemaVersion': schemaVersion,
      'updatedAt': updatedAt.toIso8601String(),
      'appConfig': {
        'notice': notice,
        'minAppVersion': minAppVersion,
      },
      'modules': {
        'main': mainModule.toJson(),
        'daily': dailyModule.toJson(),
        'events': eventsModule.toJson(),
      },
    };
  }
}

class MainModuleConfig {
  const MainModuleConfig({
    required this.url,
    required this.version,
  });

  final String url;
  final int version;

  factory MainModuleConfig.fromJson(Map<String, dynamic> json) {
    return MainModuleConfig(
      url: json['url']?.toString() ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {'url': url, 'version': version};
}

class DailyModuleConfig {
  const DailyModuleConfig({
    required this.currentMonth,
    required this.zipUrlPattern,
    required this.listUrlPattern,
    required this.version,
  });

  final String currentMonth;
  final String zipUrlPattern;
  final String listUrlPattern;
  final int version;

  factory DailyModuleConfig.fromJson(Map<String, dynamic> json) {
    return DailyModuleConfig(
      currentMonth: json['currentMonth']?.toString() ?? '',
      zipUrlPattern: json['zipUrlPattern']?.toString() ?? '',
      listUrlPattern: json['listUrlPattern']?.toString() ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
    'currentMonth': currentMonth,
    'zipUrlPattern': zipUrlPattern,
    'listUrlPattern': listUrlPattern,
    'version': version,
  };
}

class EventsModuleConfig {
  const EventsModuleConfig({
    required this.url,
    required this.version,
  });

  final String url;
  final int version;

  factory EventsModuleConfig.fromJson(Map<String, dynamic> json) {
    return EventsModuleConfig(
      url: json['url']?.toString() ?? '',
      version: (json['version'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {'url': url, 'version': version};
}
