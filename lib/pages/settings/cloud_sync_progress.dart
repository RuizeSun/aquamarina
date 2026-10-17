import 'package:flutter/material.dart';

/// 在模态进度对话框中执行异步任务。
///
/// [task] 通过回调更新进度文案；异常会原样抛出，由调用方决定如何提示。
Future<T> runWithProgressDialog<T>(
  BuildContext context, {
  required String title,
  required Future<T> Function(void Function(String message) update) task,
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
        ),
      );
    },
  );

  try {
    return await task((value) {
      if (!dialogVisible) return;
      message.value = value;
    });
  } finally {
    dialogVisible = false;
    message.dispose();
    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }
  }
}
