import 'package:flutter/material.dart';

import '../../../models/ai_chat.dart';
import '../../../models/ai_context.dart';
import '../../../models/ai_profile.dart';
import '../../../services/ai/ai_chat_service.dart';
import '../../../services/ai/ai_chat_settings.dart';
import '../../../services/ai/ai_image_service.dart';
import '../../../services/ai/ai_profile_service.dart';
import '../../../services/ai/tools/ai_tool.dart';
import '../../../services/ai/tools/ai_tool_registry.dart';
import '../../../services/ai/tools/app_tools.dart';
import '../../../widgets/chat/chat_labels.dart';
import '../settings_section_header.dart';

/// 「AI 对话」设置分区：配置选择、上下文、工具调用与对话数据。
class AiChatSection extends StatefulWidget {
  const AiChatSection({super.key, this.settings, this.profileService});

  /// 测试可注入。
  final AiChatSettings? settings;
  final AiProfileService? profileService;

  @override
  State<AiChatSection> createState() => _AiChatSectionState();
}

class _AiChatSectionState extends State<AiChatSection> {
  late final AiChatSettings _settings = widget.settings ?? AiChatSettings();
  late final AiProfileService _profileService =
      widget.profileService ?? AiProfileService();
  final AiChatService _chatService = AiChatService.instance;

  final AiToolRegistry _registry = AiToolRegistry(AppTools.build());

  bool _loading = true;
  String? _profileId;
  String _systemPrompt = AiChatSettings.defaultSystemPrompt;
  double? _temperatureOverride;
  int? _maxTokensOverride;
  AiContextPolicy _contextPolicy = AiContextPolicy.defaults;
  bool _toolsEnabled = true;
  bool _autoApproveReadOnly = true;
  int _maxToolRounds = AiChatSettings.defaultToolRounds;
  bool _streamEnabled = true;
  Set<String> _disabledTools = {};
  bool _injectRuntime = true;
  bool _injectTime = true;
  bool _showUsageBadge = true;
  AiImageSendMode _imageSendMode = AiImageSendMode.compressed;
  int _imageThumbnailSize = AiChatAttachment.thumbSizeLarge;
  int _sessionCount = 0;
  int _messageCount = 0;

  @override
  void initState() {
    super.initState();
    _profileService.addListener(_onProfilesChanged);
    _load();
  }

  @override
  void dispose() {
    _profileService.removeListener(_onProfilesChanged);
    super.dispose();
  }

  void _onProfilesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    await _profileService.load();
    final results = await Future.wait([
      _settings.getProfileId(),
      _settings.getSystemPrompt(),
      _settings.getTemperatureOverride(),
      _settings.getMaxTokensOverride(),
      _settings.getContextPolicy(),
      _settings.getToolsEnabled(),
      _settings.getAutoApproveReadOnly(),
      _settings.getMaxToolRounds(),
      _settings.getStreamEnabled(),
      _settings.getDisabledToolNames(),
      _chatService.countSessions(),
      _chatService.countMessages(),
      _settings.getImageSendMode(),
      _settings.getImageThumbnailSize(),
      _settings.getInjectRuntimeContext(),
      _settings.getInjectTimeContext(),
      _settings.getShowUsageBadge(),
    ]);
    if (!mounted) return;
    setState(() {
      _profileId = results[0] as String?;
      _systemPrompt = results[1] as String;
      _temperatureOverride = results[2] as double?;
      _maxTokensOverride = results[3] as int?;
      _contextPolicy = results[4] as AiContextPolicy;
      _toolsEnabled = results[5] as bool;
      _autoApproveReadOnly = results[6] as bool;
      _maxToolRounds = results[7] as int;
      _streamEnabled = results[8] as bool;
      _disabledTools = results[9] as Set<String>;
      _sessionCount = results[10] as int;
      _messageCount = results[11] as int;
      _imageSendMode = results[12] as AiImageSendMode;
      _imageThumbnailSize = results[13] as int;
      _injectRuntime = results[14] as bool;
      _injectTime = results[15] as bool;
      _showUsageBadge = results[16] as bool;
      _loading = false;
    });
  }

  AiProfile? get _effectiveProfile {
    final profiles = _profileService.profiles;
    if (_profileId != null) {
      for (final profile in profiles) {
        if (profile.id == _profileId) return profile;
      }
    }
    return _profileService.defaultProfile;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 使用的 AI 配置 ──
        const SettingsSectionHeader(title: '对话使用的 AI 配置'),
        ListTile(
          leading: Icon(Icons.smart_toy_outlined, color: colorScheme.primary),
          title: const Text('AI 配置'),
          subtitle: Text(
            _effectiveProfile == null
                ? '未配置'
                : '${_effectiveProfile!.name} · ${_effectiveProfile!.model}'
                      '${_effectiveProfile!.isAquamarina ? '（不支持对话）' : ''}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickProfile,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '对话只发往你选择的配置（OpenAI 兼容 / DeepSeek），不经过 Aquamarina 官方'
            '服务器。官方配置仅用于句型批改，不支持通用对话。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Divider(),

        // ── 提示词与采样 ──
        const SettingsSectionHeader(title: '提示词与生成参数'),
        ListTile(
          leading: Icon(Icons.notes_outlined, color: colorScheme.primary),
          title: const Text('系统提示词'),
          subtitle: Text(
            _systemPrompt,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _editSystemPrompt,
        ),
        SwitchListTile(
          secondary: Icon(
            Icons.thermostat_outlined,
            color: colorScheme.primary,
          ),
          title: const Text('覆盖 Temperature'),
          subtitle: Text(
            _temperatureOverride == null
                ? '使用配置自带的值'
                : '当前 ${_temperatureOverride!.toStringAsFixed(1)}',
          ),
          value: _temperatureOverride != null,
          onChanged: (enabled) async {
            final value = enabled ? 0.7 : null;
            await _settings.setTemperatureOverride(value);
            setState(() => _temperatureOverride = value);
          },
        ),
        if (_temperatureOverride != null)
          ListTile(
            title: const Text('Temperature 取值'),
            trailing: Text(
              _temperatureOverride!.toStringAsFixed(1),
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            onTap: _pickTemperature,
          ),
        SwitchListTile(
          secondary: Icon(Icons.data_usage, color: colorScheme.primary),
          title: const Text('覆盖 Max Tokens'),
          subtitle: Text(
            _maxTokensOverride == null ? '使用配置自带的值' : '当前 $_maxTokensOverride',
          ),
          value: _maxTokensOverride != null,
          onChanged: (enabled) async {
            final value = enabled ? 2048 : null;
            await _settings.setMaxTokensOverride(value);
            setState(() => _maxTokensOverride = value);
          },
        ),
        if (_maxTokensOverride != null)
          ListTile(
            title: const Text('Max Tokens 取值'),
            trailing: Text(
              '$_maxTokensOverride',
              style: theme.textTheme.titleMedium?.copyWith(
                color: colorScheme.primary,
                fontWeight: FontWeight.bold,
              ),
            ),
            onTap: _pickMaxTokens,
          ),
        ListTile(
          leading: Icon(Icons.history, color: colorScheme.primary),
          title: const Text('上下文处理'),
          subtitle: Text(_describeContextPolicy(_contextPolicy)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _editContextPolicy,
        ),
        SwitchListTile(
          secondary: Icon(Icons.flash_on, color: colorScheme.primary),
          title: const Text('流式输出'),
          subtitle: const Text('关闭后一次性返回，且不启用工具调用'),
          value: _streamEnabled,
          onChanged: (value) async {
            await _settings.setStreamEnabled(value);
            setState(() => _streamEnabled = value);
          },
        ),
        const Divider(),

        // ── 上下文注入 ──
        const SettingsSectionHeader(title: '上下文自动注入'),
        SwitchListTile(
          title: const Text('注入运行环境'),
          subtitle: const Text('App 版本、数据库 schema、平台；模型无需再调用工具确认'),
          value: _injectRuntime,
          onChanged: (v) async {
            await _settings.setInjectRuntimeContext(v);
            setState(() => _injectRuntime = v);
          },
        ),
        SwitchListTile(
          title: const Text('注入当前时间'),
          subtitle: const Text('每轮请求重新取时间；历史轮次冻结不变，保证缓存可命中'),
          value: _injectTime,
          onChanged: (v) async {
            await _settings.setInjectTimeContext(v);
            setState(() => _injectTime = v);
          },
        ),

        const Divider(),

        // ── 消息显示 ──
        const SettingsSectionHeader(title: '消息显示'),
        SwitchListTile(
          secondary: Icon(Icons.token_outlined, color: colorScheme.primary),
          title: const Text('显示 token / 费用角标'),
          subtitle: const Text('回答下方显示该轮的真实用量与费用；提问按字符估算，仅供参考'),
          value: _showUsageBadge,
          onChanged: (value) async {
            await _settings.setShowUsageBadge(value);
            setState(() => _showUsageBadge = value);
          },
        ),

        const Divider(),

        // ── 图片（多模态）──
        const SettingsSectionHeader(title: '图片与多模态'),
        ListTile(
          leading: Icon(
            Icons.photo_library_outlined,
            color: colorScheme.primary,
          ),
          title: const Text('发送给模型的图片形态'),
          subtitle: Text(_describeSendMode(_imageSendMode)),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickImageSendMode,
        ),
        ListTile(
          leading: Icon(
            Icons.photo_size_select_small,
            color: colorScheme.primary,
          ),
          title: const Text('同步用缩略图尺寸'),
          subtitle: Text(
            '$_imageThumbnailSize×$_imageThumbnailSize 像素 · 原图仅保存在本机',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: _pickThumbnailSize,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            '对话图片的原图不会上传云端；跨设备只同步 16/32 像素的缩略图，'
            '因此其它设备看到的图片是模糊占位，需要重新发送原图才能获得完整体验。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Divider(),

        // ── 工具调用 ──
        const SettingsSectionHeader(title: '工具调用'),
        SwitchListTile(
          secondary: Icon(Icons.build_outlined, color: colorScheme.primary),
          title: const Text('启用工具调用'),
          subtitle: const Text('允许 AI 调用 App 内工具（查词、词书、学习统计等）'),
          value: _toolsEnabled,
          onChanged: (value) async {
            await _settings.setToolsEnabled(value);
            setState(() => _toolsEnabled = value);
          },
        ),
        SwitchListTile(
          secondary: Icon(
            Icons.verified_user_outlined,
            color: colorScheme.primary,
          ),
          title: const Text('自动批准只读工具'),
          subtitle: const Text('查词、统计等只读操作不再询问；写操作始终需要批准'),
          value: _autoApproveReadOnly,
          onChanged: (value) async {
            await _settings.setAutoApproveReadOnly(value);
            setState(() => _autoApproveReadOnly = value);
          },
        ),
        ListTile(
          leading: Icon(Icons.repeat, color: colorScheme.primary),
          title: const Text('工具调用最大轮次'),
          subtitle: const Text('单次对话中最多连续调用工具的轮数'),
          trailing: Text(
            '$_maxToolRounds',
            style: theme.textTheme.titleMedium?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
          ),
          onTap: _pickMaxToolRounds,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            '可用工具',
            style: theme.textTheme.labelLarge?.copyWith(
              color: colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        for (final tool in _registry.all)
          SwitchListTile(
            secondary: Icon(
              tool.isMutating ? Icons.edit_outlined : Icons.search,
              color: tool.isMutating ? colorScheme.error : colorScheme.primary,
            ),
            title: Text(ChatLabels.tool(tool.name)),
            subtitle: Text(
              tool.isMutating
                  ? '写操作 · 每次执行前都需要你批准'
                  : '只读 · ${tool.description}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            value: !_disabledTools.contains(tool.name),
            onChanged: (enabled) async {
              final next = {..._disabledTools};
              if (enabled) {
                next.remove(tool.name);
              } else {
                next.add(tool.name);
              }
              await _settings.setDisabledToolNames(next);
              setState(() => _disabledTools = next);
            },
          ),
        const Divider(),

        // ── 对话数据 ──
        const SettingsSectionHeader(title: '对话数据'),
        ListTile(
          leading: Icon(Icons.forum_outlined, color: colorScheme.primary),
          title: const Text('本地对话'),
          subtitle: Text('$_sessionCount 个会话 · $_messageCount 条消息（随云同步）'),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: OutlinedButton.icon(
            onPressed: _clearAll,
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('清空全部对话'),
            style: OutlinedButton.styleFrom(foregroundColor: colorScheme.error),
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  // ── 交互 ──────────────────────────────────────────

  Future<void> _pickProfile() async {
    final profiles = _profileService.profiles;
    if (profiles.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('还没有 AI 配置，请先在「AI 服务配置」中添加'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final selected = await showModalBottomSheet<String?>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) {
        final theme = Theme.of(sheetContext);
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('选择对话使用的配置', style: theme.textTheme.titleMedium),
              ),
              for (final profile in profiles)
                ListTile(
                  enabled: !profile.isAquamarina,
                  leading: Icon(
                    profile.isDeepSeek ? Icons.psychology : Icons.auto_awesome,
                  ),
                  title: Text(profile.name),
                  subtitle: Text(
                    profile.isAquamarina
                        ? '${profile.model} · 不支持通用对话'
                        : '${profile.model} · ${profile.baseUrl}',
                  ),
                  trailing: profile.id == _effectiveProfile?.id
                      ? const Icon(Icons.check)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(profile.id),
                ),
            ],
          ),
        );
      },
    );

    if (selected == null) return;
    await _settings.setProfileId(selected);
    setState(() => _profileId = selected);
  }

  Future<void> _editSystemPrompt() async {
    final controller = TextEditingController(text: _systemPrompt);
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('系统提示词'),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: controller,
            maxLines: 10,
            minLines: 5,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              hintText: '描述助手的角色与回答风格',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              controller.text = AiChatSettings.defaultSystemPrompt;
            },
            child: const Text('恢复默认'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (result == null) {
      controller.dispose();
      return;
    }
    final value = result.isEmpty ? AiChatSettings.defaultSystemPrompt : result;
    controller.dispose();
    await _settings.setSystemPrompt(value);
    setState(() => _systemPrompt = value);
  }

  Future<void> _pickTemperature() async {
    var value = _temperatureOverride ?? 0.7;
    final result = await showDialog<double>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Temperature'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(value.toStringAsFixed(1)),
              Slider(
                value: value,
                min: 0,
                max: 2,
                divisions: 20,
                label: value.toStringAsFixed(1),
                onChanged: (v) => setDialogState(() => value = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(value),
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await _settings.setTemperatureOverride(result);
    setState(() => _temperatureOverride = result);
  }

  Future<void> _pickMaxTokens() async {
    final options = [256, 512, 1024, 2048, 4096, 8192];
    final result = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final option in options)
              ListTile(
                title: Text('$option'),
                trailing: option == _maxTokensOverride
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(option),
              ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await _settings.setMaxTokensOverride(result);
    setState(() => _maxTokensOverride = result);
  }

  Future<void> _editContextPolicy() async {
    final result = await showDialog<AiContextPolicy>(
      context: context,
      builder: (_) => _ContextPolicyDialog(
        policy: _contextPolicy,
        window: _effectiveProfile?.contextWindow ?? 0,
      ),
    );
    if (result == null) return;
    await _settings.setContextPolicy(result);
    setState(() => _contextPolicy = result);
  }

  String _describeContextPolicy(AiContextPolicy policy) {
    final parts = <String>[];
    if (!policy.compressionEnabled) {
      parts.add('未启用摘要压缩');
    } else if (policy.thresholdMode == AiContextThresholdMode.ratio) {
      final percent = (policy.ratioThreshold * 100).toStringAsFixed(0);
      final window = _effectiveProfile?.contextWindow ?? 0;
      if (window <= 0) {
        parts.add('达窗口 $percent% 时摘要压缩（未填写上下文窗口）');
      } else {
        final tokens = policy.resolveThresholdTokens(window);
        parts.add('达窗口 $percent%（约 $tokens tokens）时摘要压缩');
      }
    } else {
      parts.add(
        '达 ${_formatTokenCount(policy.absoluteThreshold)} tokens 时摘要压缩',
      );
    }
    if (!policy.usageWarningEnabled) {
      parts.add('未启用窗口提示');
    } else {
      final percent = (policy.usageWarningRatio * 100).toStringAsFixed(0);
      parts.add('会话达窗口 $percent% 时提示');
    }
    return parts.join(' · ');
  }

  String _formatTokenCount(int tokens) {
    if (tokens % 1024 == 0) {
      return '${tokens ~/ 1024}K';
    }
    if (tokens >= 1000) {
      final value = tokens / 1000;
      return '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)}K';
    }
    return '$tokens';
  }

  Future<void> _pickMaxToolRounds() async {
    final result = await _showStepperDialog(
      title: '工具调用最大轮次',
      current: _maxToolRounds,
      min: AiChatSettings.minToolRounds,
      max: AiChatSettings.maxToolRounds,
      step: 1,
    );
    if (result == null) return;
    await _settings.setMaxToolRounds(result);
    setState(() => _maxToolRounds = result);
  }

  Future<int?> _showStepperDialog({
    required String title,
    required int current,
    required int min,
    required int max,
    required int step,
  }) {
    var value = current;
    return showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.remove_circle_outline),
                onPressed: value > min
                    ? () => setDialogState(
                        () => value = (value - step).clamp(min, max),
                      )
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  '$value',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle_outline),
                onPressed: value < max
                    ? () => setDialogState(
                        () => value = (value + step).clamp(min, max),
                      )
                    : null,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(value),
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
  }

  String _describeSendMode(AiImageSendMode mode) {
    switch (mode) {
      case AiImageSendMode.original:
        return '发送原图 · 细节最好，消耗最多';
      case AiImageSendMode.compressed:
        return '压缩后发送 · 长边 ${AiImageService.maxSendDimension}px，质量 ${AiImageService.sendJpegQuality}';
      case AiImageSendMode.thumbnail:
        return '只发送 $_imageThumbnailSize×$_imageThumbnailSize 缩略图 · 最省 token';
    }
  }

  Future<void> _pickImageSendMode() async {
    final result = await showModalBottomSheet<AiImageSendMode>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final mode in AiImageSendMode.values)
              ListTile(
                leading: Icon(switch (mode) {
                  AiImageSendMode.original => Icons.hd_outlined,
                  AiImageSendMode.compressed => Icons.compress,
                  AiImageSendMode.thumbnail => Icons.grid_view,
                }),
                title: Text(switch (mode) {
                  AiImageSendMode.original => '发送原图',
                  AiImageSendMode.compressed => '压缩后发送（推荐）',
                  AiImageSendMode.thumbnail => '只发送缩略图',
                }),
                subtitle: Text(_describeSendMode(mode)),
                trailing: mode == _imageSendMode
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(mode),
              ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await _settings.setImageSendMode(result);
    setState(() => _imageSendMode = result);
  }

  Future<void> _pickThumbnailSize() async {
    final result = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: const Text('16×16'),
              subtitle: const Text('最小体积，同步最快，仅作占位'),
              trailing: _imageThumbnailSize == AiChatAttachment.thumbSizeSmall
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.of(
                sheetContext,
              ).pop(AiChatAttachment.thumbSizeSmall),
            ),
            ListTile(
              title: const Text('32×32'),
              subtitle: const Text('略大但更能辨认（默认）'),
              trailing: _imageThumbnailSize == AiChatAttachment.thumbSizeLarge
                  ? const Icon(Icons.check)
                  : null,
              onTap: () => Navigator.of(
                sheetContext,
              ).pop(AiChatAttachment.thumbSizeLarge),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await _settings.setImageThumbnailSize(result);
    setState(() => _imageThumbnailSize = result);
  }

  Future<void> _clearAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空全部对话'),
        content: const Text('将删除本机所有 AI 对话记录，并同步删除其它已同步设备上的对话。此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _chatService.clearAll();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已清空全部对话'),
        behavior: SnackBarBehavior.floating,
      ),
    );
    await _load();
  }
}

/// 供测试断言：风险分类文本。
String describeToolRisk(AiToolRisk risk) => switch (risk) {
  AiToolRisk.readOnly => '只读',
  AiToolRisk.mutating => '写操作',
};

/// 「上下文处理」对话框。
///
/// 输入框控制器由本 State 持有并释放：如果在 `showDialog` 返回后立刻释放，
/// 退出动画期间输入框仍会重建并向控制器注册监听，会触发
/// "TextEditingController was used after being disposed"。
class _ContextPolicyDialog extends StatefulWidget {
  const _ContextPolicyDialog({required this.policy, required this.window});

  final AiContextPolicy policy;

  /// 当前 AI 配置的上下文窗口；0 表示未配置。
  final int window;

  @override
  State<_ContextPolicyDialog> createState() => _ContextPolicyDialogState();
}

class _ContextPolicyDialogState extends State<_ContextPolicyDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _tokensController = TextEditingController(
    text: '${widget.policy.absoluteThreshold}',
  );
  late final TextEditingController _ratioController = TextEditingController(
    text: (widget.policy.ratioThreshold * 100).toStringAsFixed(0),
  );
  late final TextEditingController _warningController = TextEditingController(
    text: (widget.policy.usageWarningRatio * 100).toStringAsFixed(0),
  );

  late bool _compressionEnabled = widget.policy.compressionEnabled;
  late AiContextThresholdMode _mode = widget.policy.thresholdMode;
  late bool _usageWarningEnabled = widget.policy.usageWarningEnabled;

  @override
  void dispose() {
    _tokensController.dispose();
    _ratioController.dispose();
    _warningController.dispose();
    super.dispose();
  }

  double _percentOf(TextEditingController controller, double fallback) =>
      double.tryParse(controller.text.trim()) ?? fallback;

  String _compressionHelperText() {
    final window = widget.window;
    if (window <= 0) {
      return '当前 AI 配置未填写上下文窗口大小，请先到「AI 配置」中填写';
    }
    final tokens = (window * _percentOf(_ratioController, 50) / 100).floor();
    return '当前配置窗口 $window tokens，达到约 $tokens tokens 时压缩';
  }

  String _warningHelperText() {
    final window = widget.window;
    if (window <= 0) return '当前 AI 配置未填写上下文窗口，比例提示不可用';
    final tokens = (window * _percentOf(_warningController, 70) / 100).floor();
    return '当前配置窗口 $window tokens，达到约 $tokens tokens 时提示';
  }

  void _submit() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final absolute = int.tryParse(_tokensController.text.trim());
    final percent = double.tryParse(_ratioController.text.trim());
    final warningPercent = double.tryParse(_warningController.text.trim());
    final policy = AiContextPolicy(
      compressionEnabled: _compressionEnabled,
      thresholdMode: _mode,
      absoluteThreshold: absolute ?? AiContextPolicy.defaultAbsoluteThreshold,
      ratioThreshold: percent == null
          ? AiContextPolicy.defaultRatio
          : percent / 100,
      usageWarningEnabled: _usageWarningEnabled,
      usageWarningRatio: warningPercent == null
          ? AiContextPolicy.defaultUsageWarningRatio
          : warningPercent / 100,
    ).normalized();
    Navigator.of(context).pop(policy);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final window = widget.window;
    return AlertDialog(
      title: const Text('上下文处理'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(
                    Icons.compress,
                    color: theme.colorScheme.primary,
                  ),
                  title: const Text('达阈值时摘要压缩'),
                  subtitle: const Text('把较早的消息交给模型压缩成摘要，减少上下文占用'),
                  value: _compressionEnabled,
                  onChanged: (value) =>
                      setState(() => _compressionEnabled = value),
                ),
                if (_compressionEnabled) ...[
                  const SizedBox(height: 8),
                  Text(
                    window > 0
                        ? '当前 AI 配置的上下文窗口：$window tokens'
                        : '当前 AI 配置未填写上下文窗口；绝对阈值将同时作为上限',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SegmentedButton<AiContextThresholdMode>(
                    segments: const [
                      ButtonSegment(
                        value: AiContextThresholdMode.absolute,
                        label: Text('绝对 token'),
                        icon: Icon(Icons.tag),
                      ),
                      ButtonSegment(
                        value: AiContextThresholdMode.ratio,
                        label: Text('窗口比例'),
                        icon: Icon(Icons.percent),
                      ),
                    ],
                    selected: {_mode},
                    showSelectedIcon: false,
                    onSelectionChanged: (selected) =>
                        setState(() => _mode = selected.first),
                  ),
                  const SizedBox(height: 12),
                  if (_mode == AiContextThresholdMode.absolute)
                    TextFormField(
                      controller: _tokensController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '触发阈值（tokens）',
                        hintText: '例如 16384（16K）',
                        border: OutlineInputBorder(),
                        suffixText: 'tokens',
                      ),
                      validator: (value) {
                        final parsed = int.tryParse((value ?? '').trim());
                        if (parsed == null ||
                            parsed < AiContextPolicy.minAbsoluteThreshold) {
                          return '请输入不小于 ${AiContextPolicy.minAbsoluteThreshold} 的整数';
                        }
                        return null;
                      },
                    )
                  else
                    TextFormField(
                      controller: _ratioController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: '触发阈值（上下文窗口百分比）',
                        hintText: '例如 50',
                        border: const OutlineInputBorder(),
                        suffixText: '%',
                        helperText: _compressionHelperText(),
                        helperMaxLines: 3,
                      ),
                      onChanged: (_) => setState(() {}),
                      validator: (value) {
                        final parsed = double.tryParse((value ?? '').trim());
                        if (parsed == null ||
                            parsed < AiContextPolicy.minRatio * 100 ||
                            parsed > AiContextPolicy.maxRatio * 100) {
                          return '请输入 5 - 100 之间的百分比';
                        }
                        return null;
                      },
                    ),
                  const Divider(height: 24),
                ],
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: Icon(
                    Icons.data_usage,
                    color: theme.colorScheme.primary,
                  ),
                  title: const Text('接近窗口时提示'),
                  subtitle: const Text('会话历史达到上下文窗口一定比例时，在对话页顶部提醒'),
                  value: _usageWarningEnabled,
                  onChanged: (value) =>
                      setState(() => _usageWarningEnabled = value),
                ),
                if (_usageWarningEnabled)
                  TextFormField(
                    controller: _warningController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: '提示阈值（上下文窗口百分比）',
                      hintText: '例如 70',
                      border: const OutlineInputBorder(),
                      suffixText: '%',
                      helperText: _warningHelperText(),
                      helperMaxLines: 3,
                    ),
                    onChanged: (_) => setState(() {}),
                    validator: (value) {
                      final parsed = double.tryParse((value ?? '').trim());
                      if (parsed == null ||
                          parsed < AiContextPolicy.minUsageWarningRatio * 100 ||
                          parsed > AiContextPolicy.maxUsageWarningRatio * 100) {
                        return '请输入 10 - 95 之间的百分比';
                      }
                      return null;
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('保存')),
      ],
    );
  }
}
