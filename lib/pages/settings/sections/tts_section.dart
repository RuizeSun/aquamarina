import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    _settings = await TtsSettings.load();
    if (!mounted) return;
    setState(() => _isLoading = false);
    // 异步加载音色列表
    _loadVoices();
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
            trailing: SegmentedButton<TtsProvider>(
              segments: const [
                ButtonSegment(
                  value: TtsProvider.system,
                  label: Text('系统'),
                  icon: Icon(Icons.phone_android, size: 18),
                ),
                ButtonSegment(
                  value: TtsProvider.edge,
                  label: Text('Edge'),
                  icon: Icon(Icons.language, size: 18),
                ),
              ],
              selected: {_settings.provider},
              onSelectionChanged: (selected) {
                _updateSettings(_settings.copyWith(provider: selected.first));
              },
              style: ButtonStyle(
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
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
                '语速: ${_settings.rate.toStringAsFixed(1)}x',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),

          // 音调
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
                    onChanged: (value) {
                      setState(
                        () => _settings = _settings.copyWith(pitch: value),
                      );
                    },
                    onChangeEnd: (value) {
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
                '音调: ${_settings.pitch.toStringAsFixed(1)}x',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),

          // 音色选择（Edge TTS 显示）
          if (_settings.provider == TtsProvider.edge) ...[
            ListTile(
              leading: Icon(
                Icons.record_voice_over,
                color: colorScheme.primary,
              ),
              title: const Text('音色'),
              subtitle: Text(_settings.voiceName ?? '默认音色'),
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
                if (_voices.isNotEmpty) {
                  showModalBottomSheet(
                    context: context,
                    builder: (context) {
                      return SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text(
                                '选择音色',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            const Divider(height: 1),
                            SizedBox(
                              height: 300,
                              child: ListView.separated(
                                itemCount: _voices.length,
                                separatorBuilder: (_, _) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final voice = _voices[index];
                                  final isSelected =
                                      voice == _settings.voiceName;
                                  return ListTile(
                                    selected: isSelected,
                                    selectedTileColor: colorScheme
                                        .primaryContainer
                                        .withValues(alpha: 0.3),
                                    title: Text(voice),
                                    trailing: isSelected
                                        ? Icon(
                                            Icons.check,
                                            color: colorScheme.primary,
                                          )
                                        : null,
                                    onTap: () {
                                      Navigator.of(context).pop();
                                      _updateSettings(
                                        _settings.copyWith(voiceName: voice),
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                }
              },
            ),
          ],

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
