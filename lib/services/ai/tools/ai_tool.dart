/// 工具的风险等级。
///
/// [readOnly] 只读取本地数据，可在用户开启「自动批准只读工具」时直接执行；
/// [mutating] 会修改用户数据，**必须**每次由用户显式批准。
enum AiToolRisk { readOnly, mutating }

/// 一次工具执行结果。
///
/// [content] 是回灌给模型的文本（模型据此继续推理），[data] 供 UI / 调试查看，
/// [errorCode] 非空表示失败（unknown_tool / invalid_arguments / tool_error 等）。
class AiToolResult {
  final bool ok;
  final String content;
  final Map<String, dynamic>? data;
  final String? errorCode;

  const AiToolResult({
    required this.ok,
    required this.content,
    this.data,
    this.errorCode,
  });

  factory AiToolResult.success(String content, {Map<String, dynamic>? data}) =>
      AiToolResult(ok: true, content: content, data: data);

  factory AiToolResult.failure(String errorCode, String content) =>
      AiToolResult(ok: false, content: content, errorCode: errorCode);

  Map<String, dynamic> toJson() => {
    'ok': ok,
    'content': content,
    if (errorCode != null) 'error_code': errorCode,
    if (data != null) 'data': data,
  };
}

/// 一个可供模型调用的 App 内工具。
class AiToolDescriptor {
  /// 工具名（OpenAI function name 约定：字母/数字/下划线，≤64 字符）。
  final String name;

  /// 给模型看的说明：做什么、参数含义、返回什么。
  final String description;

  final AiToolRisk risk;

  /// JSON Schema 形式的参数定义。
  final Map<String, dynamic> parameters;

  /// 执行函数；参数已由注册表解析。抛出的异常会被注册表兜底成 tool_error。
  final Future<AiToolResult> Function(Map<String, dynamic> args) execute;

  const AiToolDescriptor({
    required this.name,
    required this.description,
    required this.risk,
    required this.parameters,
    required this.execute,
  });

  bool get isMutating => risk == AiToolRisk.mutating;

  /// 转换为 OpenAI tools 数组中的一项。
  Map<String, dynamic> toOpenAiTool() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

/// 参数校验失败时抛出，由注册表转成 invalid_arguments 回灌模型。
class AiToolArgumentException implements Exception {
  final String message;
  const AiToolArgumentException(this.message);

  @override
  String toString() => message;
}

/// 参数读取辅助：统一做类型与范围校验，错误信息对模型友好。
class AiToolArgs {
  final Map<String, dynamic> _raw;

  const AiToolArgs(this._raw);

  /// 必填字符串。
  String requireString(String key, {int maxLength = 200}) {
    final value = _raw[key];
    if (value is! String || value.trim().isEmpty) {
      throw AiToolArgumentException('参数 "$key" 必须是非空字符串');
    }
    final trimmed = value.trim();
    if (trimmed.length > maxLength) {
      return trimmed.substring(0, maxLength);
    }
    return trimmed;
  }

  /// 可选字符串。
  String? optionalString(String key, {int maxLength = 2000}) {
    final value = _raw[key];
    if (value == null) return null;
    if (value is! String) {
      throw AiToolArgumentException('参数 "$key" 必须是字符串');
    }
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return trimmed.length > maxLength ? trimmed.substring(0, maxLength) : trimmed;
  }

  /// 必填整数。
  int requireInt(String key, {int? min, int? max}) {
    final value = _raw[key];
    int? parsed;
    if (value is int) {
      parsed = value;
    } else if (value is num) {
      parsed = value.toInt();
    } else if (value is String) {
      parsed = int.tryParse(value.trim());
    }
    if (parsed == null) {
      throw AiToolArgumentException('参数 "$key" 必须是整数');
    }
    if (min != null && parsed < min) {
      throw AiToolArgumentException('参数 "$key" 不能小于 $min');
    }
    if (max != null && parsed > max) {
      parsed = max;
    }
    return parsed;
  }

  /// 可选整数（带默认值）。
  int optionalInt(String key, {required int fallback, int? min, int? max}) {
    if (!_raw.containsKey(key) || _raw[key] == null) return fallback;
    return requireInt(key, min: min, max: max);
  }

  /// 可选布尔。
  bool requireBool(String key) {
    final value = _raw[key];
    if (value is bool) return value;
    if (value is String) {
      if (value == 'true') return true;
      if (value == 'false') return false;
    }
    throw AiToolArgumentException('参数 "$key" 必须是布尔值');
  }

  /// 必填字符串数组。
  List<String> requireStringList(String key, {int maxItems = 200}) {
    final value = _raw[key];
    if (value is! List) {
      throw AiToolArgumentException('参数 "$key" 必须是字符串数组');
    }
    final result = <String>[];
    for (final item in value) {
      if (item is! String || item.trim().isEmpty) {
        throw AiToolArgumentException('参数 "$key" 中每一项都必须是非空字符串');
      }
      result.add(item.trim());
      if (result.length >= maxItems) break;
    }
    if (result.isEmpty) {
      throw AiToolArgumentException('参数 "$key" 不能为空数组');
    }
    return result;
  }
}
