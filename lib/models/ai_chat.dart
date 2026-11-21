import 'dart:convert';

import 'package:uuid/uuid.dart';

/// 对话消息角色。
enum AiChatRole {
  system,
  user,
  assistant,
  tool;

  static AiChatRole fromName(String? name) => values.firstWhere(
    (e) => e.name == name,
    orElse: () => AiChatRole.assistant,
  );
}

/// 消息完成状态。
///
/// 流式期间消息只存在于内存，结束时才落库，因此 [pending] 只用于运行期；
/// 落库的消息通常是 [complete] / [error] / [cancelled]。
enum AiChatMessageStatus {
  pending,
  complete,
  error,
  cancelled;

  static AiChatMessageStatus fromName(String? name) => values.firstWhere(
    (e) => e.name == name,
    orElse: () => AiChatMessageStatus.complete,
  );
}

/// 一次模型发起的工具调用。
///
/// [rawArguments] 是模型给出的原始 JSON 字符串，回灌时必须原样使用（OpenAI 协议
/// 要求 arguments 为字符串）；[arguments] 是解析结果，解析失败时为空 Map 且
/// [parseError] 为 true。
class AiToolCall {
  final String id;
  final String name;
  final String rawArguments;
  final Map<String, dynamic> arguments;
  final bool parseError;

  const AiToolCall({
    required this.id,
    required this.name,
    required this.rawArguments,
    required this.arguments,
    this.parseError = false,
  });

  factory AiToolCall.parse({
    required String id,
    required String name,
    required String rawArguments,
  }) {
    Map<String, dynamic> parsed = const {};
    var failed = false;
    final trimmed = rawArguments.trim();
    if (trimmed.isNotEmpty) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map<String, dynamic>) {
          parsed = decoded;
        } else if (decoded is Map) {
          parsed = decoded.map((k, v) => MapEntry(k.toString(), v));
        } else {
          failed = true;
        }
      } catch (_) {
        failed = true;
      }
    }
    return AiToolCall(
      id: id,
      name: name,
      rawArguments: rawArguments,
      arguments: parsed,
      parseError: failed,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'arguments': rawArguments,
    if (parseError) 'parse_error': true,
  };

  factory AiToolCall.fromJson(Map<String, dynamic> json) {
    final raw = json['arguments'];
    return AiToolCall.parse(
      id: (json['id'] ?? '').toString(),
      name: (json['name'] ?? '').toString(),
      rawArguments: raw is String ? raw : jsonEncode(raw),
    );
  }

  /// OpenAI 协议中的 tool_call 对象。
  Map<String, dynamic> toOpenAi() => {
    'id': id,
    'type': 'function',
    'function': {'name': name, 'arguments': rawArguments},
  };
}

/// 一条消息对应的 token 用量与费用快照。
///
/// assistant 消息记录的是**该轮请求**的真实用量（来自服务端 `usage`）；
/// 没有真实用量的消息（用户提问、历史数据）由 UI 退回按字符估算。
/// 该数据只用于展示与导出，**绝不进入请求体**。
class AiMessageUsage {
  final int promptTokens;
  final int cacheHitTokens;
  final int cacheMissTokens;
  final int completionTokens;
  final int totalTokens;

  /// 该轮请求的费用；配置未启用计费时为 null。
  final double? cost;
  final String currencySymbol;
  final int currencyDecimals;
  final bool currencyGrouping;

  const AiMessageUsage({
    required this.promptTokens,
    this.cacheHitTokens = 0,
    this.cacheMissTokens = 0,
    required this.completionTokens,
    required this.totalTokens,
    this.cost,
    this.currencySymbol = '¥',
    this.currencyDecimals = 2,
    this.currencyGrouping = true,
  });

  /// 是否没有任何有效数字（全 0 时不必展示角标）。
  bool get isEmpty =>
      promptTokens == 0 && completionTokens == 0 && totalTokens == 0;

  /// 合并多轮请求的用量。
  ///
  /// 一次提问可能触发「工具调用 → 继续生成」多轮，界面上仍是一个回答气泡，
  /// 因此角标按轮次求和；费用只有全部轮次都可计价时才给出总额。
  static AiMessageUsage combine(Iterable<AiMessageUsage> parts) {
    var prompt = 0;
    var hit = 0;
    var miss = 0;
    var completion = 0;
    var total = 0;
    double? cost;
    var costKnown = true;
    var symbol = '¥';
    var decimals = 2;
    var grouping = true;
    for (final part in parts) {
      prompt += part.promptTokens;
      hit += part.cacheHitTokens;
      miss += part.cacheMissTokens;
      completion += part.completionTokens;
      total += part.totalTokens;
      final partCost = part.cost;
      if (partCost == null) {
        // 任一轮不可计价就不再给总额，避免把「部分费用」当成完整费用展示。
        costKnown = false;
      } else {
        cost = (cost ?? 0) + partCost;
      }
      symbol = part.currencySymbol;
      decimals = part.currencyDecimals;
      grouping = part.currencyGrouping;
    }
    return AiMessageUsage(
      promptTokens: prompt,
      cacheHitTokens: hit,
      cacheMissTokens: miss,
      completionTokens: completion,
      totalTokens: total,
      cost: costKnown ? cost : null,
      currencySymbol: symbol,
      currencyDecimals: decimals,
      currencyGrouping: grouping,
    );
  }

  Map<String, dynamic> toJson() => {
    'prompt_tokens': promptTokens,
    'cache_hit_tokens': cacheHitTokens,
    'cache_miss_tokens': cacheMissTokens,
    'completion_tokens': completionTokens,
    'total_tokens': totalTokens,
    'cost': cost,
    'currency_symbol': currencySymbol,
    'currency_decimals': currencyDecimals,
    'currency_grouping': currencyGrouping ? 1 : 0,
  };

  factory AiMessageUsage.fromJson(Map<String, dynamic> json) {
    int asInt(Object? value) => (value as num?)?.toInt() ?? 0;
    return AiMessageUsage(
      promptTokens: asInt(json['prompt_tokens']),
      cacheHitTokens: asInt(json['cache_hit_tokens']),
      cacheMissTokens: asInt(json['cache_miss_tokens']),
      completionTokens: asInt(json['completion_tokens']),
      totalTokens: asInt(json['total_tokens']),
      cost: (json['cost'] as num?)?.toDouble(),
      currencySymbol: (json['currency_symbol'] as String?) ?? '¥',
      currencyDecimals: asInt(json['currency_decimals']) == 0
          ? 2
          : asInt(json['currency_decimals']),
      currencyGrouping: asInt(json['currency_grouping']) != 0,
    );
  }

  /// 解析落库的 JSON 文本；为 null / 损坏 / 全 0 时返回 null。
  static AiMessageUsage? tryDecode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final usage = AiMessageUsage.fromJson(
        decoded.map((k, v) => MapEntry(k.toString(), v)),
      );
      return usage.isEmpty ? null : usage;
    } catch (_) {
      return null;
    }
  }
}

/// 消息中的一张图片附件。
///
/// 原图不入库、不入同步：数据库只保存元数据（尺寸、原始文件名）与
/// **缩略图**（PNG，边长 16 或 32，base64 存储），用于跨设备展示与占位。
/// 送给模型时再按设置决定发原图还是缩略图。
class AiChatAttachment {
  /// 同步用的缩略图边长（像素）。取值只有 16 / 32。
  static const int thumbSizeSmall = 16;
  static const int thumbSizeLarge = 32;

  /// 原图过大时直接拒绝（避免一次性加载数千万像素的图片）。
  static const int maxSourceBytes = 12 * 1024 * 1024;

  final String id;

  /// 原图在本机的绝对路径；跨设备同步后为 null（没有原图）。
  final String? localPath;

  /// 原图文件名（展示用）。
  final String fileName;

  final int width;
  final int height;

  /// 缩略图（base64 PNG），参与云同步。
  final String thumbnailBase64;

  /// 缩略图边长（16 或 32）。
  final int thumbnailSize;

  /// 发给模型的 data URL（原图或缩略图）；为 null 表示本次不发送图片。
  /// 仅运行期使用，不落库。
  final String? dataUrl;

  /// OpenAI 的图片精度提示（low / high / auto）。
  final String? detail;

  /// 实际发送出去的图片像素尺寸（诊断用，不落库、不进请求体）。
  final int sentWidth;
  final int sentHeight;

  const AiChatAttachment({
    required this.id,
    required this.localPath,
    required this.fileName,
    required this.width,
    required this.height,
    required this.thumbnailBase64,
    required this.thumbnailSize,
    this.dataUrl,
    this.detail,
    this.sentWidth = 0,
    this.sentHeight = 0,
  });

  bool get hasLocalFile => localPath != null && localPath!.isNotEmpty;

  bool get isRemoteOnly => !hasLocalFile;

  Map<String, dynamic> toJson() => {
    'id': id,
    if (localPath != null) 'local_path': localPath,
    'file_name': fileName,
    'width': width,
    'height': height,
    'thumbnail': thumbnailBase64,
    'thumbnail_size': thumbnailSize,
  };

  factory AiChatAttachment.fromJson(Map<String, dynamic> json) {
    final size = (json['thumbnail_size'] as num?)?.toInt() ?? thumbSizeLarge;
    return AiChatAttachment(
      id: (json['id'] ?? '').toString(),
      localPath: json['local_path'] as String?,
      fileName: (json['file_name'] ?? 'image').toString(),
      width: (json['width'] as num?)?.toInt() ?? 0,
      height: (json['height'] as num?)?.toInt() ?? 0,
      thumbnailBase64: (json['thumbnail'] ?? '').toString(),
      thumbnailSize: size == thumbSizeSmall ? thumbSizeSmall : thumbSizeLarge,
    );
  }

  AiChatAttachment copyWith({
    String? localPath,
    bool clearLocalPath = false,
    String? dataUrl,
    String? detail,
    int? sentWidth,
    int? sentHeight,
  }) {
    return AiChatAttachment(
      id: id,
      localPath: clearLocalPath ? null : (localPath ?? this.localPath),
      fileName: fileName,
      width: width,
      height: height,
      thumbnailBase64: thumbnailBase64,
      thumbnailSize: thumbnailSize,
      dataUrl: dataUrl ?? this.dataUrl,
      detail: detail ?? this.detail,
      sentWidth: sentWidth ?? this.sentWidth,
      sentHeight: sentHeight ?? this.sentHeight,
    );
  }
}

/// 一条对话消息（落库实体 + 运行期载体）。
class AiChatMessage {
  /// 单条消息入库上限：防止超长回复把单条 oplog 记录撑得过大。
  static const int maxStoredChars = 32 * 1024;

  static const String _truncatedSuffix = '\n\n…（内容过长，已截断）';

  final String id;
  final String sessionId;
  final AiChatRole role;
  final String content;

  /// DeepSeek 思考模式的思维链，仅 assistant 消息可能有。
  final String? reasoning;

  /// assistant 消息发起的工具调用。
  final List<AiToolCall> toolCalls;

  /// tool 消息对应的调用 ID / 工具名。
  final String? toolCallId;
  final String? toolName;

  final AiChatMessageStatus status;
  final String? errorMessage;
  final DateTime createdAt;
  final double sortIndex;

  /// 用户随消息发送的图片（仅 user 消息使用）。
  final List<AiChatAttachment> attachments;

  /// 该条 assistant 消息对应请求的用量与费用角标（仅 assistant 消息会有）。
  ///
  /// 不参与请求体构造，只用于界面展示与导出。
  final AiMessageUsage? usage;

  const AiChatMessage({
    required this.id,
    required this.sessionId,
    required this.role,
    this.content = '',
    this.reasoning,
    this.toolCalls = const [],
    this.toolCallId,
    this.toolName,
    this.status = AiChatMessageStatus.complete,
    this.errorMessage,
    required this.createdAt,
    this.sortIndex = 0,
    this.attachments = const [],
    this.usage,
  });

  bool get hasAttachments => attachments.isNotEmpty;

  /// 新建一条待落库的消息（id / 时间由模型层生成）。
  factory AiChatMessage.create({
    required String sessionId,
    required AiChatRole role,
    String content = '',
    String? reasoning,
    List<AiToolCall> toolCalls = const [],
    String? toolCallId,
    String? toolName,
    AiChatMessageStatus status = AiChatMessageStatus.complete,
    String? errorMessage,
    DateTime? createdAt,
    double sortIndex = 0,
    String? id,
    List<AiChatAttachment> attachments = const [],
    AiMessageUsage? usage,
  }) {
    return AiChatMessage(
      id: id ?? const Uuid().v4(),
      sessionId: sessionId,
      role: role,
      content: content,
      reasoning: reasoning,
      toolCalls: toolCalls,
      toolCallId: toolCallId,
      toolName: toolName,
      status: status,
      errorMessage: errorMessage,
      attachments: attachments,
      usage: usage,
      createdAt: createdAt ?? DateTime.now(),
      sortIndex: sortIndex,
    );
  }

  bool get hasToolCalls => toolCalls.isNotEmpty;

  bool get isPending => status == AiChatMessageStatus.pending;

  AiChatMessage copyWith({
    String? id,
    String? sessionId,
    AiChatRole? role,
    String? content,
    String? reasoning,
    List<AiToolCall>? toolCalls,
    String? toolCallId,
    String? toolName,
    AiChatMessageStatus? status,
    String? errorMessage,
    double? sortIndex,
    List<AiChatAttachment>? attachments,
    AiMessageUsage? usage,
    bool clearReasoning = false,
    bool clearErrorMessage = false,
  }) {
    return AiChatMessage(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      role: role ?? this.role,
      content: content ?? this.content,
      reasoning: clearReasoning ? null : (reasoning ?? this.reasoning),
      toolCalls: toolCalls ?? this.toolCalls,
      toolCallId: toolCallId ?? this.toolCallId,
      toolName: toolName ?? this.toolName,
      status: status ?? this.status,
      errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
      createdAt: createdAt,
      sortIndex: sortIndex ?? this.sortIndex,
      attachments: attachments ?? this.attachments,
      usage: usage ?? this.usage,
    );
  }

  /// 把超长文本截断到 [maxStoredChars]，避免单条记录过大。
  static String truncateForStorage(String text) {
    if (text.length <= maxStoredChars) return text;
    final keep = maxStoredChars - _truncatedSuffix.length;
    if (keep <= 0) return text.substring(0, maxStoredChars);
    return text.substring(0, keep) + _truncatedSuffix;
  }

  Map<String, Object?> toRow() => {
    'id': id,
    'session_id': sessionId,
    'role': role.name,
    'content': truncateForStorage(content),
    'reasoning': reasoning == null ? null : truncateForStorage(reasoning!),
    'tool_calls': toolCalls.isEmpty
        ? null
        : jsonEncode(toolCalls.map((c) => c.toJson()).toList()),
    'tool_call_id': toolCallId,
    'tool_name': toolName,
    'status': status.name,
    'error_message': errorMessage,
    'attachments': attachments.isEmpty
        ? null
        : jsonEncode(attachments.map((a) => a.toJson()).toList()),
    'usage': usage == null ? null : jsonEncode(usage!.toJson()),
    'created_at': createdAt.toIso8601String(),
    'sort_index': sortIndex,
  };

  factory AiChatMessage.fromRow(Map<String, Object?> row) {
    final rawCalls = row['tool_calls'];
    final calls = <AiToolCall>[];
    if (rawCalls is String && rawCalls.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawCalls);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              calls.add(
                AiToolCall.fromJson(item.map((k, v) => MapEntry(k.toString(), v))),
              );
            }
          }
        }
      } catch (_) {
        // 解析失败时丢弃工具调用明细，正文仍然可用
      }
    }

    final rawAttachments = row['attachments'];
    final attachments = <AiChatAttachment>[];
    if (rawAttachments is String && rawAttachments.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawAttachments);
        if (decoded is List) {
          for (final item in decoded) {
            if (item is Map) {
              attachments.add(
                AiChatAttachment.fromJson(
                  item.map((k, v) => MapEntry(k.toString(), v)),
                ),
              );
            }
          }
        }
      } catch (_) {
        // 解析失败时丢弃附件元数据，正文仍然可用
      }
    }

    final createdAtRaw = row['created_at'];
    return AiChatMessage(
      id: (row['id'] ?? '').toString(),
      sessionId: (row['session_id'] ?? '').toString(),
      role: AiChatRole.fromName(row['role'] as String?),
      content: (row['content'] as String?) ?? '',
      reasoning: row['reasoning'] as String?,
      toolCalls: calls,
      toolCallId: row['tool_call_id'] as String?,
      toolName: row['tool_name'] as String?,
      status: AiChatMessageStatus.fromName(row['status'] as String?),
      errorMessage: row['error_message'] as String?,
      attachments: attachments,
      usage: AiMessageUsage.tryDecode(row['usage'] as String?),
      createdAt: createdAtRaw is String
          ? (DateTime.tryParse(createdAtRaw) ?? DateTime.now())
          : DateTime.now(),
      sortIndex: (row['sort_index'] as num?)?.toDouble() ?? 0,
    );
  }

  /// 构造一个 image_url 分段。
  ///
  /// 附带的 `image_size` 只用于本地诊断日志，发送前会被 [stripDiagnostics] 移除，
  /// 不会污染请求体。
  static Map<String, dynamic> _imagePart(AiChatAttachment attachment) {
    return {
      'type': 'image_url',
      'image_url': {
        'url': attachment.dataUrl,
        if (attachment.detail != null) 'detail': attachment.detail,
      },
      'image_size': {'w': attachment.sentWidth, 'h': attachment.sentHeight},
    };
  }

  /// 移除仅用于本地诊断的字段。
  static Map<String, dynamic> stripDiagnostics(Map<String, dynamic> message) {
    final cleanedMessage = {
      for (final e in message.entries)
        if (e.key != '_message_id' && e.key != 'image_size') e.key: e.value,
    };
    final content = cleanedMessage['content'];
    if (content is! List) return cleanedMessage;
    final cleaned = <Map<String, dynamic>>[];
    for (final part in content) {
      if (part is! Map<String, dynamic>) continue;
      cleaned.add({for (final e in part.entries) if (e.key != 'image_size') e.key: e.value});
    }
    return {...cleanedMessage, 'content': cleaned};
  }

  /// 转为 OpenAI Chat Completions 的 message 对象。
  Map<String, dynamic> toOpenAiMessage() {
    switch (role) {
      case AiChatRole.tool:
        return {
          'role': 'tool',
          'tool_call_id': toolCallId ?? '',
          'content': content,
        };
      case AiChatRole.assistant:
        // DeepSeek 思考模式 + tools 时必须回传历史轮次的 reasoning_content，
        // 否则 API 返回 400。是否真正发送由 AiService.buildChatBody 决定，
        // 这里只负责把思维链带出模型层（其它厂商会在发送前被剔除）。
        final reasoningContent = (reasoning == null || reasoning!.isEmpty)
            ? null
            : reasoning;
        if (toolCalls.isEmpty) {
          return {
            'role': 'assistant',
            'content': content,
            'reasoning_content': ?reasoningContent,
          };
        }
        return {
          'role': 'assistant',
          // 官方样例在工具调用轮次里回传的是空串而不是 null：部分网关会
          // 对 null content 直接报 400，空串则两边都能接受。
          'content': content,
          'tool_calls': toolCalls.map((c) => c.toOpenAi()).toList(),
          'reasoning_content': ?reasoningContent,
        };
      case AiChatRole.system:
        return {'role': 'system', 'content': content};
      case AiChatRole.user:
        if (attachments.isEmpty) {
          return {'role': 'user', 'content': content, '_message_id': id};
        }
        // 多模态：content 改为分段数组，文本段始终存在（OpenAI 允许空串）
        return {
          'role': 'user',
          '_message_id': id,
          'content': [
            if (content.isNotEmpty) {'type': 'text', 'text': content},
            for (final attachment in attachments)
              if (attachment.dataUrl != null && attachment.dataUrl!.isNotEmpty)
                _imagePart(attachment),
          ],
        };
    }
  }
}

/// 一个对话会话。
class AiChatSession {
  static const String defaultTitle = '新对话';

  final String id;
  final String title;
  final String? profileId;
  final DateTime createdAt;
  final DateTime updatedAt;

  const AiChatSession({
    required this.id,
    required this.title,
    this.profileId,
    required this.createdAt,
    required this.updatedAt,
  });

  factory AiChatSession.create({String? title, String? profileId, String? id}) {
    final now = DateTime.now();
    return AiChatSession(
      id: id ?? const Uuid().v4(),
      title: (title == null || title.trim().isEmpty) ? defaultTitle : title.trim(),
      profileId: profileId,
      createdAt: now,
      updatedAt: now,
    );
  }

  AiChatSession copyWith({
    String? title,
    String? profileId,
    DateTime? updatedAt,
    bool clearProfileId = false,
  }) {
    return AiChatSession(
      id: id,
      title: title ?? this.title,
      profileId: clearProfileId ? null : (profileId ?? this.profileId),
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, Object?> toRow() => {
    'id': id,
    'title': title,
    'profile_id': profileId,
    'created_at': createdAt.toIso8601String(),
    'updated_at': updatedAt.toIso8601String(),
  };

  factory AiChatSession.fromRow(Map<String, Object?> row) {
    final created = row['created_at'];
    final updated = row['updated_at'];
    return AiChatSession(
      id: (row['id'] ?? '').toString(),
      title: (row['title'] as String?)?.trim().isNotEmpty == true
          ? (row['title'] as String).trim()
          : defaultTitle,
      profileId: row['profile_id'] as String?,
      createdAt: created is String
          ? (DateTime.tryParse(created) ?? DateTime.now())
          : DateTime.now(),
      updatedAt: updated is String
          ? (DateTime.tryParse(updated) ?? DateTime.now())
          : DateTime.now(),
    );
  }
}

/// 运行期的工具调用状态（仅用于 UI 展示，不落库）。
enum AiToolCallState { pending, approved, denied, done, failed }

/// 运行期工具调用记录：把模型给出的调用与执行结果配对，供 UI 渲染卡片。
class AiToolCallRecord {
  final AiToolCall call;
  final String toolDescription;
  final bool isMutating;
  AiToolCallState state;
  String? resultPreview;
  String? errorCode;

  AiToolCallRecord({
    required this.call,
    this.toolDescription = '',
    this.isMutating = false,
    this.state = AiToolCallState.pending,
    this.resultPreview,
    this.errorCode,
  });

  AiToolCallRecord copy() => AiToolCallRecord(
    call: call,
    toolDescription: toolDescription,
    isMutating: isMutating,
    state: state,
    resultPreview: resultPreview,
    errorCode: errorCode,
  );
}
