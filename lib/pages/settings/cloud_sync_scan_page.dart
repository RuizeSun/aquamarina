import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:pasteboard/pasteboard.dart';

import '../../models/cloud_sync_manifest.dart';
import '../../models/cloud_sync_share_payload.dart';
import '../../services/cloud/cloud_sync_share_service.dart';
import '../../services/system/log_service.dart';
import 'cloud_sync_bootstrap_prompt.dart';
import 'cloud_sync_config_page.dart';
import 'cloud_sync_progress.dart';

/// 相机扫码是否可用。
///
/// mobile_scanner 只实现 Android / iOS / macOS / Web；Windows / Linux 桌面端
/// 无法启动相机，因此这些平台只提供「图片文件」与「剪贴板」两种导入方式。
bool get _cameraSupported {
  if (kIsWeb) return true;
  return Platform.isAndroid || Platform.isIOS || Platform.isMacOS;
}

/// 扫码导入对象存储配置页。
///
/// 三种入口最终都收敛到 [_handleRaw]：
/// 1. 相机实时扫码（移动端 / macOS）；
/// 2. 从图片文件识别（全平台，纯 Dart zxing2）；
/// 3. 从剪贴板粘贴图片（全平台，pasteboard）。
class CloudSyncQrScanPage extends StatefulWidget {
  const CloudSyncQrScanPage({super.key});

  @override
  State<CloudSyncQrScanPage> createState() => _CloudSyncQrScanPageState();
}

class _CloudSyncQrScanPageState extends State<CloudSyncQrScanPage> {
  static const XTypeGroup _imageTypeGroup = XTypeGroup(
    label: '二维码图片',
    extensions: ['png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'],
  );

  MobileScannerController? _controller;
  bool _handling = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (_cameraSupported) {
      _controller = MobileScannerController(
        detectionSpeed: DetectionSpeed.noDuplicates,
        formats: const [BarcodeFormat.qrCode],
      );
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
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

  /// 相机回调：只处理第一条有效内容，处理中忽略后续回调。
  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handling) return;
    final raw = capture.barcodes
        .map((barcode) => barcode.rawValue)
        .firstWhere((value) => value != null && value.trim().isNotEmpty, orElse: () => null);
    if (raw == null) return;
    _handling = true;
    try {
      await _controller?.stop();
      if (!mounted) return;
      await _handleRaw(raw);
    } finally {
      _handling = false;
      // 用户取消导入时恢复扫码，避免相机停在冻结画面。
      if (mounted) {
        try {
          await _controller?.start();
        } catch (_) {}
      }
    }
  }

  Future<void> _pickImage() async {
    if (_busy) return;
    try {
      final file = await openFile(acceptedTypeGroups: const [_imageTypeGroup]);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      await _handleImageBytes(bytes);
    } catch (e) {
      _showSnack('读取图片失败：$e', isError: true);
    }
  }

  Future<void> _pasteImage() async {
    if (_busy) return;
    try {
      final bytes = await Pasteboard.image;
      if (bytes == null || bytes.isEmpty) {
        _showSnack('剪贴板里没有图片', isError: true);
        return;
      }
      await _handleImageBytes(bytes);
    } catch (e) {
      _showSnack('读取剪贴板失败：$e', isError: true);
    }
  }

  Future<void> _pasteText() async {
    if (_busy) return;
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.trim().isEmpty) {
      _showSnack('剪贴板里没有文本', isError: true);
      return;
    }
    await _handleRaw(text);
  }

  Future<void> _handleImageBytes(Uint8List bytes) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      if (bytes.length > CloudSyncShareService.maxImageBytes) {
        _showSnack('图片过大，请使用更小的截图', isError: true);
        return;
      }
      final text = CloudSyncShareService.decodeImageBytes(bytes);
      if (text == null) {
        _showSnack('未识别到二维码，请换一张更清晰的图片', isError: true);
        return;
      }
      await _handleRaw(text);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 统一入口：解析 → 预览确认 → 连接自检 → 落盘 → 首次接入引导。
  Future<void> _handleRaw(String raw) async {
    final CloudSyncSharePayload payload;
    try {
      payload = CloudSyncSharePayload.decode(raw);
    } on CloudSyncException catch (e) {
      _showSnack(e.message, isError: true);
      return;
    } catch (_) {
      _showSnack('二维码内容无法识别', isError: true);
      return;
    }

    final confirmed = await _confirmPayload(payload);
    if (confirmed != true || !mounted) return;

    final config = payload.toConfig();
    final credentials = payload.toCredentials();

    // 有凭据时先做一次真实连接自检；失败允许用户选择离线保存（与配置页一致）。
    if (credentials != null) {
      try {
        if (!mounted) return;
        await runWithProgressDialog<String>(
          context,
          title: '验证配置',
          task: (update) async {
            update('正在验证 ${config.bucket} 的读写权限…');
            return CloudSyncShareService.testConfig(config, credentials);
          },
        );
      } catch (e) {
        if (!mounted) return;
        final proceed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('连接测试失败'),
            content: Text('$e\n\n仍要保存这份配置吗？保存后可以稍后重试连接。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('返回'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('仍然保存'),
              ),
            ],
          ),
        );
        if (proceed != true || !mounted) return;
      }
    }

    CloudSyncShareApplyResult result;
    try {
      result = await CloudSyncShareService.applyPayload(payload);
    } catch (e) {
      _showSnack('导入失败：$e', isError: true);
      return;
    }
    if (!mounted) return;

    final message = shareImportResultMessage(
      hasCredentials: result.credentials?.isComplete ?? false,
      backendChanged: result.backendChanged,
      credentialsCleared: result.credentialsCleared,
    );
    logInfo(
      'CloudSyncScan',
      '二维码导入完成 backendChanged=${result.backendChanged} '
          'ready=${result.isReady}',
    );

    if (!result.isReady) {
      final fillNow = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('配置已导入'),
          content: Text('$message\n\n现在补填访问密钥吗？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('稍后'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('去填写'),
            ),
          ],
        ),
      );
      if (fillNow == true && mounted) {
        await Navigator.of(context).push<bool>(
          MaterialPageRoute(builder: (context) => const CloudSyncConfigPage()),
        );
      }
      if (mounted) Navigator.of(context).pop(true);
      return;
    }

    _showSnack(message);

    // 与配置页保存后一致：本机无数据且云端有快照时询问是否立即引导。
    await maybeBootstrapFromCloud(context, showMessage: _showSnack);
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<bool?> _confirmPayload(CloudSyncSharePayload payload) {
    final config = payload.toConfig();
    final colorScheme = Theme.of(context).colorScheme;
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导入云同步配置'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '端点：${config.displayEndpoint}\n'
                '存储桶：${config.bucket}\n'
                '区域：${config.region}\n'
                '路径前缀：${config.prefix}\n'
                'path-style：${config.pathStyle ? '开启' : '关闭'}',
              ),
              if (payload.deviceName.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text('来源设备：${payload.deviceName}'),
              ],
              const SizedBox(height: 10),
              Text(
                payload.hasCredentials
                    ? '该二维码包含访问密钥，导入后本机将直接使用它同步。'
                    : '该二维码不包含访问密钥，导入后需要手动填写 Access Key / Secret Key。',
                style: TextStyle(
                  color: payload.hasCredentials
                      ? colorScheme.onSurfaceVariant
                      : colorScheme.error,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '导入会覆盖本机现有的对象存储配置与同步状态；'
                '本机学习数据不会被删除，首次同步时会再确认如何与云端合并。',
                style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('导入'),
          ),
        ],
      ),
    );
  }

  Widget _buildFallbackPanel(ColorScheme colorScheme, {required String hint}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline, size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(hint, style: Theme.of(context).textTheme.bodySmall),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final controller = _controller;

    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描二维码'),
        centerTitle: false,
        actions: [
          if (controller != null)
            IconButton(
              tooltip: '手电筒',
              icon: const Icon(Icons.flashlight_on_outlined),
              onPressed: () => controller.toggleTorch(),
            ),
        ],
      ),
      body: Column(
        children: [
          if (controller != null)
            Expanded(
              flex: 3,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileScanner(
                    controller: controller,
                    onDetect: _onDetect,
                    onDetectError: (error, _) {
                      logWarning('CloudSyncScan', '相机识别出错: $error');
                    },
                    errorBuilder: (context, error) => _buildFallbackPanel(
                      colorScheme,
                      hint: '无法使用相机：${error.errorCode.name}。'
                          '可以在下方改用图片或剪贴板导入。',
                    ),
                    overlayBuilder: (context, constraints) => Center(
                      child: Container(
                        width: 220,
                        height: 220,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.white70, width: 2),
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                    ),
                  ),
                  if (_busy)
                    const ColoredBox(
                      color: Color(0x66000000),
                      child: Center(child: CircularProgressIndicator()),
                    ),
                ],
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _buildFallbackPanel(
                colorScheme,
                hint: '当前平台没有可用的相机扫码能力。'
                    '请把其它设备分享的二维码截图保存到本机，'
                    '然后选择「从图片文件导入」，或直接复制二维码图片后点「从剪贴板导入」。',
              ),
            ),
          Expanded(
            flex: 2,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                if (controller != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      '把二维码对准取景框，识别成功后会自动弹出导入确认。',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pickImage,
                  icon: const Icon(Icons.image_outlined),
                  label: const Text('从图片文件导入'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pasteImage,
                  icon: const Icon(Icons.content_paste_outlined),
                  label: const Text('从剪贴板导入图片'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pasteText,
                  icon: const Icon(Icons.link_outlined),
                  label: const Text('粘贴分享文本'),
                ),
                const SizedBox(height: 16),
                Text(
                  '二维码由本应用的「二维码分享」页生成；'
                  '若提示「这不是 Aquamarina 的云同步二维码」，请确认扫描的是正确的码。',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
