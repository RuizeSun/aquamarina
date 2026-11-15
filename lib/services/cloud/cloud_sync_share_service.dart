import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:zxing2/qrcode.dart';

import '../../models/cloud_sync_share_payload.dart';
import '../system/log_service.dart';
import 'cloud_sync_foreground_sync_service.dart';
import 'cloud_sync_run_lock.dart';
import 'cloud_sync_service.dart';
import 'cloud_sync_settings.dart';
import 'sync_capture_service.dart';

/// 二维码导入的落地结果。
class CloudSyncShareApplyResult {
  final CloudSyncConfig config;

  /// 导入后本机实际生效的凭据；二维码不含密钥且原本也没有时为 null。
  final CloudSyncCredentials? credentials;

  /// 后端身份（endpoint / bucket / prefix …）是否发生变化。
  final bool backendChanged;

  /// 因为切换后端而清除了原本保存的密钥（需要用户补填）。
  final bool credentialsCleared;

  const CloudSyncShareApplyResult({
    required this.config,
    required this.credentials,
    required this.backendChanged,
    required this.credentialsCleared,
  });

  /// 导入后是否已经具备完整配置（可直接同步）。
  bool get isReady =>
      config.isConfigured && (credentials?.isComplete ?? false);
}

/// 云同步配置二维码的分享与导入。
///
/// 与 [CloudSyncService] 的分工：
/// - 这里只负责「把一份配置安全地写进本机」与「从图片字节里解出文本」；
/// - 后端切换后的水位/去重清理由 `CloudSyncEngine._ensureBackend` 自动完成，
///   业务数据清理由既有的「首次接入」流程处理，本类不复制这些逻辑。
class CloudSyncShareService {
  CloudSyncShareService._();

  /// 图片解码上限：超过后直接拒绝，避免超大截图占满内存。
  static const int maxImageBytes = 20 * 1024 * 1024;

  static const String _logTag = 'CloudSyncShare';

  /// 读取本机当前配置并生成分享载荷；未配置时返回 null。
  ///
  /// [includeCredentials] 为 false 时生成「不含密钥」的载荷：即使本机保存了
  /// 密钥也不会写进二维码。
  static Future<CloudSyncSharePayload?> loadCurrent({
    bool includeCredentials = true,
  }) async {
    final config = await CloudSyncSettings.loadConfig();
    if (config == null || !config.isConfigured) return null;
    CloudSyncCredentials? credentials;
    if (includeCredentials) {
      credentials = await CloudSyncSettings.loadCredentials();
    }
    final deviceId = await CloudSyncSettings.getOrCreateDeviceId();
    final deviceName = await CloudSyncSettings.getOrCreateDeviceName(deviceId);
    return CloudSyncSharePayload.fromConfig(
      config: config,
      credentials: credentials?.isComplete == true ? credentials : null,
      deviceName: deviceName,
    );
  }

  /// 文本解析入口：非本应用的文本一律返回 null，不抛异常。
  static CloudSyncSharePayload? tryDecodeText(String? text) {
    if (text == null || text.trim().isEmpty) return null;
    try {
      return CloudSyncSharePayload.decode(text);
    } catch (_) {
      return null;
    }
  }

  /// 把图片字节交给 zxing2 识别；识别失败 / 非二维码 / 超大图均返回 null。
  ///
  /// 纯 Dart 实现，Android / iOS / Windows 行为一致，不依赖相机插件。
  static String? decodeImageBytes(Uint8List bytes) {
    if (bytes.isEmpty || bytes.length > maxImageBytes) return null;
    img.Image? decoded;
    try {
      decoded = img.decodeImage(bytes);
    } catch (_) {
      return null;
    }
    if (decoded == null) return null;
    try {
      // zxing2 需要 ARGB（每像素一个 int32）；先把图像归一到 4 通道。
      final rgba = decoded.convert(numChannels: 4);
      final source = RGBLuminanceSource(
        decoded.width,
        decoded.height,
        rgba.getBytes(order: img.ChannelOrder.abgr).buffer.asInt32List(),
      );
      final bitmap = BinaryBitmap(GlobalHistogramBinarizer(source));
      return QRCodeReader().decode(bitmap).text;
    } catch (_) {
      // 找不到二维码、图像过小、格式不支持都会走到这里，交由 UI 统一提示。
      return null;
    }
  }

  /// 解析图片字节为分享载荷（在解码基础上再做一次格式校验）。
  static CloudSyncSharePayload? parseImageBytes(Uint8List bytes) {
    final text = decodeImageBytes(bytes);
    if (text == null) return null;
    return tryDecodeText(text);
  }

  /// 把载荷写入本机配置。
  ///
  /// 关键规则（见 `docs/cloud-sync-spec.md` 的凭据约束）：
  /// - 载荷含密钥 → 直接覆盖；
  /// - 载荷不含密钥且后端未变化 → 保留本机原凭据（重复扫同一张码不丢密钥）；
  /// - 载荷不含密钥且后端已变化 → 清除凭据，绝不把 A 后端的密钥发往 B 后端。
  static Future<CloudSyncShareApplyResult> applyPayload(
    CloudSyncSharePayload payload,
  ) async {
    return CloudSyncRunLock.runExclusive(() async {
      final nextConfig = payload.toConfig();
      final previousConfig = await CloudSyncSettings.loadConfig();
      final previousCredentials = await CloudSyncSettings.loadCredentials();
      final backendChanged =
          previousConfig?.backendIdentity != nextConfig.backendIdentity;

      // 切换后端期间停止前台轮询，避免轮询读到半写状态。
      CloudSyncForegroundSyncService.instance.stop();

      await CloudSyncSettings.saveConfig(nextConfig);

      CloudSyncCredentials? effective;
      var cleared = false;
      final incoming = payload.toCredentials();
      if (incoming != null) {
        effective = incoming;
        await CloudSyncSettings.saveCredentials(incoming);
      } else if (!backendChanged) {
        effective = previousCredentials;
      } else if (previousCredentials != null) {
        await CloudSyncSettings.clearCredentials();
        cleared = true;
      }

      if (payload.deviceName.isNotEmpty) {
        await CloudSyncSettings.saveDeviceName(payload.deviceName);
      }

      // 配置完整时立即开启变更捕获；失败不影响配置落地（与配置页一致）。
      try {
        await SyncCaptureService.setCaptureEnabled(enabled: true);
      } catch (_) {}

      await CloudSyncSettings.updateState(
        (state) => state.copyWith(
          clearError: true,
          clearBackoff: true,
          consecutiveFailures: 0,
        ),
      );

      logInfo(
        _logTag,
        '已导入二维码配置 endpoint=${nextConfig.endpoint} '
        'bucket=${nextConfig.bucket} prefix=${nextConfig.prefix} '
        'containsSecrets=${incoming != null} backendChanged=$backendChanged '
        'credentialsCleared=$cleared',
      );

      // 导入后立即启动前台轮询；未配置 / 关闭自动同步时会自行停止。
      CloudSyncForegroundSyncService.instance.start();

      return CloudSyncShareApplyResult(
        config: nextConfig,
        credentials: effective,
        backendChanged: backendChanged,
        credentialsCleared: cleared,
      );
    });
  }

  /// 验证载荷能否真正连上对象存储；语义与配置页「测试连接」一致。
  static Future<String> testConfig(
    CloudSyncConfig config,
    CloudSyncCredentials credentials,
  ) {
    return CloudSyncService.testConfig(config, credentials);
  }
}
