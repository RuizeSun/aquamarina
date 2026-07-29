import 'package:flutter/material.dart';
import '../models/ai_profile.dart';
import '../services/ai_profile_service.dart';

/// AI 配置文件编辑页
class AiProfileEditPage extends StatefulWidget {
  final AiProfileService profileService;
  final AiProfile? profile;

  /// profile 为 null 或 isNew=true 时表示新建
  final bool isNew;

  const AiProfileEditPage({
    super.key,
    required this.profileService,
    this.profile,
    this.isNew = false,
  });

  @override
  State<AiProfileEditPage> createState() => _AiProfileEditPageState();
}

class _AiProfileEditPageState extends State<AiProfileEditPage> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _baseUrlController;
  late TextEditingController _apiKeyController;
  late TextEditingController _modelController;
  late TextEditingController _maxTokensController;
  late TextEditingController _temperatureController;
  late TextEditingController _balanceThresholdController;

  late AiProfileType _type;
  late bool _enableThinking;
  late String? _reasoningEffort;
  late double? _temperature;
  late double? _balanceThreshold;

  bool _isSaving = false;
  bool _obscureApiKey = true;

  // 模型列表
  List<String>? _availableModels;
  bool _isLoadingModels = false;

  /// 非新建模式且已有 profile 才视为编辑
  bool get _isEditing => !widget.isNew && widget.profile != null;

  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _nameController = TextEditingController(text: p?.name ?? '');
    _baseUrlController = TextEditingController(
      text: p?.baseUrl ?? 'https://api.openai.com/v1',
    );
    _apiKeyController = TextEditingController(text: p?.apiKey ?? '');
    _modelController = TextEditingController(text: p?.model ?? 'gpt-4o-mini');
    _maxTokensController = TextEditingController(
      text: '${p?.maxTokens ?? 2048}',
    );
    _temperatureController = TextEditingController(
      text: p?.temperature != null ? '${p!.temperature}' : '0.7',
    );
    _balanceThresholdController = TextEditingController(
      text: p?.balanceThreshold != null ? '${p!.balanceThreshold}' : '',
    );

    _type = p?.type ?? AiProfileType.openai;
    _enableThinking = p?.enableThinking ?? false;
    _reasoningEffort = p?.reasoningEffort;
    _temperature = p?.temperature;
    _balanceThreshold = p?.balanceThreshold;

    // DeepSeek 类型：监听 API Key 输入变化，自动拉取模型列表
    if (_type == AiProfileType.deepseek) {
      _apiKeyController.addListener(_onApiKeyChanged);
      // 如果已有 API Key，立即拉取
      if (_apiKeyController.text.trim().isNotEmpty) {
        _fetchModels();
      }
    }
  }

  void _onApiKeyChanged() {
    if (_type == AiProfileType.deepseek &&
        _apiKeyController.text.trim().isNotEmpty &&
        (_availableModels == null)) {
      _fetchModels();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    _maxTokensController.dispose();
    _temperatureController.dispose();
    _balanceThresholdController.dispose();
    super.dispose();
  }

  Future<void> _fetchModels() async {
    final apiKey = _apiKeyController.text.trim();
    final baseUrl = _baseUrlController.text.trim();
    if (apiKey.isEmpty) return;

    setState(() => _isLoadingModels = true);

    try {
      // 构建临时 profile 用于请求
      final tempProfile = AiProfile(
        id: widget.profile?.id ?? '',
        name: _nameController.text.trim(),
        type: _type,
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: _modelController.text.trim(),
        maxTokens: int.tryParse(_maxTokensController.text.trim()) ?? 2048,
      );
      final models = await widget.profileService.fetchModels(tempProfile);
      if (!mounted) return;
      setState(() {
        _availableModels = models;
        _isLoadingModels = false;
      });

      if (models.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已获取 ${models.length} 个模型'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _availableModels = null;
        _isLoadingModels = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('拉取模型列表失败，请手动输入'),
          backgroundColor: Colors.orange,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _checkBalance() async {
    final apiKey = _apiKeyController.text.trim();
    final baseUrl = _baseUrlController.text.trim();
    if (apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('请先输入 API Key'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

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
                Text('正在查询余额...'),
              ],
            ),
          ),
        ),
      ),
    );

    try {
      final tempProfile = AiProfile(
        id: widget.profile?.id ?? '',
        name: _nameController.text.trim(),
        type: _type,
        baseUrl: baseUrl,
        apiKey: apiKey,
        model: _modelController.text.trim(),
        maxTokens: int.tryParse(_maxTokensController.text.trim()) ?? 2048,
      );
      final balance = await widget.profileService.checkBalance(tempProfile);
      if (!mounted) return;
      Navigator.of(context).pop();

      showDialog(
        context: context,
        builder: (context) {
          return AlertDialog(
            title: Row(
              children: [
                Icon(
                  balance.isAvailable
                      ? Icons.check_circle
                      : Icons.error_outline,
                  color: balance.isAvailable ? Colors.green : Colors.red,
                ),
                const SizedBox(width: 8),
                const Text('账户余额'),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!balance.isAvailable)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('账户不可用', style: TextStyle(color: Colors.red)),
                  ),
                ...balance.balanceInfos.map(
                  (info) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('${info.currency} 余额：'),
                        Text(
                          '¥${info.totalBalance}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('关闭'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('查询失败：$e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    final profile = AiProfile(
      id: widget.profile?.id ?? '',
      name: _nameController.text.trim(),
      type: _type,
      baseUrl: _baseUrlController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim(),
      maxTokens: int.tryParse(_maxTokensController.text.trim()) ?? 2048,
      temperature: _temperature,
      enableThinking: _enableThinking,
      reasoningEffort: _reasoningEffort,
      isDefault: widget.profile?.isDefault ?? false,
      balanceThreshold: _balanceThreshold,
    );

    try {
      if (_isEditing) {
        await widget.profileService.updateProfile(profile);
      } else {
        await widget.profileService.addProfile(profile.copyWith(id: null));
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('保存失败：$e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  /// 构建模型输入字段（下拉选择或文本输入）
  Widget _buildModelField() {
    final hasModels = _availableModels != null && _availableModels!.isNotEmpty;

    if (hasModels) {
      return DropdownButtonFormField<String>(
        value: _availableModels!.contains(_modelController.text)
            ? _modelController.text
            : null,
        decoration: const InputDecoration(
          labelText: '模型',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.smart_toy),
        ),
        items: _availableModels!
            .map(
              (m) => DropdownMenuItem(
                value: m,
                child: Text(m, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: (v) {
          if (v != null) {
            _modelController.text = v;
          }
        },
      );
    }

    return TextFormField(
      controller: _modelController,
      decoration: InputDecoration(
        labelText: '模型',
        hintText: _type == AiProfileType.deepseek
            ? 'deepseek-chat'
            : 'gpt-4o-mini',
        border: const OutlineInputBorder(),
        prefixIcon: const Icon(Icons.smart_toy),
      ),
      validator: (v) => (v == null || v.trim().isEmpty) ? '请输入模型名称' : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAquamarina = _type == AiProfileType.aquamarina;

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑配置' : '新建配置'),
        centerTitle: false,
        actions: [
          TextButton(
            onPressed: _isSaving ? null : _save,
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('保存'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ---- 名称 ----
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: '配置名称',
                hintText: '例如：Aquamarina 官方',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.label),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? '请输入配置名称' : null,
            ),
            const SizedBox(height: 16),

            // ---- 类型 ----
            DropdownButtonFormField<AiProfileType>(
              value: _type,
              decoration: const InputDecoration(
                labelText: '配置类型',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.category),
              ),
              items: const [
                DropdownMenuItem(
                  value: AiProfileType.openai,
                  child: Text('OpenAI 兼容协议'),
                ),
                DropdownMenuItem(
                  value: AiProfileType.deepseek,
                  child: Text('DeepSeek'),
                ),
                DropdownMenuItem(
                  value: AiProfileType.aquamarina,
                  child: Text('Aquamarina 官方'),
                ),
              ],
              onChanged: (v) {
                if (v == null) return;
                setState(() {
                  _type = v;
                  if (v == AiProfileType.deepseek) {
                    _baseUrlController.text = 'https://api.deepseek.com';
                    _temperature = null;
                    _temperatureController.text = '';
                    _enableThinking = true;
                    _reasoningEffort = 'high';
                    _apiKeyController.text = '';
                  } else if (v == AiProfileType.aquamarina) {
                    _baseUrlController.text =
                        'https://aquamarina.78go.work/api/v1';
                    _apiKeyController.text = 'aquamarinapublicapi';
                    _modelController.text = 'default';
                    _maxTokensController.text = '4096';
                    _temperature = null;
                    _temperatureController.text = '';
                    _enableThinking = false;
                    _reasoningEffort = null;
                    _balanceThreshold = null;
                    _balanceThresholdController.text = '';
                  } else {
                    _baseUrlController.text = 'https://api.openai.com/v1';
                    _temperature = 0.7;
                    _temperatureController.text = '0.7';
                    _enableThinking = false;
                    _reasoningEffort = null;
                    _apiKeyController.text = '';
                  }
                  _availableModels = null;
                });
                if (_apiKeyController.text.trim().isNotEmpty &&
                    v != AiProfileType.aquamarina) {
                  _fetchModels();
                }
              },
            ),
            const SizedBox(height: 16),

            // ---- Base URL ----
            TextFormField(
              controller: _baseUrlController,
              decoration: InputDecoration(
                labelText: 'Base URL',
                hintText: isAquamarina
                    ? 'https://aquamarina.78go.work/api/v1'
                    : 'https://api.openai.com/v1',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.link),
                helperText: isAquamarina ? '内置公共 API，无需额外配置' : null,
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return '请输入 Base URL';
                final trimmed = v.trim();
                if (!trimmed.startsWith('http://') &&
                    !trimmed.startsWith('https://')) {
                  return '请输入有效的 URL（以 http:// 或 https:// 开头）';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            // ---- API Key ----
            if (isAquamarina)
              TextFormField(
                controller: _apiKeyController,
                readOnly: true,
                decoration: const InputDecoration(
                  labelText: 'API Key',
                  hintText: '内置公共密钥',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.vpn_key),
                  helperText: 'Aquamarina 使用内置公共密钥，无需手动配置',
                  helperMaxLines: 2,
                ),
              )
            else
              TextFormField(
                controller: _apiKeyController,
                obscureText: _obscureApiKey,
                decoration: InputDecoration(
                  labelText: 'API Key',
                  hintText: 'sk-...',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.vpn_key),
                  suffixIcon: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: Icon(
                          _obscureApiKey
                              ? Icons.visibility_off
                              : Icons.visibility,
                        ),
                        onPressed: () =>
                            setState(() => _obscureApiKey = !_obscureApiKey),
                      ),
                      if (_type == AiProfileType.deepseek)
                        IconButton(
                          icon: const Icon(Icons.account_balance_wallet),
                          tooltip: '查询余额',
                          onPressed: _checkBalance,
                        ),
                    ],
                  ),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? '请输入 API Key' : null,
              ),
            const SizedBox(height: 16),

            // ---- 模型 ----
            if (!isAquamarina) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: _buildModelField()),
                  const SizedBox(width: 8),
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: IconButton(
                      onPressed: _apiKeyController.text.trim().isEmpty
                          ? null
                          : _fetchModels,
                      icon: _isLoadingModels
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh),
                      tooltip: '刷新模型列表',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
            ] else
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.teal.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.teal.withValues(alpha: 0.2)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.teal.shade700),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '模型',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '由 Aquamarina 服务端自动路由模型',
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                                ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

            if (!isAquamarina) ...[
              const SizedBox(height: 16),

              // ---- Max Tokens ----
              TextFormField(
                controller: _maxTokensController,
                decoration: const InputDecoration(
                  labelText: 'Max Tokens',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.data_usage),
                ),
                keyboardType: TextInputType.number,
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return '请输入 Max Tokens';
                  final n = int.tryParse(v.trim());
                  if (n == null || n < 1) return '请输入有效的正整数';
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // ---- Temperature（非 DeepSeek 思考模式时才显示） ----
              if (!(_type == AiProfileType.deepseek && _enableThinking)) ...[
                TextFormField(
                  controller: _temperatureController,
                  decoration: const InputDecoration(
                    labelText: 'Temperature',
                    hintText: '0.0 - 2.0',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.thermostat),
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  onChanged: (v) {
                    final parsed = double.tryParse(v.trim());
                    _temperature = parsed;
                  },
                ),
                const SizedBox(height: 16),
              ],
            ],

            // ---- DeepSeek 专属设置 ----
            if (_type == AiProfileType.deepseek) ...[
              const Divider(),
              _SectionHeader(title: 'DeepSeek 专属设置'),

              // 思考模式开关
              SwitchListTile(
                title: const Text('思考模式'),
                subtitle: Text(
                  _enableThinking ? '启用后不支持 temperature 等参数' : '关闭则使用标准对话模式',
                ),
                value: _enableThinking,
                onChanged: (v) {
                  setState(() {
                    _enableThinking = v;
                    if (v) {
                      _temperature = null;
                      _temperatureController.text = '';
                    } else {
                      _temperature = 0.7;
                      _temperatureController.text = '0.7';
                    }
                  });
                },
                secondary: const Icon(Icons.psychology),
              ),

              // 思考强度
              if (_enableThinking) ...[
                DropdownButtonFormField<String>(
                  value: _reasoningEffort ?? 'high',
                  decoration: const InputDecoration(
                    labelText: '思考强度',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.trending_up),
                  ),
                  items: const [
                    DropdownMenuItem(value: 'high', child: Text('High（高）')),
                    DropdownMenuItem(value: 'max', child: Text('Max（最大）')),
                  ],
                  onChanged: (v) {
                    if (v != null) setState(() => _reasoningEffort = v);
                  },
                ),
                const SizedBox(height: 16),
              ],

              // 余额停止使用阈值
              TextFormField(
                controller: _balanceThresholdController,
                decoration: InputDecoration(
                  labelText: '余额停止阈值（¥）',
                  hintText: '为空则不限制',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.monetization_on),
                  helperText: '余额低于此值时停止使用该配置',
                  suffixIcon: IconButton(
                    onPressed: _checkBalance,
                    icon: const Icon(Icons.account_balance_wallet),
                    tooltip: '查询当前余额',
                  ),
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (v) {
                  final trimmed = v.trim();
                  _balanceThreshold = trimmed.isEmpty
                      ? null
                      : double.tryParse(trimmed);
                },
              ),
              const SizedBox(height: 8),
            ],
          ],
        ),
      ),
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
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 8),
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
