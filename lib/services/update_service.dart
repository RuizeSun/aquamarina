import 'dart:io';

import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

/// GitHub Release 信息
class GitHubRelease {
  final String tagName;
  final String name;
  final String body;
  final String htmlUrl;
  final List<GitHubAsset> assets;
  final String publishedAt;

  const GitHubRelease({
    required this.tagName,
    required this.name,
    required this.body,
    required this.htmlUrl,
    required this.assets,
    required this.publishedAt,
  });

  factory GitHubRelease.fromJson(Map<String, dynamic> json) {
    final assetsList = (json['assets'] as List<dynamic>? ?? [])
        .map((a) => GitHubAsset.fromJson(a as Map<String, dynamic>))
        .toList();
    return GitHubRelease(
      tagName: (json['tag_name'] as String?) ?? '',
      name: (json['name'] as String?) ?? '',
      body: (json['body'] as String?) ?? '',
      htmlUrl: (json['html_url'] as String?) ?? '',
      assets: assetsList,
      publishedAt: (json['published_at'] as String?) ?? '',
    );
  }
}

/// GitHub Release 中的资产文件
class GitHubAsset {
  final String name;
  final String browserDownloadUrl;
  final int size;
  final String contentType;

  const GitHubAsset({
    required this.name,
    required this.browserDownloadUrl,
    required this.size,
    required this.contentType,
  });

  factory GitHubAsset.fromJson(Map<String, dynamic> json) {
    return GitHubAsset(
      name: (json['name'] as String?) ?? '',
      browserDownloadUrl: (json['browser_download_url'] as String?) ?? '',
      size: (json['size'] as num?)?.toInt() ?? 0,
      contentType: (json['content_type'] as String?) ?? '',
    );
  }
}

/// 更新检测结果
class UpdateInfo {
  final GitHubRelease release;
  final String latestVersion;
  final String currentVersion;
  final String? downloadUrl;

  const UpdateInfo({
    required this.release,
    required this.latestVersion,
    required this.currentVersion,
    this.downloadUrl,
  });
}

/// 新版本推送频道
enum UpdateChannel {
  /// 稳定：仅当 major 或 minor 版本变更时提示（忽略纯 patch 更新）
  stable('稳定'),

  /// 最新：任何版本变更都提示
  latest('最新'),

  /// 关闭：不进行任何更新检查
  off('关闭');

  /// 显示名称
  final String label;
  const UpdateChannel(this.label);
}

/// 应用更新检测服务
///
/// 通过 GitHub Releases API 检测是否有新版本可用。
/// 支持 24 小时冷却期和版本跳过功能。
class UpdateService {
  UpdateService._();

  static const String _apiUrl =
      'https://api.github.com/repos/RuizeSun/aquamarina/releases/latest';
  static const String _lastCheckKey = 'update_last_check_time';
  static const String _skippedVersionKey = 'update_skipped_version';
  static const String _updateChannelKey = 'update_channel';

  /// 检查间隔：24 小时
  static const Duration _checkInterval = Duration(hours: 24);

  static final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
      headers: {
        'Accept': 'application/vnd.github.v3+json',
        'User-Agent': 'Aquamarina-App',
      },
    ),
  );

  /// 检查是否有新版本可用。
  ///
  /// [force] 为 true 时忽略冷却期，强制检查。
  /// [bypassChannel] 为 true 时忽略频道设置（用于手动检查更新）。
  /// 返回 [UpdateInfo] 如果有新版本，否则返回 null。
  static Future<UpdateInfo?> checkForUpdate({
    bool force = false,
    bool bypassChannel = false,
  }) async {
    try {
      // 读取更新频道，关闭则直接跳过（除非手动绕过）
      final savedChannel = await getUpdateChannel();
      if (!bypassChannel && savedChannel == UpdateChannel.off) return null;

      // 手动绕过时始终使用 latest 频道进行版本比较
      final channel = bypassChannel ? UpdateChannel.latest : savedChannel;

      if (!force && !await _shouldCheck()) {
        return null;
      }

      final response = await _dio.get(_apiUrl);
      if (response.statusCode != 200) return null;

      final release = GitHubRelease.fromJson(
        response.data as Map<String, dynamic>,
      );

      // 记录检查时间
      await _recordCheckTime();

      if (release.tagName.isEmpty) return null;

      // 获取本地版本
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // 根据频道比较版本
      if (!isNewerByChannel(release.tagName, currentVersion, channel)) {
        return null;
      }

      // 检查是否被用户跳过
      final skippedVersion = await getSkippedVersion();
      if (skippedVersion != null && skippedVersion == release.tagName) {
        return null;
      }

      // 根据当前平台选择合适的下载链接
      final downloadUrl = _selectDownloadUrl(release.assets);

      return UpdateInfo(
        release: release,
        latestVersion: release.tagName,
        currentVersion: currentVersion,
        downloadUrl: downloadUrl,
      );
    } catch (_) {
      // 网络请求失败静默处理
      return null;
    }
  }

  /// 比较两个版本号，判断 [remoteVersion] 是否比 [localVersion] 更新。
  ///
  /// 版本号格式：`major.minor.patch`（如 `1.0.8`）
  /// 忽略 pubspec 中的 build number（`+9` 部分由 PackageInfo 处理）。
  static bool isNewerVersion(String remoteVersion, String localVersion) {
    final remote = _parseVersion(remoteVersion);
    final local = _parseVersion(localVersion);
    if (remote == null || local == null) return false;

    for (var i = 0; i < 3; i++) {
      if (remote[i] > local[i]) return true;
      if (remote[i] < local[i]) return false;
    }
    return false;
  }

  /// 根据更新频道判断 [remoteVersion] 是否比 [localVersion] 更应被提示更新。
  ///
  /// - [UpdateChannel.latest]：任何版本号变更都视为有更新（等同于 [isNewerVersion]）。
  /// - [UpdateChannel.stable]：仅当 major 或 minor 版本变更时才视为有更新。
  static bool isNewerByChannel(
    String remoteVersion,
    String localVersion,
    UpdateChannel channel,
  ) {
    if (channel == UpdateChannel.latest) {
      return isNewerVersion(remoteVersion, localVersion);
    }

    // stable 模式：比较 major 和 minor，忽略纯 patch 变更
    final remote = _parseVersion(remoteVersion);
    final local = _parseVersion(localVersion);
    if (remote == null || local == null) return false;

    // major 不同 → 有更新
    if (remote[0] > local[0]) return true;
    if (remote[0] < local[0]) return false;

    // major 相同，minor 不同 → 有更新
    if (remote[1] > local[1]) return true;

    // major 和 minor 都相同 → 不提示（即使 patch 有变更）
    return false;
  }

  /// 获取当前更新频道设置。
  static Future<UpdateChannel> getUpdateChannel() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_updateChannelKey);
    if (index != null && index >= 0 && index < UpdateChannel.values.length) {
      return UpdateChannel.values[index];
    }
    // 默认：最新
    return UpdateChannel.latest;
  }

  /// 设置更新频道并持久化。
  static Future<void> setUpdateChannel(UpdateChannel channel) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_updateChannelKey, channel.index);
  }

  /// 将版本字符串解析为 [major, minor, patch] 列表。
  static List<int>? _parseVersion(String version) {
    // 移除可能的 'v' 前缀
    var v = version.trim();
    if (v.startsWith('v') || v.startsWith('V')) {
      v = v.substring(1);
    }
    // 移除 build number（+N）
    final plusIndex = v.indexOf('+');
    if (plusIndex != -1) {
      v = v.substring(0, plusIndex);
    }

    final parts = v.split('.');
    if (parts.length < 3) return null;

    try {
      return parts.take(3).map(int.parse).toList();
    } catch (_) {
      return null;
    }
  }

  /// 根据当前平台选择合适的下载链接。
  static String? _selectDownloadUrl(List<GitHubAsset> assets) {
    if (assets.isEmpty) return null;

    if (Platform.isAndroid) {
      // 优先选择 arm64-v8a 的 aligned APK
      final aligned = assets.where(
        (a) => a.name.contains('arm64-v8a') && a.name.contains('aligned'),
      );
      if (aligned.isNotEmpty) return aligned.first.browserDownloadUrl;

      // 次选 arm64-v8a 的 signed APK
      final signed = assets.where(
        (a) => a.name.contains('arm64-v8a') && a.name.contains('signed'),
      );
      if (signed.isNotEmpty) return signed.first.browserDownloadUrl;

      // 再选任意 arm64 APK
      final arm64 = assets.where((a) => a.name.contains('arm64-v8a'));
      if (arm64.isNotEmpty) return arm64.first.browserDownloadUrl;

      // 最后选任意 APK
      final anyApk = assets.where(
        (a) => a.name.endsWith('.apk') && a.contentType.contains('android'),
      );
      if (anyApk.isNotEmpty) return anyApk.first.browserDownloadUrl;
    } else if (Platform.isWindows) {
      final windowsZip = assets.where((a) => a.name.contains('windows'));
      if (windowsZip.isNotEmpty) return windowsZip.first.browserDownloadUrl;
    } else if (Platform.isIOS) {
      // iOS 用户通常通过 App Store 更新，返回 Release 页面
      return null;
    }

    // 兜底：返回 Release 页面
    return null;
  }

  /// 打开下载链接或 Release 页面。
  static Future<void> launchUpdate(UpdateInfo updateInfo) async {
    // 优先打开具体下载链接
    final url = updateInfo.downloadUrl ?? updateInfo.release.htmlUrl;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// 打开 Release 页面。
  static Future<void> launchReleasePage(String htmlUrl) async {
    final uri = Uri.parse(htmlUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// 获取用户跳过的版本号。
  static Future<String?> getSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_skippedVersionKey);
  }

  /// 设置用户跳过的版本号。
  static Future<void> setSkippedVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skippedVersionKey, version);
  }

  /// 清除跳过的版本号。
  static Future<void> clearSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_skippedVersionKey);
  }

  /// 判断是否应该检查更新（基于冷却期）。
  static Future<bool> _shouldCheck() async {
    final prefs = await SharedPreferences.getInstance();
    final lastCheckMs = prefs.getInt(_lastCheckKey);
    if (lastCheckMs == null) return true;

    final lastCheck = DateTime.fromMillisecondsSinceEpoch(lastCheckMs);
    return DateTime.now().difference(lastCheck) >= _checkInterval;
  }

  /// 记录本次检查时间。
  static Future<void> _recordCheckTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastCheckKey, DateTime.now().millisecondsSinceEpoch);
  }
}
