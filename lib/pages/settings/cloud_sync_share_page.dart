import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/cloud_sync_manifest.dart';
import '../../models/cloud_sync_share_payload.dart';
import '../../services/cloud/cloud_sync_share_service.dart';
import '../../services/system/log_service.dart';
import 'cloud_sync_scan_page.dart';

/// 二维码渲染组件。
///
/// 单独抽出的原因：`QrImageView` 把 data 存成私有字段，组件测试无法直接断言
/// 二维码里到底编码了什么（是否真的不含密钥）。这里把 [data] 暴露成公开字段，
/// 让测试可以解码校验，同时保持渲染逻辑只有一处。
class CloudSyncQrCode extends StatelessWidget {
  final String data;
  final double size;

  const CloudSyncQrCode({super.key, required this.data, this.size = 240});

  @override
  Widget build(BuildContext context) {
    return QrImageView(
      data: data,
      version: QrVersions.auto,
      errorCorrectionLevel: QrErrorCorrectLevel.M,
      size: size,
      backgroundColor: Colors.white,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Colors.black,
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Colors.black,
      ),
      errorStateBuilder: (context, error) => SizedBox(
        width: size,
        height: size,
        child: const Center(child: Text('二维码生成失败')),
      ),
    );
  }
}

/// 对象存储配置的二维码分享页。
///
/// 默认把 Access Key / Secret Key 一并编码进二维码，扫码设备可以做到
/// 「扫完即可同步」；也可以关闭开关，只分享非敏感配置。
/// 页面顶部始终提示：二维码等同于账号密码，截屏与转发都会泄露存储桶权限。
class CloudSyncQrSharePage extends StatefulWidget {
  const CloudSyncQrSharePage({super.key});

  @override
  State<CloudSyncQrSharePage> createState() => _CloudSyncQrSharePageState();
}

class _CloudSyncQrSharePageState extends State<CloudSyncQrSharePage> {
  bool _includeCredentials = true;
  bool _loading = true;
  bool _exporting = false;
  CloudSyncSharePayload? _payload;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    CloudSyncSharePayload? payload;
    String? error;
    try {
      payload = await CloudSyncShareService.loadCurrent(
        includeCredentials: _includeCredentials,
      );
    } catch (e) {
      error = e is CloudSyncException ? e.message : '$e';
    }
    if (!mounted) return;
    setState(() {
      _payload = payload;
      _error = error;
      _loading = false;
    });
  }

  Future<void> _setIncludeCredentials(bool value) async {
    if (_includeCredentials == value) return;
    setState(() {
      _includeCredentials = value;
      _loading = true;
    });
    await _load();
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

  Future<void> _copyPayload() async {
    final payload = _payload;
    if (payload == null) return;
    await Clipboard.setData(ClipboardData(text: payload.encode()));
    logInfo('CloudSyncShare', '已复制二维码分享文本 containsSecrets=${payload.hasCredentials}');
    _showSnack(
      payload.hasCredentials
          ? '已复制分享文本；其中包含访问密钥，请及时清空剪贴板'
          : '已复制分享文本',
    );
  }

  /// 把二维码画成 PNG 后交给系统分享面板 / 保存对话框。
  Future<void> _exportImage() async {
    final payload = _payload;
    if (payload == null || _exporting) return;
    setState(() => _exporting = true);
    File? temp;
    try {
      final painter = QrPainter(
        data: payload.encode(),
        version: QrVersions.auto,
        errorCorrectionLevel: QrErrorCorrectLevel.M,
        gapless: true,
      );
      final image = await painter.toImage(1024);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) {
        throw const CloudSyncException('二维码渲染失败，请重试');
      }
      final dir = await getTemporaryDirectory();
      final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
      temp = File(p.join(dir.path, 'aquamarina_cloud_sync_$stamp.png'));
      await temp.writeAsBytes(byteData.buffer.asUint8List(), flush: true);
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(temp.path)],
          subject: 'Aquamarina 云同步配置',
        ),
      );
      logInfo('CloudSyncShare', '已导出二维码图片 containsSecrets=${payload.hasCredentials}');
    } catch (e) {
      _showSnack('导出失败：$e', isError: true);
    } finally {
      // 分享完成后立刻删除临时文件，避免含密钥的二维码长期留在磁盘上。
      try {
        if (temp != null && await temp.exists()) {
          await temp.delete();
        }
      } catch (_) {}
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _openScan() async {
    final imported = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (context) => const CloudSyncQrScanPage()),
    );
    if (imported == true && mounted) {
      await _load();
    }
  }

  Widget _warningCard(ColorScheme colorScheme) {
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
              Icon(Icons.share_outlined, size: 18, color: colorScheme.primary),
              const SizedBox(width: 8),
              Text('二维码等同于账号密码', style: Theme.of(context).textTheme.labelLarge),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '开启「包含访问密钥」时，任何扫描到这张二维码的人都能读写该存储桶下'
            '此前缀里的所有对象。请勿截图外发、不要贴在公开渠道；'
            '一旦可疑泄露，请立即到对象存储控制台更换 Access Key / Secret Key。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ColorScheme colorScheme) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: colorScheme.error),
          ),
        ),
      );
    }
    final payload = _payload;
    if (payload == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off_outlined, size: 48, color: colorScheme.outline),
              const SizedBox(height: 12),
              const Text('请先完成对象存储配置', textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(
                '配置完成后即可生成分享二维码，让其它设备扫码自动完成配置。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _warningCard(colorScheme),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('包含 Access Key / Secret Key'),
          subtitle: Text(
            _includeCredentials
                ? '扫码设备无需再输入密钥，导入后即可直接同步'
                : '只分享端点、存储桶等非敏感配置，扫码设备需要自行补填密钥',
          ),
          value: _includeCredentials,
          onChanged: _loading ? null : _setIncludeCredentials,
        ),
        const SizedBox(height: 8),
        Center(
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
            ),
            child: CloudSyncQrCode(data: payload.encode()),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            payload.maskedSummary,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: _loading ? null : _copyPayload,
          icon: const Icon(Icons.copy_outlined),
          label: const Text('复制分享文本'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _loading || _exporting ? null : _exportImage,
          icon: _exporting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.save_alt_outlined),
          label: Text(_exporting ? '正在导出…' : '保存二维码图片'),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _openScan,
          icon: const Icon(Icons.qr_code_scanner),
          label: const Text('扫描其它设备的二维码'),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('二维码分享'), centerTitle: false),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(Theme.of(context).colorScheme),
    );
  }
}
