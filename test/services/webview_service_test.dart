import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jigsawpuzzle/services/webview_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    WebViewService.isOnlineSearchAvailable = true;
    WebViewService.webViewVersion = null;
    WebViewService.environment = null;
  });

  group('WebViewService Availability Tests (flutter_inappwebview)', () {
    test(
      'Non-Windows platform defaults to available without checking WebView2',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        await WebViewService.init();

        expect(WebViewService.isOnlineSearchAvailable, isTrue);
      },
    );

    test(
      'Windows platform with WebView2 installed sets available to true',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;

        bool creatorCalled = false;
        await WebViewService.init(
          versionChecker: () async => '128.0.2739.42',
          appSupportDirFinder: () async => Directory.systemTemp,
          environmentCreator: (settings) async {
            creatorCalled = true;
            return null;
          },
        );

        expect(WebViewService.isOnlineSearchAvailable, isTrue);
        expect(WebViewService.webViewVersion, equals('128.0.2739.42'));
        expect(creatorCalled, isTrue);
      },
    );

    test('Windows platform without WebView2 sets available to false', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      await WebViewService.init(versionChecker: () async => null);

      expect(WebViewService.isOnlineSearchAvailable, isFalse);
      expect(WebViewService.webViewVersion, isNull);
    });

    test(
      'Windows platform with empty version string sets available to false',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;

        await WebViewService.init(versionChecker: () async => '');

        expect(WebViewService.isOnlineSearchAvailable, isFalse);
      },
    );

    test(
      'Windows platform throwing error in check sets available to false',
      () async {
        debugDefaultTargetPlatformOverride = TargetPlatform.windows;

        await WebViewService.init(
          versionChecker: () async => throw Exception('DLL missing'),
        );

        expect(WebViewService.isOnlineSearchAvailable, isFalse);
      },
    );
  });
}
