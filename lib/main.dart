import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'pages/search_page.dart';
import 'pages/vocabulary_page.dart';
import 'pages/ai_practice_page.dart'
    show AiPracticePage, AiPracticePageState, routeObserver;
import 'pages/profile_page.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'services/cloud/cloud_sync_foreground_sync_service.dart';
import 'services/cloud/cloud_sync_compatibility_service.dart';
import 'services/cloud/cloud_sync_settings.dart';
import 'services/cloud/cloud_sync_version_gate_service.dart';
import 'services/data/database_service.dart';
import 'services/data/dictionary_service.dart';
import 'services/cloud/sync_data_change_notifier.dart';
import 'services/tts/tts_service.dart';
import 'services/ai/ai_profile_service.dart';
import 'services/system/theme_mode_service.dart';
import 'services/system/update_service.dart';
import 'services/data/study_timer_service.dart';
import 'services/system/log_service.dart';
import 'services/cloud/sync_capture_service.dart';
import 'models/ai_profile.dart';

/// 云同步配置完整时，确保 SQLite 变更捕获处于开启状态。
///
/// 捕获开关是数据库里的持久状态；恢复快照、旧版本升级或异常退出都可能让它
/// 变成 0。必须在任何业务写入（包括闪退恢复）之前校正，否则新数据不会进入
/// oplog，后续增量同步永远看不到这些变更。
Future<void> _ensureCloudSyncCaptureEnabled() async {
  try {
    if (!await CloudSyncSettings.hasCompleteConfiguration()) return;
    if (await SyncCaptureService.isCaptureEnabled()) return;
    await SyncCaptureService.setCaptureEnabled(enabled: true);
    logInfo('CloudSync', '启动时已自动开启同步变更捕获');
  } catch (e) {
    logWarning('CloudSync', '启动时确保同步变更捕获失败: $e');
  }
}

/// 后台预热词典数据库，失败时记录日志（搜索页会给用户明确提示）
Future<void> _prewarmDictionaries() async {
  try {
    await DictionaryService.enDb;
    await DictionaryService.cnDb;
    logInfo('DictionaryService', '词典数据库预热完成');
  } catch (e, stackTrace) {
    logError('DictionaryService', '词典数据库预热失败: $e', stackTrace);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── 初始化日志服务 ──────────────────────────────
  await LogService.instance.load();
  logInfo('App', '应用启动');

  // ── 全局未捕获异常处理器 ──────────────────────────
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    logError('FlutterError', '${details.exception}', details.stack);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    logError('Platform', '$error', stack);
    return true;
  };

  // ── 关键服务初始化（失败时仍启动 App 并显示错误提示）──
  Object? initError;
  try {
    await DatabaseService.database; // 初始化业务数据库
    logInfo('DatabaseService', '业务数据库初始化完成');
    await SharedPreferences.getInstance(); // 预热 SharedPreferences

    // 先确保云同步捕获已开启，再执行任何可能写库的启动逻辑
    await _ensureCloudSyncCaptureEnabled();

    // 清理上次未正常结束的学习会话（闪退恢复）
    await StudyTimerService.recoverInterruptedSessions();
    logInfo('StudyTimerService', '中断会话恢复完成');
  } catch (e, stackTrace) {
    logError('DatabaseService', '数据库初始化失败: $e', stackTrace);
    initError = e;
  }

  // 自动创建 Aquamarina 官方 AI 配置（首次启动时）
  try {
    final profileService = AiProfileService();
    await profileService.load();
    if (profileService.profiles.isEmpty) {
      final defaultProfile = createProfileFromTemplate(
        AiProfileTemplate.aquamarinaOfficial,
      ).copyWith(isDefault: true);
      await profileService.addProfile(defaultProfile);
      logInfo('AiProfileService', '已创建默认 AI 配置');
    } else {
      logInfo(
        'AiProfileService',
        'AI 配置加载完成，共 ${profileService.profiles.length} 个',
      );
    }
  } catch (e, stackTrace) {
    logError('AiProfileService', 'AI 配置初始化失败: $e', stackTrace);
  }

  // 预热词典数据库（在后台解压 + 打开，避免首次搜词时阻塞）
  // 后台加载失败时记录日志，搜索页会给出明确的错误提示
  unawaited(_prewarmDictionaries());

  // ── 开源许可证注册保持原样 ─────────────────────────

  // 注册开源许可证
  LicenseRegistry.addLicense(() async* {
    // ecdict (星火词典) - MIT License
    yield LicenseEntryWithLineBreaks(
      ['ecdict (星火词典)'],
      '''MIT License

Copyright (c) 2024 skywind3000

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''',
    );
  });

  LicenseRegistry.addLicense(() async* {
    // CC-CEDICT - MIT License
    yield LicenseEntryWithLineBreaks(
      ['CC-CEDICT'],
      '''MIT License

Copyright (c) 2024 MDBG

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.''',
    );
  });

  runApp(AquamarinaApp(initError: initError));
}

class AquamarinaApp extends StatefulWidget {
  /// 数据库/关键服务初始化失败时的错误信息（为 null 表示初始化成功）
  final Object? initError;

  const AquamarinaApp({super.key, this.initError});

  @override
  State<AquamarinaApp> createState() => _AquamarinaAppState();
}

class _AquamarinaAppState extends State<AquamarinaApp> {
  Timer? _autoSyncTimer;
  late final AppLifecycleListener _syncLifecycleListener;

  @override
  void initState() {
    super.initState();
    ThemeModeService.instance.load();

    // 启动 5 秒后启动前台轮询（首次 tick 会立即尝试一次同步）
    _autoSyncTimer = Timer(const Duration(seconds: 5), () {
      unawaited(CloudSyncForegroundSyncService.instance.start());
    });
    _syncLifecycleListener = AppLifecycleListener(
      onResume: () =>
          unawaited(CloudSyncForegroundSyncService.instance.start()),
      onHide: CloudSyncForegroundSyncService.instance.stop,
      onPause: CloudSyncForegroundSyncService.instance.stop,
    );

    // 关键服务初始化失败时向用户弹窗提示
    final initError = widget.initError;
    if (initError != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.error_outline, color: Colors.red),
            title: const Text('初始化失败'),
            content: Text(
              '数据库初始化失败，部分功能可能无法使用。\n\n错误信息：$initError\n\n'
              '您可以尝试在「设置 → 数据管理」中导入备份或清除数据后重试。',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('知道了'),
              ),
            ],
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _autoSyncTimer?.cancel();
    _autoSyncTimer = null;
    CloudSyncForegroundSyncService.instance.stop();
    _syncLifecycleListener.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        ThemeModeService.instance.mode,
        ThemeModeService.instance.seedColor,
      ]),
      builder: (context, _) {
        final themeMode = ThemeModeService.instance.mode.value;
        final seedColor = ThemeModeService.instance.seedColor.value;
        return MaterialApp(
          title: 'Aquamarina',
          debugShowCheckedModeBanner: false,
          navigatorObservers: [routeObserver],
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: seedColor,
              brightness: Brightness.light,
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: seedColor,
              brightness: Brightness.dark,
            ),
          ),
          themeMode: themeMode,
          home: const MainShell(),
        );
      },
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _selectedIndex = 0;
  final GlobalKey<VocabularyPageState> _vocabularyKey = GlobalKey();
  final GlobalKey<AiPracticePageState> _aiPracticeKey =
      GlobalKey<AiPracticePageState>();
  final GlobalKey<ProfilePageState> _profileKey = GlobalKey<ProfilePageState>();

  /// 启动后延迟检查更新的定时器（dispose 时必须取消，避免泄漏与测试报错）
  Timer? _updateTimer;

  /// 版本阻断 / 版本差异弹窗是否正在展示，避免并发重复弹窗。
  bool _versionDialogShowing = false;

  @override
  void initState() {
    super.initState();
    // 初始化 TTS 服务
    TtsService.instance.init();
    // 云同步版本提示：后台同步只发布状态，由主界面负责弹窗。
    CloudSyncVersionGateService.instance.notice.addListener(_onVersionNotice);
    // 自动同步把远端数据写入本地后，立即刷新当前可见的主 Tab。
    SyncDataChangeNotifier.instance.addListener(_onRemoteDataChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(CloudSyncVersionGateService.instance.restore());
    });
    // 延迟检测应用更新（等待首屏渲染完成）
    _updateTimer = Timer(const Duration(seconds: 3), _checkForUpdate);
  }

  @override
  void dispose() {
    CloudSyncVersionGateService.instance.notice.removeListener(
      _onVersionNotice,
    );
    SyncDataChangeNotifier.instance.removeListener(_onRemoteDataChanged);
    _updateTimer?.cancel();
    _updateTimer = null;
    super.dispose();
  }

  void _onVersionNotice() {
    final result = CloudSyncVersionGateService.instance.notice.value;
    if (!mounted || result == null || _versionDialogShowing) return;
    unawaited(_showVersionDialog(result));
  }

  /// 自动 / 手动云同步应用远端变更后刷新当前可见的主 Tab。
  ///
  /// 隐藏的 Tab 在用户切换时由 [_onTabSelected] 刷新，避免每次同步都对
  /// 所有常驻页面重复查询数据库。
  void _onRemoteDataChanged() {
    if (!mounted) return;
    if (_selectedIndex == 1) {
      _vocabularyKey.currentState?.refresh();
    } else if (_selectedIndex == 2) {
      _aiPracticeKey.currentState?.refresh();
    } else if (_selectedIndex == 3) {
      _profileKey.currentState?.refresh();
    }
  }

  Future<void> _showVersionDialog(CloudSyncCompatibilityResult result) async {
    _versionDialogShowing = true;
    final blocked = result.isBlocked;
    final action = await showDialog<String>(
      context: context,
      barrierDismissible: !blocked,
      builder: (context) {
        final colorScheme = Theme.of(context).colorScheme;
        return AlertDialog(
          icon: Icon(
            blocked ? Icons.sync_problem_rounded : Icons.devices_rounded,
            color: blocked ? colorScheme.error : colorScheme.primary,
            size: 36,
          ),
          title: Text(blocked ? '云同步已暂停' : '设备版本不一致'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(result.reason),
                if (blocked) ...[
                  const SizedBox(height: 12),
                  Text(
                    '本机的新记录仍会保存在本地 oplog 中，升级后会自动继续上传，不会丢失。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (blocked)
              TextButton(
                onPressed: () => Navigator.of(context).pop('update'),
                child: const Text('检查更新'),
              ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('知道了'),
            ),
          ],
        );
      },
    );
    _versionDialogShowing = false;
    await CloudSyncVersionGateService.instance.dismiss(result.signature);
    if (action == 'update' && mounted) {
      final updateInfo = await UpdateService.checkForUpdate();
      if (!mounted) return;
      if (updateInfo == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('当前没有可用更新，请稍后重试或手动检查更新。'),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      _showUpdateDialog(updateInfo);
    }
  }

  /// 检查应用更新，发现新版本时弹窗提示。
  Future<void> _checkForUpdate() async {
    final updateInfo = await UpdateService.checkForUpdate();
    if (!mounted || updateInfo == null) return;
    _showUpdateDialog(updateInfo);
  }

  /// 展示更新提示弹窗。
  void _showUpdateDialog(UpdateInfo updateInfo) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.system_update_rounded,
          color: colorScheme.primary,
          size: 36,
        ),
        title: Text('发现新版本 ${updateInfo.latestVersion}'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '当前版本: ${updateInfo.currentVersion}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '更新日志',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                updateInfo.release.body.isNotEmpty
                    ? updateInfo.release.body
                    : '暂无更新日志',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              UpdateService.setSkippedVersion(updateInfo.latestVersion);
              Navigator.of(context).pop();
            },
            child: const Text('跳过此版本'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('稍后提醒'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop();
              UpdateService.launchUpdate(updateInfo);
            },
            child: const Text('立即更新'),
          ),
        ],
      ),
    );
  }

  void _onTabSelected(int index) {
    setState(() {
      _selectedIndex = index;
    });
    // 切到背词Tab时立即刷新
    if (index == 1) {
      _vocabularyKey.currentState?.refresh();
    }
    // 切到句型练习Tab时立即刷新
    if (index == 2) {
      _aiPracticeKey.currentState?.refresh();
    }
    // 切到个人Tab时立即刷新
    if (index == 3) {
      _profileKey.currentState?.refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: [
          const SearchPage(),
          VocabularyPage(key: _vocabularyKey),
          AiPracticePage(key: _aiPracticeKey),
          ProfilePage(key: _profileKey),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onTabSelected,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.search),
            selectedIcon: Icon(Icons.search_rounded),
            label: '搜索',
          ),
          NavigationDestination(
            icon: Icon(Icons.auto_stories_outlined),
            selectedIcon: Icon(Icons.auto_stories_rounded),
            label: '背单词',
          ),
          NavigationDestination(
            icon: Icon(Icons.smart_toy_outlined),
            selectedIcon: Icon(Icons.smart_toy_rounded),
            label: '句型练习',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person_rounded),
            label: '个人',
          ),
        ],
      ),
    );
  }
}
