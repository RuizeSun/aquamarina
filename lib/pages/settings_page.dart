import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ai_config.dart';
import '../services/ai_config_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  int _reviewLimit = 10;
  int _learningLimit = 10;

  // AI 配置相关
  final AiConfigService _aiConfigService = AiConfigService();
  late AiConfig _aiConfig;

  static const String _reviewLimitKey = 'review_limit';
  static const String _learningLimitKey = 'learning_limit';

  @override
  void initState() {
    super.initState();
    _aiConfig = const AiConfig();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _reviewLimit = prefs.getInt(_reviewLimitKey) ?? 10;
      _learningLimit = prefs.getInt(_learningLimitKey) ?? 10;
    });
    await prefs.setInt(_reviewLimitKey, _reviewLimit);
    await prefs.setInt(_learningLimitKey, _learningLimit);

    // 加载 AI 配置
    await _aiConfigService.load();
    if (mounted) {
      setState(() {
        _aiConfig = _aiConfigService.config;
      });
    }
  }

  Future<void> _setReviewLimit(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_reviewLimitKey, value);
    setState(() => _reviewLimit = value);
  }

  Future<void> _setLearningLimit(int value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_learningLimitKey, value);
    setState(() => _learningLimit = value);
  }

  void _showReviewLimitPicker() {
    _showLimitPicker(
      title: '单次复习上限',
      current: _reviewLimit,
      onSave: _setReviewLimit,
    );
  }

  void _showLearningLimitPicker() {
    _showLimitPicker(
      title: '单次学习上限',
      current: _learningLimit,
      onSave: _setLearningLimit,
    );
  }

  void _showLimitPicker({
    required String title,
    required int current,
    required Future<void> Function(int) onSave,
  }) {
    int temp = current;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(title),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('当前值: $temp'),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: temp > 1
                              ? () => setDialogState(() => temp--)
                              : null,
                        ),
                        const SizedBox(width: 16),
                        Text(
                          '$temp',
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(width: 16),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: temp < 100
                              ? () => setDialogState(() => temp++)
                              : null,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    onSave(temp);
                    Navigator.of(context).pop();
                  },
                  child: const Text('确认'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // ===== AI 配置对话框 =====

  void _showAiBaseUrlDialog() {
    final controller = TextEditingController(text: _aiConfig.baseUrl);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Base URL'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'https://api.openai.com/v1',
              helperText: '请输入 OpenAI 兼容 API 的基础地址',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final trimmed = controller.text.trim();
                await _aiConfigService.saveConfig(
                  _aiConfig.copyWith(baseUrl: trimmed),
                );
                if (!context.mounted) return;
                setState(() => _aiConfig = _aiConfigService.config);
                Navigator.of(context).pop();
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
  }

  void _showApiKeyDialog() {
    final controller = TextEditingController(text: _aiConfig.apiKey);
    bool obscure = true;
    showDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('API Key'),
              content: TextField(
                controller: controller,
                obscureText: obscure,
                decoration: InputDecoration(
                  hintText: 'sk-...',
                  helperText: 'API Key 将安全存储在系统凭据管理器中',
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscure ? Icons.visibility_off : Icons.visibility,
                    ),
                    onPressed: () => setDialogState(() => obscure = !obscure),
                  ),
                ),
                autofocus: true,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    final trimmed = controller.text.trim();
                    await _aiConfigService.saveApiKey(trimmed);
                    if (!context.mounted) return;
                    setState(() => _aiConfig = _aiConfigService.config);
                    Navigator.of(context).pop();
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _showModelDialog() {
    final controller = TextEditingController(text: _aiConfig.model);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('模型'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: 'gpt-4o-mini',
              helperText: '使用的模型名称',
              border: OutlineInputBorder(),
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final trimmed = controller.text.trim();
                await _aiConfigService.saveConfig(
                  _aiConfig.copyWith(model: trimmed),
                );
                if (!context.mounted) return;
                setState(() => _aiConfig = _aiConfigService.config);
                Navigator.of(context).pop();
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _testConnection() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('正在测试连接...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final result = await _aiConfigService.testConnection();
      if (!context.mounted) return;
      Navigator.of(context).pop();
      _showResultSnackBar(result, isSuccess: true);
    } on AiConfigException catch (e) {
      if (!context.mounted) return;
      Navigator.of(context).pop();
      _showResultSnackBar(e.toString(), isSuccess: false);
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context).pop();
      _showResultSnackBar('连接失败：$e', isSuccess: false);
    }
  }

  void _showResultSnackBar(String message, {required bool isSuccess}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ===== Build =====

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final apiKeyMasked = _aiConfig.apiKey.isEmpty
        ? '未设置'
        : '${_aiConfig.apiKey.substring(0, 8)}...${_aiConfig.apiKey.substring(_aiConfig.apiKey.length - 4)}';

    return Scaffold(
      appBar: AppBar(title: const Text('设置'), centerTitle: false),
      body: ListView(
        children: [
          const SizedBox(height: 8),

          // ---- 背单词设置 ----
          _SectionHeader(title: '背单词设置'),
          ListTile(
            leading: Icon(Icons.replay, color: colorScheme.primary),
            title: const Text('单次复习上限'),
            subtitle: Text('每次复习最多 $_reviewLimit 个单词'),
            trailing: Text(
              '$_reviewLimit',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            onTap: _showReviewLimitPicker,
          ),
          ListTile(
            leading: Icon(Icons.auto_stories, color: colorScheme.primary),
            title: const Text('单次学习上限'),
            subtitle: Text('每次学习最多 $_learningLimit 个新词'),
            trailing: Text(
              '$_learningLimit',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            onTap: _showLearningLimitPicker,
          ),

          const Divider(),

          // ---- AI 服务配置 ----
          _SectionHeader(title: 'AI 服务配置'),
          ListTile(
            leading: Icon(Icons.link, color: colorScheme.primary),
            title: const Text('Base URL'),
            subtitle: Text(_aiConfig.baseUrl, overflow: TextOverflow.ellipsis),
            onTap: _showAiBaseUrlDialog,
          ),
          ListTile(
            leading: Icon(Icons.vpn_key, color: colorScheme.primary),
            title: const Text('API Key'),
            subtitle: Text(apiKeyMasked, overflow: TextOverflow.ellipsis),
            onTap: _showApiKeyDialog,
          ),
          ListTile(
            leading: Icon(Icons.smart_toy, color: colorScheme.primary),
            title: const Text('模型'),
            subtitle: Text(_aiConfig.model),
            onTap: _showModelDialog,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: OutlinedButton.icon(
              onPressed: _testConnection,
              icon: const Icon(Icons.wifi_find),
              label: const Text('测试连接'),
            ),
          ),

          const Divider(),

          // ---- 关于 ----
          ListTile(
            leading: Icon(Icons.info_outline, color: colorScheme.primary),
            title: const Text('关于 Aquamarina'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _showAbout(context),
          ),
        ],
      ),
    );
  }

  void _showAbout(BuildContext context) async {
    final platform = Theme.of(context).platform == TargetPlatform.android
        ? 'Android'
        : Theme.of(context).platform == TargetPlatform.iOS
        ? 'iOS'
        : 'Windows';
    final info = await PackageInfo.fromPlatform();
    final version = 'v${info.version}';
    if (!context.mounted) return;
    showAboutDialog(
      context: context,
      applicationName: info.appName,
      applicationVersion: version,
      applicationLegalese: '当前平台: $platform',
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;

  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
