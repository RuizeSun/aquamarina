import 'package:shared_preferences/shared_preferences.dart';

import '../../models/ai_chat.dart';
import '../../models/ai_context.dart';
import 'ai_image_service.dart';

/// AI 对话的本地设置（SharedPreferences）。
///
/// 所有读写都做越界收敛（clamp），避免手工改坏的偏好值把 UI 撑爆。
/// 除「对话使用的配置」外都只影响本机，不参与云同步。
class AiChatSettings {
  AiChatSettings({SharedPreferences? prefs}) : _injected = prefs;

  final SharedPreferences? _injected;

  // ── 键名 ──────────────────────────────────────────
  static const String profileIdKey = 'ai_chat_profile_id';
  static const String systemPromptKey = 'ai_chat_system_prompt';
  static const String temperatureOverrideKey = 'ai_chat_temperature_override';
  static const String maxTokensOverrideKey = 'ai_chat_max_tokens_override';
  static const String contextMessagesKey = 'ai_chat_context_messages';
  static const String contextCompressionEnabledKey =
      'ai_chat_context_compression_enabled';
  static const String contextThresholdModeKey =
      'ai_chat_context_threshold_mode';
  static const String contextThresholdTokensKey =
      'ai_chat_context_threshold_tokens';
  static const String contextThresholdRatioKey =
      'ai_chat_context_threshold_ratio';
  static const String toolsEnabledKey = 'ai_chat_tools_enabled';
  static const String toolDisabledNamesKey = 'ai_chat_tool_disabled_names';
  static const String autoApproveReadOnlyKey = 'ai_chat_auto_approve_readonly';
  static const String maxToolRoundsKey = 'ai_chat_max_tool_rounds';
  static const String streamEnabledKey = 'ai_chat_stream_enabled';
  static const String imageSendModeKey = 'ai_chat_image_send_mode';
  static const String imageThumbnailSizeKey = 'ai_chat_image_thumbnail_size';
  static const String injectRuntimeContextKey =
      'ai_chat_inject_runtime_context';
  static const String injectTimeContextKey = 'ai_chat_inject_time_context';
  static const String showUsageBadgeKey = 'ai_chat_show_usage_badge';

  // ── 取值范围 ──────────────────────────────────────
  static const int minContextMessages = AiContextPolicy.minMessageCount;
  static const int maxContextMessages = AiContextPolicy.maxMessageCount;
  static const int defaultContextMessages = AiContextPolicy.defaultMessageCount;

  static const int minMaxTokens = 64;
  static const int maxMaxTokens = 8192;

  static const int minToolRounds = 1;
  static const int maxToolRounds = 10;
  static const int defaultToolRounds = 5;

  /// 默认系统提示词：说明身份、可用能力，以及「写操作需要用户批准」。
  static const String defaultSystemPrompt =
      '你是 Aquamarina 英语学习助手中的对话助手。你可以调用 App 内的工具来查询'
      '词典、词书、学习统计与句式集等信息。任何会修改用户数据的操作都必须经用户'
      '批准后才执行；被拒绝时请尊重用户的选择，不要反复请求。回答用简体中文，'
      '必要时补充英文例句。\n\n'
      '用户消息末尾可能出现 <context-note> 区块，那是系统自动注入的上下文'
      '（App 版本、数据库 schema、当前时间等），**不是用户输入的内容**。'
      '这些信息已经是最新的，不要为了确认版本或时间而调用工具，也不要因为它'
      '出现在末尾就以为用户改变了话题。只有当用户明确要求重新核对、或你发现'
      '注入内容与实际不符时，才调用 get_app_info 等工具复查。';

  Future<SharedPreferences> get _prefs async =>
      _injected ?? await SharedPreferences.getInstance();

  // ── 配置选择 ──────────────────────────────────────

  /// 对话使用的 AI 配置 id；null 表示使用默认配置。
  Future<String?> getProfileId() async {
    final prefs = await _prefs;
    final value = prefs.getString(profileIdKey);
    if (value == null || value.isEmpty) return null;
    return value;
  }

  Future<void> setProfileId(String? id) async {
    final prefs = await _prefs;
    if (id == null || id.isEmpty) {
      await prefs.remove(profileIdKey);
    } else {
      await prefs.setString(profileIdKey, id);
    }
  }

  // ── 系统提示词 ────────────────────────────────────

  Future<String> getSystemPrompt() async {
    final prefs = await _prefs;
    final value = prefs.getString(systemPromptKey);
    if (value == null || value.trim().isEmpty) return defaultSystemPrompt;
    return value;
  }

  Future<void> setSystemPrompt(String prompt) async {
    final prefs = await _prefs;
    final trimmed = prompt.trim();
    if (trimmed.isEmpty) {
      await prefs.remove(systemPromptKey);
    } else {
      await prefs.setString(systemPromptKey, trimmed);
    }
  }

  // ── 采样参数覆盖 ──────────────────────────────────

  /// 温度覆盖值；null 表示沿用所选配置的值。
  Future<double?> getTemperatureOverride() async {
    final prefs = await _prefs;
    final value = prefs.getDouble(temperatureOverrideKey);
    if (value == null) return null;
    return value.clamp(0.0, 2.0);
  }

  Future<void> setTemperatureOverride(double? value) async {
    final prefs = await _prefs;
    if (value == null) {
      await prefs.remove(temperatureOverrideKey);
    } else {
      await prefs.setDouble(temperatureOverrideKey, value.clamp(0.0, 2.0));
    }
  }

  /// 最大输出 token 覆盖值；null 表示沿用所选配置的值。
  Future<int?> getMaxTokensOverride() async {
    final prefs = await _prefs;
    final value = prefs.getInt(maxTokensOverrideKey);
    if (value == null) return null;
    return value.clamp(minMaxTokens, maxMaxTokens);
  }

  Future<void> setMaxTokensOverride(int? value) async {
    final prefs = await _prefs;
    if (value == null) {
      await prefs.remove(maxTokensOverrideKey);
    } else {
      await prefs.setInt(
        maxTokensOverrideKey,
        value.clamp(minMaxTokens, maxMaxTokens),
      );
    }
  }

  // ── 上下文处理 ────────────────────────────────────

  /// 读取完整的上下文处理策略（消息条数 + 摘要压缩阈值）。
  Future<AiContextPolicy> getContextPolicy() async {
    final prefs = await _prefs;
    final messages = prefs.getInt(contextMessagesKey) ?? defaultContextMessages;
    final enabled = prefs.getBool(contextCompressionEnabledKey) ?? false;
    final mode = AiContextThresholdMode.fromName(
      prefs.getString(contextThresholdModeKey),
    );
    final tokens =
        prefs.getInt(contextThresholdTokensKey) ??
        AiContextPolicy.defaultAbsoluteThreshold;
    final ratio =
        prefs.getDouble(contextThresholdRatioKey) ??
        AiContextPolicy.defaultRatio;
    return AiContextPolicy(
      maxMessages: messages,
      compressionEnabled: enabled,
      thresholdMode: mode,
      absoluteThreshold: tokens,
      ratioThreshold: ratio,
    ).normalized();
  }

  Future<void> setContextPolicy(AiContextPolicy policy) async {
    final prefs = await _prefs;
    final normalized = policy.normalized();
    await prefs.setInt(contextMessagesKey, normalized.maxMessages);
    await prefs.setBool(
      contextCompressionEnabledKey,
      normalized.compressionEnabled,
    );
    await prefs.setString(
      contextThresholdModeKey,
      normalized.thresholdMode.name,
    );
    await prefs.setInt(contextThresholdTokensKey, normalized.absoluteThreshold);
    await prefs.setDouble(contextThresholdRatioKey, normalized.ratioThreshold);
  }

  /// 仅消息条数（兼容旧调用点 / 旧偏好键）。
  Future<int> getContextMessages() async {
    final policy = await getContextPolicy();
    return policy.maxMessages;
  }

  Future<void> setContextMessages(int value) async {
    final policy = await getContextPolicy();
    await setContextPolicy(policy.copyWith(maxMessages: value));
  }

  // ── 上下文自动注入 ────────────────────────────────

  /// 是否把运行环境信息（版本 / schema / 平台）注入系统提示词。
  Future<bool> getInjectRuntimeContext() async {
    final prefs = await _prefs;
    return prefs.getBool(injectRuntimeContextKey) ?? true;
  }

  Future<void> setInjectRuntimeContext(bool value) async {
    final prefs = await _prefs;
    await prefs.setBool(injectRuntimeContextKey, value);
  }

  /// 是否注入当前时间（每轮请求刷新）。
  Future<bool> getInjectTimeContext() async {
    final prefs = await _prefs;
    return prefs.getBool(injectTimeContextKey) ?? true;
  }

  Future<void> setInjectTimeContext(bool value) async {
    final prefs = await _prefs;
    await prefs.setBool(injectTimeContextKey, value);
  }

  // ── 消息角标 ──────────────────────────────────────

  /// 是否在每条消息下方显示 token / 费用角标（默认开启）。
  Future<bool> getShowUsageBadge() async {
    final prefs = await _prefs;
    return prefs.getBool(showUsageBadgeKey) ?? true;
  }

  Future<void> setShowUsageBadge(bool value) async {
    final prefs = await _prefs;
    await prefs.setBool(showUsageBadgeKey, value);
  }

  // ── 工具调用 ──────────────────────────────────────

  Future<bool> getToolsEnabled() async {
    final prefs = await _prefs;
    return prefs.getBool(toolsEnabledKey) ?? true;
  }

  Future<void> setToolsEnabled(bool value) async {
    final prefs = await _prefs;
    await prefs.setBool(toolsEnabledKey, value);
  }

  /// 被用户关停的工具名（黑名单）。
  Future<Set<String>> getDisabledToolNames() async {
    final prefs = await _prefs;
    final list = prefs.getStringList(toolDisabledNamesKey) ?? const [];
    return list.toSet();
  }

  Future<void> setDisabledToolNames(Set<String> names) async {
    final prefs = await _prefs;
    await prefs.setStringList(toolDisabledNamesKey, names.toList()..sort());
  }

  /// 与工具全集的差集，供请求组装使用。
  Future<Set<String>> enabledToolNames(Iterable<String> allNames) async {
    final disabled = await getDisabledToolNames();
    return allNames.where((name) => !disabled.contains(name)).toSet();
  }

  Future<bool> getAutoApproveReadOnly() async {
    final prefs = await _prefs;
    return prefs.getBool(autoApproveReadOnlyKey) ?? true;
  }

  Future<void> setAutoApproveReadOnly(bool value) async {
    final prefs = await _prefs;
    await prefs.setBool(autoApproveReadOnlyKey, value);
  }

  Future<int> getMaxToolRounds() async {
    final prefs = await _prefs;
    final value = prefs.getInt(maxToolRoundsKey) ?? defaultToolRounds;
    return value.clamp(minToolRounds, maxToolRounds);
  }

  Future<void> setMaxToolRounds(int value) async {
    final prefs = await _prefs;
    await prefs.setInt(
      maxToolRoundsKey,
      value.clamp(minToolRounds, maxToolRounds),
    );
  }

  // ── 流式 ──────────────────────────────────────────

  Future<bool> getStreamEnabled() async {
    final prefs = await _prefs;
    return prefs.getBool(streamEnabledKey) ?? true;
  }

  Future<void> setStreamEnabled(bool value) async {
    final prefs = await _prefs;
    await prefs.setBool(streamEnabledKey, value);
  }

  // ── 多模态 ────────────────────────────────────────

  /// 送给模型时使用哪种图片形态（原图 / 压缩 / 缩略图）。
  Future<AiImageSendMode> getImageSendMode() async {
    final prefs = await _prefs;
    return AiImageSendMode.fromName(prefs.getString(imageSendModeKey));
  }

  Future<void> setImageSendMode(AiImageSendMode mode) async {
    final prefs = await _prefs;
    await prefs.setString(imageSendModeKey, mode.name);
  }

  /// 同步用缩略图边长（16 或 32，默认 32）。
  Future<int> getImageThumbnailSize() async {
    final prefs = await _prefs;
    final value = prefs.getInt(imageThumbnailSizeKey);
    return value == AiChatAttachment.thumbSizeSmall
        ? AiChatAttachment.thumbSizeSmall
        : AiChatAttachment.thumbSizeLarge;
  }

  Future<void> setImageThumbnailSize(int size) async {
    final prefs = await _prefs;
    final normalized = size == AiChatAttachment.thumbSizeSmall
        ? AiChatAttachment.thumbSizeSmall
        : AiChatAttachment.thumbSizeLarge;
    await prefs.setInt(imageThumbnailSizeKey, normalized);
  }
}
