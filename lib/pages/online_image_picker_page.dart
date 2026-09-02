import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../data/models/downloaded_image_item.dart';
import '../services/app_logger.dart';
import '../logic/download_manager.dart';
import '../main.dart';
import '../theme/app_palette.dart';
import '../widgets/downloaded_drawer_sheet.dart';
import '../widgets/game_toast.dart';

enum GallerySite {
  pixabay('Pixabay', 'https://pixabay.com/zh/photos/'),
  unsplash('Unsplash', 'https://unsplash.com/'),
  pexels('Pexels', 'https://www.pexels.com/zh-cn/');

  final String label;
  final String url;
  const GallerySite(this.label, this.url);
}

/// Fullscreen online image browser powered by InAppWebView,
/// featuring in-page Back/Forward navigation, explicit Close (X) button,
/// PopScope safety back interception, anti-scraping 403 bypass, and structured logging.
class OnlineImagePickerPage extends StatefulWidget {
  const OnlineImagePickerPage({
    super.key,
    this.initialSite = GallerySite.pixabay,
  });

  final GallerySite initialSite;

  static Future<void> push(
    BuildContext context, {
    GallerySite initialSite = GallerySite.pixabay,
  }) {
    return Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => OnlineImagePickerPage(initialSite: initialSite),
      ),
    );
  }

  @override
  State<OnlineImagePickerPage> createState() => _OnlineImagePickerPageState();
}

class _OnlineImagePickerPageState extends State<OnlineImagePickerPage> {
  InAppWebViewController? _webViewController;
  late GallerySite _currentSite;
  double _loadingProgress = 0.0;
  bool _isExtracting = false;

  // Browser navigation history states
  bool _canGoBack = false;
  bool _canGoForward = false;

  // Timed download notification banner (5 seconds auto-hide + explicit close)
  bool _showDownloadBanner = false;
  DownloadedImageItem? _lastDownloadedItem;
  Timer? _bannerTimer;

  @override
  void initState() {
    super.initState();
    _currentSite = widget.initialSite;
    DownloadManager.instance.init();
    AppLogger.webview.info(
      '[WebView:Init] Platform: ${defaultTargetPlatform.name}, InitialSite: ${_currentSite.label} (${_currentSite.url})',
    );
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    super.dispose();
  }

  Future<void> _updateHistoryState() async {
    if (_webViewController == null) return;
    try {
      final canBack = await _webViewController!.canGoBack();
      final canForward = await _webViewController!.canGoForward();
      if (mounted && (_canGoBack != canBack || _canGoForward != canForward)) {
        setState(() {
          _canGoBack = canBack;
          _canGoForward = canForward;
        });
      }
    } catch (_) {}
  }

  void _switchSite(GallerySite site) {
    if (_currentSite == site) return;
    AppLogger.webview.info(
      '[WebView:SiteSwitch] Switching from ${_currentSite.label} to ${site.label} (${site.url})',
    );
    setState(() {
      _currentSite = site;
      _loadingProgress = 0.1;
    });
    _webViewController?.loadUrl(urlRequest: URLRequest(url: WebUri(site.url)));
  }

  /// Trigger the 5-second auto-dismissing download banner
  void _triggerDownloadBanner(DownloadedImageItem item) {
    _bannerTimer?.cancel();
    setState(() {
      _lastDownloadedItem = item;
      _showDownloadBanner = true;
    });
    _bannerTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _showDownloadBanner = false);
      }
    });
  }

  /// Bypasses anti-scraping Cloudflare 403 by executing fetch inside the webview's authenticated session.
  Future<Uint8List?> _fetchImageBytesInsideWebView(String targetUrl) async {
    if (_webViewController == null) return null;
    AppLogger.webview.info(
      '[WebView:InAppFetch:Start] Executing authenticated in-webview fetch for: $targetUrl',
    );
    final escapedUrl = targetUrl.replaceAll("'", "\\'");
    final jsCode =
        '''
      (async function() {
        try {
          const controller = new AbortController();
          const timeoutId = setTimeout(() => controller.abort(), 25000);
          const res = await fetch('$escapedUrl', {
            credentials: 'include',
            signal: controller.signal
          });
          clearTimeout(timeoutId);
          if (!res.ok) return 'HTTP_' + res.status;
          const contentType = res.headers.get('content-type') || '';
          if (contentType.includes('text/html') || contentType.includes('application/json')) {
            return 'ERR_NOT_IMAGE';
          }
          const blob = await res.blob();
          if (blob.size < 15000) {
            return 'ERR_TOO_SMALL';
          }
          return new Promise((resolve) => {
            const reader = new FileReader();
            reader.onloadend = () => resolve(reader.result);
            reader.onerror = () => resolve('');
            reader.readAsDataURL(blob);
          });
        } catch (e) {
          return 'ERR_' + e.message;
        }
      })();
    ''';
    try {
      final result = await _webViewController!.evaluateJavascript(
        source: jsCode,
      );
      if (result != null) {
        final str = result.toString();
        if (str.startsWith('data:image')) {
          final commaIdx = str.indexOf(',');
          if (commaIdx != -1) {
            final base64Data = str.substring(commaIdx + 1);
            final bytes = base64Decode(base64Data);
            AppLogger.webview.info(
              '[WebView:InAppFetch:Success] Decoded ${bytes.length} bytes from in-webview fetch.',
            );
            return bytes;
          }
        } else {
          AppLogger.webview.warning(
            '[WebView:InAppFetch:Warning] JS returned non-image result: $str',
          );
        }
      }
    } catch (e) {
      AppLogger.webview.severe(
        '[WebView:InAppFetch:Error] In-webview fetch error: $e',
      );
    }
    return null;
  }

  String _upgradeImageUrlToHighRes(String url, String platform) {
    var upgraded = url;
    if (platform == 'Pixabay' || upgraded.contains('pixabay.com')) {
      upgraded = upgraded.replaceAll('__640.', '_1280.');
      upgraded = upgraded.replaceAll('_640.', '_1280.');
      upgraded = upgraded.replaceAll('_340.', '_1280.');
      upgraded = upgraded.replaceAll('_180.', '_1280.');
      upgraded = upgraded.replaceAll('_960_720.', '_1280.');
    } else if (platform == 'Unsplash' || upgraded.contains('unsplash.com')) {
      // If it's a direct download endpoint, keep original raw URL (full 5000+ px resolution)
      if (upgraded.contains('/download') || upgraded.contains('force=true')) {
        return upgraded;
      }
      if (upgraded.contains('w=')) {
        upgraded = upgraded.replaceAll(RegExp(r'w=\d+'), 'w=3840');
      } else if (upgraded.contains('?')) {
        upgraded = '$upgraded&w=3840&q=90';
      } else {
        upgraded = '$upgraded?w=3840&q=90';
      }
    } else if (platform == 'Pexels' || upgraded.contains('pexels.com')) {
      // If it's already a direct download link with chosen resolution, preserve raw URL
      if (upgraded.contains('dl=') || upgraded.contains('download')) {
        return upgraded;
      }
      if (upgraded.contains('w=')) {
        upgraded = upgraded.replaceAll(RegExp(r'w=\d+'), 'w=3840');
      }
    }
    return upgraded;
  }

  /// Smart deep sniffing for the highest resolution image URL on the current webpage
  Future<String> _sniffBestHighResImageUrl() async {
    if (_webViewController == null) return '';
    const js = '''
      (function() {
        const candidates = [];

        // 1. Direct /get/ download links on Pixabay detail page
        const getLinks = Array.from(document.querySelectorAll('a[href*="/get/"], a[href*="attachment="]'));
        for (const a of getLinks) {
          if (a.href && a.href.startsWith('http')) {
            if (a.href.includes('_1920') || a.href.includes('_1280')) return a.href;
            candidates.push(a.href);
          }
        }

        // 2. JSON-LD structured data
        try {
          const scripts = document.querySelectorAll('script[type="application/ld+json"]');
          for (const s of scripts) {
            const data = JSON.parse(s.innerText);
            if (data.contentUrl && typeof data.contentUrl === 'string' && data.contentUrl.startsWith('http')) {
              candidates.push(data.contentUrl);
            }
            if (data.image) {
              if (typeof data.image === 'string' && data.image.startsWith('http')) candidates.push(data.image);
              if (Array.isArray(data.image)) {
                for (const item of data.image) {
                  if (typeof item === 'string') candidates.push(item);
                  else if (item && item.url && item.url.startsWith('http')) candidates.push(item.url);
                }
              }
              if (data.image.url && data.image.url.startsWith('http')) candidates.push(data.image.url);
            }
          }
        } catch (e) {}

        // 3. Download links in detail page
        const dlLinks = Array.from(document.querySelectorAll('a[download], a[href*="download=true"]'));
        for (const a of dlLinks) {
          if (a.href && a.href.startsWith('http')) candidates.push(a.href);
        }

        // 4. Inspect main <img> elements with minimum resolution filter
        const imgs = Array.from(document.querySelectorAll('img')).filter(i => {
          const src = i.currentSrc || i.src || '';
          if (!src.startsWith('http') || src.endsWith('.svg') || src.includes('data:image')) return false;
          if (src.includes('avatar') || src.includes('icon') || src.includes('logo') || src.includes('profile')) return false;
          // Filter out tiny placeholder images
          if (i.naturalWidth > 0 && i.naturalWidth < 250) return false;
          if (i.naturalHeight > 0 && i.naturalHeight < 250) return false;
          return true;
        });

        for (const img of imgs) {
          if (img.srcset) {
            const parts = img.srcset.split(',').map(p => p.trim());
            for (const p of parts) {
              const u = p.split(' ')[0];
              if (u && u.startsWith('http')) candidates.push(u);
            }
          }
          if (img.dataset) {
            for (const k in img.dataset) {
              const val = img.dataset[k];
              if (typeof val === 'string' && val.startsWith('http') && !val.endsWith('.svg')) {
                candidates.push(val);
              }
            }
          }
          const s = img.currentSrc || img.src;
          if (s && s.startsWith('http')) candidates.push(s);
        }

        // 5. Meta og:image
        const og = document.querySelector('meta[property="og:image"]');
        if (og && og.content && og.content.startsWith('http')) {
          candidates.push(og.content);
        }

        const valid = candidates.filter(u => typeof u === 'string' && u.startsWith('http') && !u.endsWith('.svg'));
        
        for (const u of valid) {
          if (u.includes('_1920') || u.includes('_1280') || u.includes('w=2400') || u.includes('w=2560')) return u;
        }

        const cdnMatches = valid.filter(u =>
          u.includes('cdn.pixabay.com') ||
          u.includes('images.unsplash.com') ||
          u.includes('images.pexels.com')
        );
        if (cdnMatches.length > 0) return cdnMatches[0];

        if (valid.length > 0) return valid[0];
        return '';
      })();
    ''';
    try {
      final result = await _webViewController!.evaluateJavascript(source: js);
      final raw = result?.toString().trim() ?? '';
      AppLogger.webview.info('[WebView:Sniff:Result] Sniffed URL: $raw');
      return raw;
    } catch (e) {
      AppLogger.webview.severe(
        '[WebView:Sniff:Error] Sniff execution failed: $e',
      );
      return '';
    }
  }

  /// Handle download triggered either via in-page download button interception or FAB extraction
  Future<void> _handleDownload({
    required String rawUrl,
    bool isFromInterception = false,
  }) async {
    final currentWebUrl =
        (await _webViewController?.getUrl())?.toString() ?? _currentSite.url;
    final targetUrl = _upgradeImageUrlToHighRes(rawUrl, _currentSite.label);

    AppLogger.webview.info(
      '[WebView:DownloadAction] Raw: $rawUrl -> Target: $targetUrl (fromInterception: $isFromInterception)',
    );

    if (DownloadManager.instance.isDownloaded(targetUrl) ||
        DownloadManager.instance.isDownloaded(rawUrl)) {
      AppLogger.webview.info(
        '[WebView:DownloadAction] Image already in download cache.',
      );
      if (mounted) {
        GameToast.show(context, message: '该图片已在下载箱中', type: GameToastType.info);
      }
      return;
    }

    try {
      // 1. Try authenticated in-webview fetch first for zero 403 error
      Uint8List? fetchedBytes = await _fetchImageBytesInsideWebView(targetUrl);
      if (fetchedBytes == null && targetUrl != rawUrl) {
        fetchedBytes = await _fetchImageBytesInsideWebView(rawUrl);
      }

      // 2. Save and strictly validate via DownloadManager
      final item = await DownloadManager.instance.saveOrDownloadImage(
        sourceUrl: targetUrl,
        sourcePlatform: '网络',
        refererUrl: currentWebUrl,
        directBytes: fetchedBytes,
      );

      AppLogger.webview.info(
        '[WebView:DownloadAction:Success] Successfully added to drawer: ${item.id} (${item.width}x${item.height})',
      );

      if (mounted) {
        _triggerDownloadBanner(item);
      }
    } catch (e) {
      AppLogger.webview.severe(
        '[WebView:DownloadAction:Error] Download failed: $e',
      );
      if (mounted) {
        GameToast.show(
          context,
          message: '下载图片失败: $e',
          type: GameToastType.error,
        );
      }
    }
  }

  /// Sniff and extract highest resolution image from the current page
  Future<void> _extractCurrentImage() async {
    if (_isExtracting) return;
    setState(() => _isExtracting = true);
    AppLogger.webview.info(
      '[WebView:Extract:Start] Triggered image extraction button',
    );

    try {
      final detectedUrl = await _sniffBestHighResImageUrl();

      if (detectedUrl.isEmpty || detectedUrl == 'null') {
        AppLogger.webview.warning(
          '[WebView:Extract:NotFound] No suitable image detected on current page.',
        );
        if (mounted) {
          GameToast.show(
            context,
            message: '未在当前页面检测到高清大图，请点击进入照片详情页后再试',
            type: GameToastType.warning,
          );
        }
        return;
      }

      await _handleDownload(rawUrl: detectedUrl);
    } finally {
      if (mounted) setState(() => _isExtracting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    return PopScope(
      canPop: !_canGoBack,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        if (_canGoBack && _webViewController != null) {
          AppLogger.webview.info(
            '[WebView:PopScope] User pressed system back -> Navigating back inside webview',
          );
          await _webViewController!.goBack();
          _updateHistoryState();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(PhosphorIconsBold.x, size: 20),
            onPressed: () {
              AppLogger.webview.info(
                '[WebView:Action] User clicked Close (X) button',
              );
              Navigator.of(context).pop();
            },
            tooltip: '关闭在线选图',
          ),
          titleSpacing: 0,
          title: Center(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: _buildSiteSegmentedTabs(),
            ),
          ),
          actions: [
            // In-page Back Button (Compact)
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              icon: Icon(
                PhosphorIconsBold.caretLeft,
                size: 18,
                color: _canGoBack ? palette.primaryText : Colors.black26,
              ),
              onPressed: _canGoBack
                  ? () async {
                      AppLogger.webview.info(
                        '[WebView:Action] User clicked In-Page Back',
                      );
                      await _webViewController?.goBack();
                      _updateHistoryState();
                    }
                  : null,
              tooltip: '后退',
            ),

            // Browser Refresh Button (Compact)
            IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              icon: const Icon(PhosphorIconsRegular.arrowClockwise, size: 17),
              onPressed: () {
                AppLogger.webview.info('[WebView:Action] User clicked reload.');
                _webViewController?.reload();
              },
              tooltip: '刷新',
            ),

            // Material Box Button with Badge (Compact)
            ValueListenableBuilder<List<DownloadedImageItem>>(
              valueListenable: DownloadManager.instance.itemsNotifier,
              builder: (context, items, _) {
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    IconButton(
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 36,
                        minHeight: 36,
                      ),
                      icon: const Icon(PhosphorIconsBold.archive, size: 19),
                      tooltip: '素材库',
                      onPressed: () => DownloadedDrawerSheet.show(context),
                    ),
                    if (items.isNotEmpty)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: palette.success,
                            shape: BoxShape.circle,
                          ),
                          constraints: const BoxConstraints(
                            minWidth: 16,
                            minHeight: 16,
                          ),
                          child: Text(
                            '${items.length}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(width: 4),
          ],
          bottom: _loadingProgress < 1.0
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(3),
                  child: LinearProgressIndicator(
                    value: _loadingProgress,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      palette.brandLight,
                    ),
                    minHeight: 3,
                  ),
                )
              : null,
        ),
        body: Stack(
          children: [
            // 1. Cross-Platform Embedded InAppWebView
            InAppWebView(
              webViewEnvironment: globalWebViewEnvironment,
              initialUrlRequest: URLRequest(url: WebUri(_currentSite.url)),
              initialSettings: InAppWebViewSettings(
                useShouldOverrideUrlLoading: true,
                useOnDownloadStart: true,
                javaScriptEnabled: true,
                javaScriptCanOpenWindowsAutomatically: true,
                supportMultipleWindows: false,
                mediaPlaybackRequiresUserGesture: false,
                userAgent:
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
                isInspectable: kDebugMode,
                supportZoom: true,
                transparentBackground: false,
                verticalScrollBarEnabled: true,
                horizontalScrollBarEnabled: true,
              ),
              onWebViewCreated: (controller) {
                _webViewController = controller;
                AppLogger.webview.info(
                  '[WebView:Created] InAppWebViewController initialized successfully.',
                );
              },
              onLoadStart: (controller, url) {
                AppLogger.webview.info('[WebView:LoadStart] URL: $url');
                if (mounted) {
                  setState(() => _loadingProgress = 0.1);
                }
                _updateHistoryState();
              },
              onProgressChanged: (controller, progress) {
                if (progress % 25 == 0 || progress == 100) {
                  AppLogger.webview.fine('[WebView:Progress] $progress%');
                }
                if (mounted) {
                  setState(() => _loadingProgress = progress / 100.0);
                }
                _updateHistoryState();
              },
              onLoadStop: (controller, url) async {
                AppLogger.webview.info(
                  '[WebView:LoadStop] Finished loading: $url',
                );
                if (mounted) {
                  setState(() => _loadingProgress = 1.0);
                }
                _updateHistoryState();

                // Inject CSS to clean mobile ads
                await controller.evaluateJavascript(
                  source: '''
                  (function() {
                    const style = document.createElement('style');
                    style.innerHTML = `
                      .app-banner, .mobile-banner, .download-app, #app-banner,
                      [class*="banner-download"], [class*="app-promo"], [class*="AppBanner"] {
                        display: none !important;
                      }
                    `;
                    document.head.appendChild(style);
                  })();
                ''',
                );
              },
              onReceivedError: (controller, request, error) {
                AppLogger.webview.severe(
                  '[WebView:Error] Type: ${error.type}, Description: ${error.description}, FailingURL: ${request.url}',
                );
              },
              onReceivedHttpError: (controller, request, errorResponse) {
                AppLogger.webview.severe(
                  '[WebView:HttpError] Status: ${errorResponse.statusCode}, Reason: ${errorResponse.reasonPhrase}, URL: ${request.url}',
                );
              },
              shouldOverrideUrlLoading: (controller, navigationAction) async {
                final uri = navigationAction.request.url;
                final urlStr = uri?.toString() ?? '';
                AppLogger.webview.fine(
                  '[WebView:Navigation] URL: $urlStr, isMainFrame: ${navigationAction.isForMainFrame}',
                );

                if (urlStr.isEmpty) {
                  return NavigationActionPolicy.ALLOW;
                }

                final lower = urlStr.toLowerCase();
                final pathLower = uri?.path.toLowerCase() ?? '';

                final isImageFile =
                    pathLower.endsWith('.jpg') ||
                    pathLower.endsWith('.jpeg') ||
                    pathLower.endsWith('.png') ||
                    pathLower.endsWith('.webp') ||
                    pathLower.endsWith('.avif');

                // Check if URL is an explicit binary image download trigger
                final isDirectDownload =
                    (lower.contains('pixabay.com/get/')) ||
                    (lower.contains('unsplash.com/photos/') &&
                        lower.contains('/download')) ||
                    (lower.contains('images.pexels.com/') &&
                        (lower.contains('dl=') ||
                            lower.contains('download'))) ||
                    (lower.contains('pexels.com/') && lower.contains('dl=')) ||
                    (lower.contains('images.pexels.com/photos/') &&
                        isImageFile &&
                        navigationAction.isForMainFrame);

                if (isDirectDownload) {
                  AppLogger.webview.fine(
                    '[WebView:Navigation:Intercept] Direct download intercepted: $urlStr',
                  );
                  _handleDownload(rawUrl: urlStr, isFromInterception: true);
                  return NavigationActionPolicy.CANCEL;
                }

                // Allow all ordinary page links, detail links, search submissions, and navigations
                return NavigationActionPolicy.ALLOW;
              },
              onCreateWindow: (controller, createWindowAction) async {
                final targetUrl = createWindowAction.request.url;
                AppLogger.webview.info(
                  '[WebView:CreateWindow] Target URL: $targetUrl',
                );
                if (targetUrl != null) {
                  controller.loadUrl(urlRequest: URLRequest(url: targetUrl));
                }
                return true;
              },
              onDownloadStartRequest: (controller, downloadStartRequest) async {
                final url = downloadStartRequest.url.toString();
                AppLogger.webview.info(
                  '[WebView:DownloadRequest] Intercepted onDownloadStartRequest: $url (MIME: ${downloadStartRequest.mimeType})',
                );
                await _handleDownload(rawUrl: url, isFromInterception: true);
              },
            ),

            // 2. Timed Auto-Dismiss Download Success Banner (Shown for 5 seconds on download, with explicit X button)
            if (_showDownloadBanner && _lastDownloadedItem != null)
              Positioned(
                left: 16,
                right: 16,
                bottom: 90,
                child: AnimatedOpacity(
                  opacity: _showDownloadBanner ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: palette.brand,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black45,
                          blurRadius: 10,
                          offset: Offset(0, 4),
                        ),
                      ],
                      border: Border.all(color: palette.brandLight, width: 1.2),
                    ),
                    child: Row(
                      children: [
                        CircleAvatar(
                          radius: 14,
                          backgroundColor: palette.success,
                          child: const Icon(
                            PhosphorIconsBold.check,
                            size: 16,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                '已存入素材库 (${_lastDownloadedItem!.width}×${_lastDownloadedItem!.height})',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const Text(
                                '来源: 网络 · 点击查看',
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () {
                            setState(() => _showDownloadBanner = false);
                            DownloadedDrawerSheet.show(context);
                          },
                          style: TextButton.styleFrom(
                            backgroundColor: Colors.white24,
                            visualDensity: VisualDensity.compact,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          child: const Text(
                            '制作拼图',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(
                            PhosphorIconsBold.x,
                            size: 16,
                            color: Colors.white70,
                          ),
                          tooltip: '关闭提示',
                          visualDensity: VisualDensity.compact,
                          onPressed: () =>
                              setState(() => _showDownloadBanner = false),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // 2. Compact Top-Right Floating Extraction Pill (Below AppBar, Right-aligned)
            Positioned(
              top: 8,
              right: 10,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: _isExtracting ? null : _extractCurrentImage,
                  borderRadius: BorderRadius.circular(18),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: palette.brand.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: palette.brandLight, width: 1.2),
                      boxShadow: const [
                        BoxShadow(
                          color: Colors.black45,
                          blurRadius: 8,
                          offset: Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_isExtracting)
                          const SizedBox(
                            width: 13,
                            height: 13,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        else
                          const Icon(
                            PhosphorIconsBold.magnifyingGlassPlus,
                            size: 14,
                            color: Colors.white,
                          ),
                        const SizedBox(width: 6),
                        Text(
                          _isExtracting ? '正在提取...' : '提取本页大图',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSiteSegmentedTabs() {
    final palette = AppPalette.of(context);
    return Container(
      height: 36,
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: palette.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: palette.divider, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: GallerySite.values.map((site) {
          final isSelected = _currentSite == site;
          return GestureDetector(
            onTap: () => _switchSite(site),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isSelected ? palette.brand : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Text(
                site.label,
                style: TextStyle(
                  color: isSelected ? Colors.white : palette.secondaryText,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 12,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}
