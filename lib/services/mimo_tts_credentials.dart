import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'log_service.dart';

/// 小米 MiMo TTS 的 API Key 存储（Secure Storage）
///
/// 与 AI 配置一致，敏感信息不落 SharedPreferences。
/// 备份导出白名单见 `BackupService._exportSecureStorage()`，新增 key 时需同步维护。
class MimoTtsCredentials {
  MimoTtsCredentials._();

  /// Secure Storage 中保存 MiMo API Key 的 key
  static const String storageKey = 'tts_mimo_api_key';

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  /// 读取 API Key（未配置或读取失败时返回空串）
  static Future<String> read() async {
    try {
      return await _storage.read(key: storageKey) ?? '';
    } catch (e) {
      logWarning('MimoTtsCredentials', '读取 API Key 失败: $e');
      return '';
    }
  }

  /// 保存 API Key（传入空串表示清除）
  static Future<void> save(String apiKey) async {
    final trimmed = apiKey.trim();
    try {
      if (trimmed.isEmpty) {
        await _storage.delete(key: storageKey);
        logInfo('MimoTtsCredentials', '已清除 API Key');
      } else {
        await _storage.write(key: storageKey, value: trimmed);
        logInfo('MimoTtsCredentials', '已保存 API Key');
      }
    } catch (e) {
      logError('MimoTtsCredentials', '保存 API Key 失败: $e');
      rethrow;
    }
  }

  /// 是否已配置 API Key
  static Future<bool> isConfigured() async => (await read()).isNotEmpty;
}
