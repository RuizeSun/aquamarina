import 'dart:async';

import 'package:flutter/material.dart';
import '../../../services/log_service.dart';
import '../../../services/mimo_tts_credentials.dart';
import '../../../services/mimo_tts_engine.dart';
import '../../../services/tts_settings.dart';
import '../../../services/tts_service.dart';

/// 语音设置分区（TTS）
class TtsSettingsSection extends StatefulWidget {
  const TtsSettingsSection({super.key});

  @override
  State<TtsSettingsSection> createState() => _TtsSettingsSectionState();
}

class _TtsSettingsSectionState extends State<TtsSettingsSection> {
  TtsSettings _settings = const TtsSettings();
  bool _isLoading = true;
  List<String> _voices = [];

  // ── MiMo TTS 相关状态 ──────────────────────────
  final TextEditingController _mimoApiKeyController = TextEditingController();
  final TextEditingController _mimoInstructionController =
      TextEditingController();
  final TextEditingController _mimoStyleTagController = TextEditingController();
  final TextEditingController _mimoBaseUrlController = TextEditingController();
  final TextEditingController _mimoModelController = TextEditingController();
  bool _obscureMimoApiKey = true;
  bool _mimoKeyConfigured = false;

  // ── 试听测试 ──────────────────────────────────
  /// 试听默认文本：中英各一句，便于同时验证中英文音色
  static const String _defaultTestText =
      'Hello, this is a TTS test. 你好，这是一段语音测试。';

  final TextEditingController _testTextController = TextEditingController(
    text: _defaultTestText,
  );
  bool _isTesting = false;

  /// 文本输入的持久化防抖（避免每次按键都写 SharedPreferences）
  Timer? _persistDebounce;

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _persistDebounce?.cancel();
    _mimoApiKeyController.dispose();
    _mimoInstructionController.dispose();
    _mimoStyleTagController.dispose();
    _mimoBaseUrlController.dispose();
    _mimoModelController.dispose();
    _testTextController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final settings = await TtsSettings.load();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _syncMimoTextControllers(settings);
      _isLoading = false;
    });
    // 异步加载音色列表
    _loadVoices();
    // API Key 存于安全存储，单独异步读取（不阻塞设置页渲染）
    unawaited(_loadMimoApiKey());
  }

  /// 异步读取 MiMo API Key（安全存储可能较慢）
  Future<void> _loadMimoApiKey() async {
    final apiKey = await MimoTtsCredentials.read();
    if (!mounted) return;
    setState(() {
      _mimoApiKeyController.text = apiKey;
      _mimoKeyConfigured = apiKey.isNotEmpty;
    });
  }

  /// 把 MiMo 文本类设置同步到输入框
  void _syncMimoTextControllers(TtsSettings settings) {
    _mimoInstructionController.text = settings.mimoInstruction;
    _mimoStyleTagController.text = settings.mimoStyleTag;
    _mimoBaseUrlController.text = settings.mimoBaseUrl;
    _mimoModelController.text = settings.mimoModel;
  }

  Future<void> _loadVoices() async {
    try {
      final voices = await TtsService.instance.getVoices();
      if (mounted) setState(() => _voices = voices);
    } catch (_) {
      // 静默处理
    }
  }

  Future<void> _updateSettings(TtsSettings newSettings) async {
    await TtsService.instance.updateSettings(newSettings);
    if (mounted) {
      setState(() => _settings = newSettings);
    }
  }

  /// 文本输入使用：先本地更新 UI，防抖后再持久化
  void _updateSettingsDebounced(TtsSettings newSettings) {
    setState(() => _settings = newSettings);
    _persistDebounce?.cancel();
    _persistDebounce = Timer(const Duration(milliseconds: 500), () {
      TtsService.instance.updateSettings(_settings);
    });
  }

  /// 立即落盘（用于离开输入框等场景）
  Future<void> _flushPendingPersist() async {
    if (_persistDebounce?.isActive ?? false) {
      _persistDebounce!.cancel();
      await TtsService.instance.updateSettings(_settings);
    }
  }

  /// 保存 MiMo API Key（敏感信息存 Secure Storage）
  Future<void> _saveMimoApiKey() async {
    final key = _mimoApiKeyController.text.trim();
    try {
      await MimoTtsCredentials.save(key);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('保存失败：无法写入安全存储'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (!mounted) return;
    setState(() {
      _mimoKeyConfigured = key.isNotEmpty;
      if (key.isEmpty) _mimoApiKeyController.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(key.isEmpty ? '已清除 MiMo API Key' : '已保存 MiMo API Key'),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 试听测试：用当前服务商朗读测试文本。
  ///
  /// 这里显式关闭降级（`allowFallback: false`），确保「能听到声音」就等于
  /// 当前服务商配置正确，而不是被系统 TTS 兜底掩盖。
  Future<void> _testTts() async {
    if (_isTesting) return;

    final text = _testTextController.text.trim();
    if (text.isEmpty) {
      _showSnack('请输入测试文本');
      return;
    }

    setState(() => _isTesting = true);

    var success = false;
    try {
      success = await TtsService.instance.speak(text, allowFallback: false);
    } catch (e) {
      logError('TtsSettingsSection', '试听测试异常: $e');
    }

    if (!mounted) return;
    setState(() => _isTesting = false);
    _showSnack(
      success ? '试听成功：${_settings.provider.label}' : _testFailureHint(),
    );
  }

  /// 试听失败提示（具体原因已由引擎写入日志）
  String _testFailureHint() {
    switch (_settings.provider) {
      case TtsProvider.mimo:
        if (!_mimoReady) return '试听失败：请先填写并保存 MiMo API Key';
        return '试听失败：请检查网络、API Key 或 Base URL（详见「日志」）';
      case TtsProvider.edge:
        return '试听失败：请检查网络连接（详见「日志」）';
      case TtsProvider.system:
        return '试听失败：系统语音不可用，请检查系统 TTS 设置';
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  /// 切换服务商：重建引擎并按新服务商重新加载音色列表
  ///
  /// 切换时会取回目标服务商已保存的音色（没有则清空，使用其默认音色），
  /// 避免把旧服务商的音色写入新服务商。
  Future<void> _onProviderChanged(TtsProvider provider) async {
    if (provider == _settings.provider) return;
    await _flushPendingPersist();
    final voice = await TtsSettings.loadVoiceFor(provider);
    final updated = _settings.copyWith(
      provider: provider,
      voiceName: voice,
      clearVoiceName: voice == null || voice.isEmpty,
    );
    await _updateSettings(updated);
    await _loadVoices();
  }

  /// MiMo 是否已可用（已配置 API Key）
  bool get _mimoReady => _mimoKeyConfigured;

  /// 音色选择弹窗：MiMo 预置音色按语言分组展示
  Widget _buildVoiceSheet(BuildContext context, ColorScheme colorScheme) {
    final selected = _settings.effectiveVoiceName;
    final children = <Widget>[];

    if (_settings.provider == TtsProvider.mimo) {
      String? group;
      for (final voice in MimoTtsEngine.presetVoices) {
        if (voice.language != group) {
          group = voice.language;
          children.add(
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                group,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.primary,
                ),
              ),
            ),
          );
        }
        children.add(
          _buildVoiceTile(
            context,
            colorScheme,
            voiceId: voice.id,
            selected: selected,
            hint: voice.hint,
          ),
        );
      }
    } else {
      for (final voice in _voices) {
        children.add(
          _buildVoiceTile(
            context,
            colorScheme,
            voiceId: voice,
            selected: selected,
          ),
        );
      }
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              '选择音色',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ),
          const Divider(height: 1),
          SizedBox(height: 340, child: ListView(children: children)),
        ],
      ),
    );
  }

  /// 单个音色选项
  Widget _buildVoiceTile(
    BuildContext context,
    ColorScheme colorScheme, {
    required String voiceId,
    required String? selected,
    String? hint,
  }) {
    final isSelected = voiceId == selected;
    return ListTile(
      selected: isSelected,
      selectedTileColor: colorScheme.primaryContainer.withValues(alpha: 0.3),
      title: Text(voiceId),
      subtitle: hint == null ? null : Text(hint),
      trailing: isSelected
          ? Icon(Icons.check, color: colorScheme.primary)
          : null,
      onTap: () {
        Navigator.of(context).pop();
        _updateSettings(_settings.copyWith(voiceName: voiceId));
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    if (_isLoading) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return Column(
      children: [
        // TTS 启用开关
        SwitchListTile(
          secondary: Icon(Icons.volume_up, color: colorScheme.primary),
          title: const Text('启用 TTS'),
          subtitle: const Text('朗读单词发音'),
          value: _settings.enabled,
          onChanged: (value) {
            _updateSettings(_settings.copyWith(enabled: value));
          },
        ),

        if (_settings.enabled) ...[
          // 服务商切换
          ListTile(
            leading: Icon(Icons.cloud, color: colorScheme.primary),
            title: const Text('TTS 服务商'),
            subtitle: Text('当前：${_settings.provider.label}'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: SegmentedButton<TtsProvider>(
                    segments: [
                      for (final provider in TtsProvider.values)
                        ButtonSegment(
                          value: provider,
                          label: Text(provider.label),
                        ),
                    ],
                    selected: {_settings.provider},
                    showSelectedIcon: false,
                    onSelectionChanged: (selected) {
                      _onProviderChanged(selected.first);
                    },
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 音量
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.volume_mute, size: 20, color: colorScheme.primary),
                Expanded(
                  child: Slider(
                    value: _settings.volume,
                    min: 0.0,
                    max: 1.0,
                    divisions: 20,
                    label: '${(_settings.volume * 100).round()}%',
                    onChanged: (value) {
                      setState(
                        () => _settings = _settings.copyWith(volume: value),
                      );
                    },
                    onChangeEnd: (value) {
                      _updateSettings(_settings.copyWith(volume: value));
                    },
                  ),
                ),
                Icon(Icons.volume_up, size: 20, color: colorScheme.primary),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 72, top: 0, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '音量: ${(_settings.volume * 100).round()}%',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),

          // 语速
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.speed, size: 20, color: colorScheme.primary),
                Expanded(
                  child: Slider(
                    value: _settings.rate,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: '${_settings.rate.toStringAsFixed(1)}x',
                    onChanged: (value) {
                      setState(
                        () => _settings = _settings.copyWith(rate: value),
                      );
                    },
                    onChangeEnd: (value) {
                      _updateSettings(_settings.copyWith(rate: value));
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 72, top: 0, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '语速: ${_settings.rate.toStringAsFixed(1)}x'
                '${_settings.provider == TtsProvider.mimo ? '（MiMo 通过播放倍速实现，精细控制可写在风格指令中）' : ''}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),

          // 音调（MiMo TTS 接口不支持音调，置灰禁用）
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Icon(Icons.tune, size: 20, color: colorScheme.primary),
                Expanded(
                  child: Slider(
                    value: _settings.pitch,
                    min: 0.5,
                    max: 2.0,
                    divisions: 15,
                    label: '${_settings.pitch.toStringAsFixed(1)}x',
                    onChanged: _settings.provider == TtsProvider.mimo
                        ? null
                        : (value) {
                            setState(
                              () =>
                                  _settings = _settings.copyWith(pitch: value),
                            );
                          },
                    onChangeEnd: _settings.provider == TtsProvider.mimo
                        ? null
                        : (value) {
                            _updateSettings(_settings.copyWith(pitch: value));
                          },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 72, top: 0, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                _settings.provider == TtsProvider.mimo
                    ? '音调: MiMo 不支持调整'
                    : '音调: ${_settings.pitch.toStringAsFixed(1)}x',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),

          // 音色选择（系统 TTS 由系统管理，在线服务商可选音色）
          if (_settings.provider != TtsProvider.system) ...[
            ListTile(
              leading: Icon(
                Icons.record_voice_over,
                color: colorScheme.primary,
              ),
              title: const Text('音色'),
              subtitle: Text(_settings.effectiveVoiceName ?? '默认音色'),
              trailing: _voices.isNotEmpty
                  ? PopupMenuButton<String>(
                      onSelected: (voice) {
                        _updateSettings(_settings.copyWith(voiceName: voice));
                      },
                      itemBuilder: (context) => _voices.map((voice) {
                        return PopupMenuItem(value: voice, child: Text(voice));
                      }).toList(),
                      icon: const Icon(Icons.arrow_drop_down),
                    )
                  : const Icon(Icons.arrow_drop_down),
              onTap: () {
                if (_voices.isEmpty && _settings.provider != TtsProvider.mimo) {
                  return;
                }
                showModalBottomSheet(
                  context: context,
                  builder: (context) => _buildVoiceSheet(context, colorScheme),
                );
              },
            ),
          ],

          // ── 小米 MiMo TTS 配置 ────────────────────────
          if (_settings.provider == TtsProvider.mimo) ...[
            const Divider(),

            // API Key（敏感信息存 Secure Storage）
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                controller: _mimoApiKeyController,
                obscureText: _obscureMimoApiKey,
                decoration: InputDecoration(
                  labelText: 'MiMo API Key',
                  hintText: '在 platform.xiaomimimo.com 控制台获取',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.vpn_key),
                  helperMaxLines: 2,
                  helperText: _mimoReady
                      ? '已配置 API Key；清空后点保存可移除'
                      : '未配置：MiMo TTS 需要 API Key 才能合成语音',
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: _obscureMimoApiKey ? '显示' : '隐藏',
                        icon: Icon(
                          _obscureMimoApiKey
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () => setState(
                          () => _obscureMimoApiKey = !_obscureMimoApiKey,
                        ),
                      ),
                      IconButton(
                        tooltip: '保存',
                        icon: const Icon(Icons.save_outlined),
                        onPressed: _saveMimoApiKey,
                      ),
                    ],
                  ),
                ),
                onSubmitted: (_) => _saveMimoApiKey(),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Text(
                '语音由小米 MiMo 云端合成（当前限时免费），需要网络连接；'
                '合成失败时会自动降级到系统 TTS。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),

            // 风格指令：作为 user 消息，用自然语言控制风格
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: TextField(
                controller: _mimoInstructionController,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '风格指令（可选）',
                  hintText: '如：用标准美式发音，语速稍慢，语气自然',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.auto_fix_high),
                  helperMaxLines: 2,
                  helperText: '作为 user 消息发送，可控制语速、情绪、方言、角色扮演等',
                ),
                onChanged: (value) => _updateSettingsDebounced(
                  _settings.copyWith(mimoInstruction: value),
                ),
                onEditingComplete: _flushPendingPersist,
              ),
            ),

            // 高级设置
            ExpansionTile(
              leading: Icon(Icons.settings_suggest, color: colorScheme.primary),
              title: const Text('MiMo 高级设置'),
              subtitle: const Text('接口地址、模型与音频标签前缀'),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              children: [
                TextField(
                  controller: _mimoBaseUrlController,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.link),
                    helperMaxLines: 2,
                    helperText: '默认使用官方地址；接入兼容中转服务时可修改',
                  ),
                  onChanged: (value) => _updateSettingsDebounced(
                    _settings.copyWith(mimoBaseUrl: value),
                  ),
                  onEditingComplete: _flushPendingPersist,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _mimoModelController,
                  decoration: const InputDecoration(
                    labelText: '模型',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.smart_toy_outlined),
                    helperMaxLines: 3,
                    helperText: '默认 mimo-v2.5-tts（预置音色）；音色设计 / 音色复刻模型暂未适配',
                  ),
                  onChanged: (value) => _updateSettingsDebounced(
                    _settings.copyWith(mimoModel: value),
                  ),
                  onEditingComplete: _flushPendingPersist,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _mimoStyleTagController,
                  decoration: const InputDecoration(
                    labelText: '音频标签前缀（可选）',
                    hintText: '如：东北话 / 唱歌',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.label_outline),
                    helperMaxLines: 3,
                    helperText: '自动加括号拼在待朗读文本最前，如 (东北话)hello；支持情绪、方言、唱歌等标签',
                  ),
                  onChanged: (value) => _updateSettingsDebounced(
                    _settings.copyWith(mimoStyleTag: value),
                  ),
                  onEditingComplete: _flushPendingPersist,
                ),
              ],
            ),
          ],

          const Divider(),

          // ── 试听测试 ─────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: TextField(
              controller: _testTextController,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: '测试文本',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.record_voice_over),
                helperMaxLines: 2,
                helperText: '用当前服务商、音色与参数试听；失败原因可在「日志」中查看',
              ),
              onSubmitted: (_) => _testTts(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
            child: Row(
              children: [
                FilledButton.tonalIcon(
                  onPressed: _isTesting ? null : _testTts,
                  icon: _isTesting
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow_rounded, size: 20),
                  label: Text(_isTesting ? '合成中…' : '试听'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () => TtsService.instance.stop(),
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: const Text('停止'),
                ),
                const Spacer(),
                if (_settings.provider == TtsProvider.mimo && !_mimoReady)
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 20,
                    color: colorScheme.error,
                  ),
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0)),

          const Divider(),

          // 自动朗读设置
          SwitchListTile(
            secondary: Icon(Icons.visibility, color: colorScheme.primary),
            title: const Text('浏览阶段自动朗读'),
            subtitle: const Text('在学习/复习的浏览阶段自动朗读单词'),
            value: _settings.autoReadBrowse,
            onChanged: (value) {
              _updateSettings(_settings.copyWith(autoReadBrowse: value));
            },
          ),
          SwitchListTile(
            secondary: Icon(Icons.psychology, color: colorScheme.primary),
            title: const Text('回忆阶段自动朗读'),
            subtitle: const Text('在回忆阶段自动朗读单词'),
            value: _settings.autoReadRecall,
            onChanged: (value) {
              _updateSettings(_settings.copyWith(autoReadRecall: value));
            },
          ),
        ],
      ],
    );
  }
}
