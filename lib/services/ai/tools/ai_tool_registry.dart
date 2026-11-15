import '../../../models/ai_chat.dart';
import '../../system/log_service.dart';
import 'ai_tool.dart';

/// 工具注册表：负责把模型给出的调用分发到具体实现，并把一切异常收敛成
/// 可回灌的结果（对话循环因此永远不需要 try/catch）。
class AiToolRegistry {
  AiToolRegistry(List<AiToolDescriptor> tools)
    : _tools = List.unmodifiable(tools),
      _byName = {for (final tool in tools) tool.name: tool};

  final List<AiToolDescriptor> _tools;
  final Map<String, AiToolDescriptor> _byName;

  List<AiToolDescriptor> get all => _tools;

  Map<String, AiToolDescriptor> get byName => Map.unmodifiable(_byName);

  AiToolDescriptor? lookup(String name) => _byName[name];

  /// 构造 OpenAI `tools` 参数；[enabledNames] 为 null 表示全部启用。
  List<Map<String, dynamic>> openAiTools({Set<String>? enabledNames}) {
    return _tools
        .where((tool) => enabledNames == null || enabledNames.contains(tool.name))
        .map((tool) => tool.toOpenAiTool())
        .toList();
  }

  /// 执行一次工具调用。**永不抛出**：未知工具、参数非法、实现异常都以
  /// [AiToolResult.failure] 返回，供上层原样回灌给模型自纠。
  Future<AiToolResult> execute(AiToolCall call) async {
    final tool = _byName[call.name];
    if (tool == null) {
      final available = _tools.map((t) => t.name).join(', ');
      return AiToolResult.failure(
        'unknown_tool',
        '工具 "${call.name}" 不存在。可用工具：$available',
      );
    }

    if (call.parseError) {
      return AiToolResult.failure(
        'invalid_arguments',
        '工具 "${call.name}" 的参数不是合法 JSON：${call.rawArguments}',
      );
    }

    try {
      return await tool.execute(call.arguments);
    } on AiToolArgumentException catch (e) {
      return AiToolResult.failure(
        'invalid_arguments',
        '工具 "${call.name}" 参数有误：${e.message}',
      );
    } catch (e, stackTrace) {
      logError('AiToolRegistry', '工具 ${call.name} 执行失败: $e', stackTrace);
      return AiToolResult.failure(
        'tool_error',
        '工具 "${call.name}" 执行失败：${e.toString()}',
      );
    }
  }
}
