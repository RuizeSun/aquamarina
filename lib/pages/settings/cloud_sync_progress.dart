import 'package:flutter/material.dart';

import '../../models/cloud_sync_manifest.dart';

/// 进度弹窗的取消令牌。
///
/// UI 只负责置位；具体任务在安全边界检查 [isCancelled] 并尽快退出。
class ProgressCancelToken {
  bool _cancelled = false;

  bool get isCancelled => _cancelled;

  void cancel() => _cancelled = true;
}

/// 在模态进度对话框中执行异步任务。
///
/// [task] 通过回调更新进度文案；异常会原样抛出，由调用方决定如何提示。
/// 传入 [cancelToken] 时显示「取消」按钮；任务主动抛
/// [CloudSyncCancelledException] 或取消后正常返回都会让本函数返回 null。
Future<T?> runWithProgressDialog<T>(
  BuildContext context, {
  required String title,
  required Future<T> Function(void Function(String message) update) task,
  ProgressCancelToken? cancelToken,
}) async {
  final message = ValueNotifier<String>('准备中…');
  var dialogVisible = true;

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      return PopScope(
        canPop: false,
        child: AlertDialog(
          title: Text(title),
          content: Row(
            children: [
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ValueListenableBuilder<String>(
                  valueListenable: message,
                  builder: (context, value, _) => Text(value),
                ),
              ),
            ],
          ),
          actions: [
            if (cancelToken != null)
              TextButton(
                onPressed: () {
                  cancelToken.cancel();
                  message.value = '正在取消…';
                },
                child: const Text('取消'),
              ),
          ],
        ),
      );
    },
  );

  try {
    final result = await task((value) {
      if (!dialogVisible) return;
      message.value = value;
    });
    if (cancelToken?.isCancelled ?? false) return null;
    return result;
  } on CloudSyncCancelledException {
    return null;
  } finally {
    dialogVisible = false;
    message.dispose();
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
}
