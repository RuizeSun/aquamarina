import '../../../models/ai_chat.dart';
import 'ai_tool.dart';

/// 用户对一次工具调用的批准结果。
enum AiToolApprovalDecision {
  /// 仅本次允许执行。
  approved,

  /// 拒绝执行（结果以 denied_by_user 回灌模型）。
  denied,

  /// 本会话内不再询问此工具（仅内存缓存，不落库）。
  alwaysAllowedInSession,
}

/// 批准回调：由页面注入（弹出批准面板）。返回 null 表示页面已销毁。
typedef AiToolApprovalHandler =
    Future<AiToolApprovalDecision> Function(
      AiToolCall call,
      AiToolDescriptor tool,
    );

/// 把批准结果与工具风险合并成「是否执行」的判定。
///
/// 规则：
/// - 只读工具且用户开启「自动批准只读工具」→ 直接执行，不打扰用户；
/// - 其余情况（所有写工具、被关闭自动批准的只读工具）→ 必须询问；
/// - 本会话已勾选「总是允许」的工具 → 直接执行。
class AiToolApprovalPolicy {
  AiToolApprovalPolicy({
    required this.autoApproveReadOnly,
    this.handler,
    Set<String>? alwaysAllowed,
  }) : _alwaysAllowed = {...?alwaysAllowed};

  final bool autoApproveReadOnly;
  final AiToolApprovalHandler? handler;
  final Set<String> _alwaysAllowed;

  /// 本会话已永久放行的工具名（供 UI 展示）。
  Set<String> get alwaysAllowedTools => Set.unmodifiable(_alwaysAllowed);

  /// 判断是否需要弹窗询问。
  bool needsPrompt(AiToolDescriptor tool) {
    if (_alwaysAllowed.contains(tool.name)) return false;
    if (tool.risk == AiToolRisk.readOnly && autoApproveReadOnly) return false;
    return true;
  }

  /// 取得执行授权；无 handler（页面已销毁）时一律拒绝。
  Future<bool> ensureApproved(AiToolCall call, AiToolDescriptor tool) async {
    if (_alwaysAllowed.contains(tool.name)) return true;
    if (tool.risk == AiToolRisk.readOnly && autoApproveReadOnly) return true;

    final callback = handler;
    if (callback == null) return false;

    final decision = await callback(call, tool);
    switch (decision) {
      case AiToolApprovalDecision.approved:
        return true;
      case AiToolApprovalDecision.alwaysAllowedInSession:
        _alwaysAllowed.add(tool.name);
        return true;
      case AiToolApprovalDecision.denied:
        return false;
    }
  }
}
