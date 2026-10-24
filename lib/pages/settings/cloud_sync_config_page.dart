import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';

import '../../models/cloud_sync_manifest.dart';
import '../../services/cloud/cloud_sync_bootstrap_service.dart';
import '../../services/cloud/cloud_sync_introduction_service.dart';
import '../../services/cloud/cloud_sync_service.dart';
import '../../services/cloud/cloud_sync_settings.dart';
import '../../services/cloud/cloud_sync_foreground_sync_service.dart';
import '../../services/cloud/cloud_sync_run_lock.dart';
import '../../services/cloud/sync_capture_service.dart';
import 'cloud_sync_progress.dart';

/// 对象存储配置页。
///
/// 保存前默认执行一次真实读写自检（Bucket / PUT / GET / LIST / DELETE），
/// 避免把错误配置写入后，用户直到同步失败才发现问题。
class CloudSyncConfigPage extends StatefulWidget {
  const CloudSyncConfigPage({super.key});

  @override
  State<CloudSyncConfigPage> createState() => _CloudSyncConfigPageState();
}

class _CloudSyncConfigPageState extends State<CloudSyncConfigPage> {
  final _formKey = GlobalKey<FormState>();
  final _endpointController = TextEditingController();
  final _bucketController = TextEditingController();
  final _regionController = TextEditingController(text: 'us-east-1');
  final _prefixController = TextEditingController(
    text: CloudSyncConfig.defaultPrefix,
  );
  final _accessKeyController = TextEditingController();
  final _secretKeyController = TextEditingController();
  final _deviceNameController = TextEditingController();

  bool _pathStyle = true;
  int _retainCount = CloudSyncConfig.defaultRetainCount;
  bool _autoSync = true;
  int _autoSyncIntervalMinutes = 5;
  bool _wifiOnly = false;
  bool _autoCheckpoint = true;
  bool _obscureAccessKey = true;
  bool _obscureSecretKey = true;
  bool _loading = true;
  bool _saving = false;
  String _deviceId = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _endpointController.dispose();
    _bucketController.dispose();
    _regionController.dispose();
    _prefixController.dispose();
    _accessKeyController.dispose();
    _secretKeyController.dispose();
    _deviceNameController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final config = await CloudSyncSettings.loadConfig();
    final credentials = await CloudSyncSettings.loadCredentials();
    final deviceId = await CloudSyncSettings.getOrCreateDeviceId();
    final deviceName = await CloudSyncSettings.getOrCreateDeviceName(deviceId);
    if (!mounted) return;
    setState(() {
      if (config != null) {
        _endpointController.text = config.displayEndpoint;
        _bucketController.text = config.bucket;
        _regionController.text = config.region;
        _prefixController.text = config.prefix;
        _pathStyle = config.pathStyle;
        _retainCount = config.retainCount;
        _autoSync = config.autoSync;
        _autoSyncIntervalMinutes = config.autoSyncIntervalMinutes;
        _wifiOnly = config.wifiOnly;
        _autoCheckpoint = config.autoCheckpoint;
      }
      _accessKeyController.text = credentials?.accessKey ?? '';
      _secretKeyController.text = credentials?.secretKey ?? '';
      _deviceId = deviceId;
      _deviceNameController.text = deviceName;
      _loading = false;
    });
  }

  CloudSyncConfig _parseConfig() {
    return CloudSyncConfig.create(
      endpointInput: _endpointController.text,
      bucket: _bucketController.text,
      region: _regionController.text,
      prefix: _prefixController.text,
      pathStyle: _pathStyle,
      retainCount: _retainCount,
      autoSync: _autoSync,
      autoSyncIntervalMinutes: _autoSyncIntervalMinutes,
      wifiOnly: _wifiOnly,
      autoCheckpoint: _autoCheckpoint,
    );
  }

  /// 返回表单中新输入的凭据；两项都为空时返回 null（表示沿用已保存凭据）。
  CloudSyncCredentials? _enteredCredentials() {
    final accessKey = _accessKeyController.text.trim();
    final secretKey = _secretKeyController.text.trim();
    if (accessKey.isEmpty && secretKey.isEmpty) return null;
    if (accessKey.isEmpty || secretKey.isEmpty) {
      throw const CloudSyncException('Access Key 与 Secret Key 需要同时填写');
    }
    return CloudSyncCredentials(accessKey: accessKey, secretKey: secretKey);
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Theme.of(context).colorScheme.error : null,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _testConnection() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final CloudSyncConfig config;
    final CloudSyncCredentials? credentials;
    try {
      config = _parseConfig();
      credentials =
          _enteredCredentials() ?? await CloudSyncSettings.loadCredentials();
    } on CloudSyncException catch (e) {
      _showSnack(e.message, isError: true);
      return;
    }
    if (credentials == null || !credentials.isComplete) {
      _showSnack('请先填写 Access Key 与 Secret Key', isError: true);
      return;
    }
    if (!mounted) return;

    final creds = credentials;
    try {
      final message = await runWithProgressDialog<String>(
        context,
        title: '测试连接',
        task: (update) async {
          update('正在验证 ${config.bucket} 的读写权限…');
          return CloudSyncService.testConfig(config, creds);
        },
      );
      if (message == null) return;
      _showSnack(message);
    } catch (e) {
      _showSnack('连接失败：$e', isError: true);
    }
  }

  /// 新设备首次配置：本机没有业务数据且云端有快照时，询问是否引导。
  Future<void> _maybeBootstrap() async {
    try {
      if (await CloudSyncBootstrapService.hasLocalData()) return;
      final candidate = await CloudSyncBootstrapService.findLatestSnapshot();
      if (candidate == null || !mounted) return;
      final summary = candidate.summary;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('发现云端数据'),
          content: Text(
            '本机还没有学习数据，云端已有一份统一数据'
            '（${summary.latest!.createdAt.toLocal()}）。\n\n'
            '是否立即用云端数据初始化本机？当前空库不会丢失任何学习记录。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后手动恢复'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('立即引导'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await runWithProgressDialog<CloudRestoreOutcome>(
        context,
        title: '从云端引导',
        task: (update) async {
          update('正在下载并校验云端数据…');
          return candidate.service.restoreSnapshot(summary);
        },
      );
      await CloudSyncSettings.saveIntroDecision(
        summary.manifest.deviceId,
        CloudSyncIntroAction.useCloud.storageValue,
      );
      if (mounted) _showSnack('已从云端引导，建议重启应用');
    } catch (e) {
      if (mounted) _showSnack('自动引导失败：$e', isError: true);
    }
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;

    CloudSyncConfig? config;
    CloudSyncCredentials? credentials;
    try {
      config = _parseConfig();
      final entered = _enteredCredentials();
      final stored = await CloudSyncSettings.loadCredentials();
      final resolved = entered ?? stored;
      if (resolved == null || !resolved.isComplete) {
        _showSnack('请填写 Access Key 与 Secret Key', isError: true);
        return;
      }
      credentials = resolved;
    } on CloudSyncException catch (e) {
      _showSnack(e.message, isError: true);
      return;
    }

    final resolvedConfig = config;
    final resolvedCredentials = credentials;
    if (!mounted) return;
    setState(() => _saving = true);

    try {
      // 保存前先做一次真实连接自检；失败时允许用户选择离线保存。
      try {
        await runWithProgressDialog<String>(
          context,
          title: '验证配置',
          task: (update) async {
            update('正在验证 ${resolvedConfig.bucket} 的读写权限…');
            return CloudSyncService.testConfig(
              resolvedConfig,
              resolvedCredentials,
            );
          },
        );
      } catch (e) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('连接测试失败'),
            content: Text('$e\n\n仍要保存这份配置吗？保存后可以稍后重试连接。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('返回修改'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('仍然保存'),
              ),
            ],
          ),
        );
        if (proceed != true) return;
      }

      await CloudSyncSettings.saveConfig(resolvedConfig);
      await CloudSyncSettings.saveCredentials(resolvedCredentials);
      await CloudSyncSettings.saveDeviceName(_deviceNameController.text);
      // 配置成功后开启变更捕获；失败不影响配置保存
      try {
        await SyncCaptureService.setCaptureEnabled(enabled: true);
      } catch (_) {}
      // 按新配置重建前台轮询（关闭自动同步时会自动停止）
      unawaited(CloudSyncForegroundSyncService.instance.start());
      await _maybeBootstrap();
      if (!mounted) return;
      _showSnack('配置已保存');
      Navigator.of(context).pop(true);
    } catch (e) {
      _showSnack('保存失败：$e', isError: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetDeviceId() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('重置设备标识'),
        content: const Text(
          '重置后云端会把本机视为一台新设备。\n\n'
          '本机现有数据仍会保留；重置后会被视为一台新设备，'
          '需要重新确认如何接入云端统一数据。\n\n确定要重置吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('重置'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final id = await CloudSyncSettings.resetDeviceId();
    final name = await CloudSyncSettings.getOrCreateDeviceName(id);
    if (!mounted) return;
    setState(() {
      _deviceId = id;
      _deviceNameController.text = name;
    });
    _showSnack('设备标识已重置');
  }

  Future<void> _clearConfig() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清除云同步配置'),
        content: const Text(
          '将清除本机保存的端点、存储桶、Access Key / Secret Key 与同步状态。\n\n'
          '云端已有的统一数据不会被删除。确定继续吗？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await CloudSyncRunLock.runExclusive(() async {
      await CloudSyncSettings.clearAll();
      await SyncCaptureService.setCaptureEnabled(enabled: false);
    });
    CloudSyncForegroundSyncService.instance.stop();
    if (!mounted) return;
    _endpointController.clear();
    _bucketController.clear();
    _accessKeyController.clear();
    _secretKeyController.clear();
    _prefixController.text = CloudSyncConfig.defaultPrefix;
    _showSnack('云同步配置已清除');
    Navigator.of(context).pop(true);
  }

  Future<void> _copyDeviceId() async {
    await Clipboard.setData(ClipboardData(text: _deviceId));
    _showSnack('设备标识已复制');
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        text,
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildNoticeCard(ColorScheme colorScheme) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text(
                '凭据只保存在本机安全存储',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Access Key / Secret Key 不会写入备份，也不会随云同步上传。'
            '建议使用私有桶，并只授予该前缀的 Get / Put / List / Delete 权限。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 18, color: colorScheme.tertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '云端只保存一份统一数据。首次把已有本地数据的设备接入时，'
                  '会询问一次：合并两端、以本机为准或以云端为准。'
                  '系统会自动发布基线和处理合并，不需要手动上传备份。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPathStyleHint(ColorScheme colorScheme) {
    return Text(
      '自建 MinIO / Rain 等非 AWS 端点通常使用 path-style（默认开启）；'
      'AWS S3 可关闭以使用虚拟主机风格。',
      style: Theme.of(
        context,
      ).textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('对象存储配置'), centerTitle: false),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                children: [
                  _buildNoticeCard(colorScheme),
                  _sectionTitle('连接信息'),
                  TextFormField(
                    controller: _endpointController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '访问端点',
                      hintText: 'https://cn-nb1.rains3.com',
                      helperText: '只填写域名与端口，不要带存储桶或路径',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                        ? '请填写访问端点'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _bucketController,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: '存储桶',
                      hintText: 'aquamarina-test',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) =>
                        (value == null || value.trim().isEmpty)
                        ? '请填写存储桶名称'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _regionController,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: '区域',
                            hintText: 'cn-nb1 / us-east-1 / auto',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) =>
                              (value == null || value.trim().isEmpty)
                              ? '请填写区域'
                              : null,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _prefixController,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: '路径前缀',
                            hintText: 'aquamarina',
                            border: OutlineInputBorder(),
                          ),
                          validator: (value) =>
                              (value == null || value.trim().isEmpty)
                              ? '请填写路径前缀'
                              : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('使用 path-style 访问'),
                    subtitle: _buildPathStyleHint(colorScheme),
                    value: _pathStyle,
                    onChanged: (value) => setState(() => _pathStyle = value),
                  ),

                  DropdownButtonFormField<int>(
                    initialValue: _retainCount,
                    decoration: const InputDecoration(
                      labelText: '云端保留份数',
                      helperText: '超出数量的旧快照会在上传成功后自动清理',
                      border: OutlineInputBorder(),
                    ),
                    items: const [1, 3, 5, 10, 20, 50]
                        .map(
                          (value) => DropdownMenuItem<int>(
                            value: value,
                            child: Text('$value 份'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value != null) setState(() => _retainCount = value);
                    },
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('启动 / 回到前台时自动同步'),
                    subtitle: const Text('学习结束后会立即同步一次；前台按下方间隔轮询，失败静默重试'),
                    value: _autoSync,
                    onChanged: (value) => setState(() => _autoSync = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('仅 Wi-Fi / 以太网自动同步'),
                    subtitle: const Text('移动流量下跳过自动同步；手动同步不受限制'),
                    value: _wifiOnly,
                    onChanged: (value) => setState(() => _wifiOnly = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('自动生成检查点'),
                    subtitle: const Text('每 7 天或累计 5000 条变更上传一份完整快照'),
                    value: _autoCheckpoint,
                    onChanged: (value) =>
                        setState(() => _autoCheckpoint = value),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: _autoSyncIntervalMinutes,
                    decoration: const InputDecoration(
                      labelText: '自动同步间隔',
                      helperText: '仅影响前台轮询与自动同步冷却；学习结束后仍会立即同步',
                      border: OutlineInputBorder(),
                    ),
                    items: const [1, 5, 15, 30]
                        .map(
                          (value) => DropdownMenuItem<int>(
                            value: value,
                            child: Text('$value 分钟'),
                          ),
                        )
                        .toList(),
                    onChanged: _autoSync
                        ? (value) {
                            if (value != null) {
                              setState(() => _autoSyncIntervalMinutes = value);
                            }
                          }
                        : null,
                  ),
                  _sectionTitle('访问凭据'),
                  TextFormField(
                    controller: _accessKeyController,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Access Key',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureAccessKey
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(
                          () => _obscureAccessKey = !_obscureAccessKey,
                        ),
                      ),
                    ),
                    obscureText: _obscureAccessKey,
                    validator: (value) {
                      final access = value?.trim() ?? '';
                      final secret = _secretKeyController.text.trim();
                      if (access.isEmpty && secret.isNotEmpty) {
                        return '请填写 Access Key';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _secretKeyController,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: InputDecoration(
                      labelText: 'Secret Key',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(
                          _obscureSecretKey
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(
                          () => _obscureSecretKey = !_obscureSecretKey,
                        ),
                      ),
                    ),
                    obscureText: _obscureSecretKey,
                    validator: (value) {
                      final secret = value?.trim() ?? '';
                      final access = _accessKeyController.text.trim();
                      if (secret.isEmpty && access.isNotEmpty) {
                        return '请填写 Secret Key';
                      }
                      return null;
                    },
                  ),

                  _sectionTitle('设备信息'),
                  TextFormField(
                    controller: _deviceNameController,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: '设备名称',
                      helperText: '用于在「从云端恢复」时区分不同设备',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('设备标识'),
                    subtitle: SelectableText(
                      _deviceId,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    trailing: IconButton(
                      tooltip: '复制',
                      icon: const Icon(Icons.copy_outlined),
                      onPressed: _copyDeviceId,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: _resetDeviceId,
                      icon: const Icon(Icons.restart_alt),
                      label: const Text('重置设备标识'),
                      style: TextButton.styleFrom(
                        foregroundColor: colorScheme.error,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _saving ? null : _testConnection,
                    icon: const Icon(Icons.wifi_tethering),
                    label: const Text('测试连接'),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(_saving ? '保存中…' : '保存配置'),
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: TextButton(
                      onPressed: _saving ? null : _clearConfig,
                      style: TextButton.styleFrom(
                        foregroundColor: colorScheme.error,
                      ),
                      child: const Text('清除云同步配置'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}
