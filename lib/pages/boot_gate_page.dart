import 'dart:async';

import 'package:flutter/material.dart';

import 'package:jigsawpuzzle/l10n/gen/strings.g.dart';
import 'package:jigsawpuzzle/logic/content/app_content.dart';
import 'package:jigsawpuzzle/pages/main_screen.dart';
import 'package:jigsawpuzzle/services/app_logger.dart';
import 'package:jigsawpuzzle/services/locale_service.dart';
import 'package:jigsawpuzzle/theme/app_palette.dart';
import 'package:jigsawpuzzle/theme/app_text_styles.dart';

/// 首启初始化门面页（BootGate）
///
/// 仅在 [AppContent.isFirstBootReady] == false 时作为 MaterialApp home 出现：
/// - 状态机：initializing（拉 manifest + main 元数据 + 前 4 关原图）→ 成功后
///   无缝切 MainScreen；失败（含 20s 整体超时）→ 失败页 + 重试（D5：不满足
///   条件绝不进首页）。
/// - 老用户（判据齐备）由 main.dart 直接以 MainScreen 起步，本页不参与，0 闪烁。
///
/// 见 docs/home-network-migration-and-boot-init-design-20260907.md §3.1/3.2。
class BootGatePage extends StatefulWidget {
  const BootGatePage({super.key});

  @override
  State<BootGatePage> createState() => _BootGatePageState();
}

enum _BootState { initializing, failed }

class _BootGatePageState extends State<BootGatePage> {
  _BootState _state = _BootState.initializing;

  @override
  void initState() {
    super.initState();
    LocaleService.instance.addListener(_onLocaleChanged);
    // 首帧后开始初始化（确保首帧渲染出加载 UI）
    WidgetsBinding.instance.addPostFrameCallback((_) => _initialize());
  }

  void _onLocaleChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initialize() async {
    setState(() => _state = _BootState.initializing);
    AppLogger.content.info('BootGate initialize start');
    try {
      await AppContent.instance.ensureFirstBootReady();
      AppLogger.content.info('BootGate initialize success');
      if (!mounted) return;
      _enterMain();
      // best-effort：记录后降级继续
      // ignore: avoid_catches_without_on_clauses
    } catch (e, st) {
      AppLogger.content.severe('BootGate initialize failed', e, st);
      if (!mounted) return;
      setState(() => _state = _BootState.failed);
    }
  }

  void _enterMain() {
    // 成功后后台增量同步（daily/events/collections/当月 zip）
    AppContent.instance.backgroundSyncOnce();
    // 页面即将销毁，跳转 Future 无需等待
    unawaited(
      Navigator.of(context).pushReplacement(
        PageRouteBuilder<void>(
          pageBuilder: (_, _, _) => const MainScreen(),
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
        ),
      ),
    );
  }

  @override
  void dispose() {
    LocaleService.instance.removeListener(_onLocaleChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = AppPalette.of(context);
    final styles = AppTextStyles.of(context);
    final tr = LocaleSettings.instance.currentTranslations;
    final isFailed = _state == _BootState.failed;

    return Scaffold(
      backgroundColor: palette.surface,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('🧩', style: TextStyle(fontSize: 64)),
                const SizedBox(height: 20),
                Text(
                  isFailed ? tr.boot.failedTitle : tr.boot.initTitle,
                  style: styles.h2,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                Text(
                  isFailed ? tr.boot.failedDesc : tr.boot.initSubtitle,
                  style: styles.body.copyWith(color: palette.secondaryText),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 28),
                if (isFailed)
                  FilledButton.icon(
                    key: const Key('boot_retry_button'),
                    style: FilledButton.styleFrom(
                      backgroundColor: palette.brand,
                    ),
                    onPressed: _initialize,
                    icon: const Icon(Icons.refresh),
                    label: Text(tr.boot.retry),
                  )
                else
                  SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      color: palette.brand,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
