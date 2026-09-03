import '../models/ai_profile.dart';
import 'database_service.dart';
import 'log_service.dart';

/// 请求类型（仅作记录标注）
enum AiUsageRequestMode {
  chat,
  stream;

  String get label => switch (this) {
    AiUsageRequestMode.chat => '非流式',
    AiUsageRequestMode.stream => '流式',
  };
}

/// 单条 AI 用量请求记录
class AiUsageRecord {
  final int id;
  final DateTime createdAt;
  final String? profileId;
  final String profileName;
  final String? profileType;
  final String? model;
  final String requestMode;

  final int promptTokens;
  final int cacheHitTokens;
  final int cacheMissTokens;
  final int completionTokens;
  final int totalTokens;

  // 计费价格快照（请求发生时）
  final String? pricingMode;
  final String? priceUnit;
  final double? cacheHitPrice;
  final double? cacheMissPrice;
  final double? outputPrice;
  final double? requestPrice;
  final String? currencySymbol;
  final int currencyDecimals;
  final bool currencyGrouping;
  final double? cost;

  const AiUsageRecord({
    required this.id,
    required this.createdAt,
    this.profileId,
    required this.profileName,
    this.profileType,
    this.model,
    required this.requestMode,
    required this.promptTokens,
    required this.cacheHitTokens,
    required this.cacheMissTokens,
    required this.completionTokens,
    required this.totalTokens,
    this.pricingMode,
    this.priceUnit,
    this.cacheHitPrice,
    this.cacheMissPrice,
    this.outputPrice,
    this.requestPrice,
    this.currencySymbol,
    required this.currencyDecimals,
    required this.currencyGrouping,
    this.cost,
  });

  /// 格式化该条记录的费用，无可计价配置时返回 null
  String? formatCost() {
    final costValue = cost;
    if (costValue == null) return null;
    return AiUsageService.formatMoney(
      costValue,
      symbol: currencySymbol ?? '¥',
      decimals: currencyDecimals,
      grouping: currencyGrouping,
    );
  }

  factory AiUsageRecord.fromRow(Map<String, Object?> row) {
    int asInt(String key) => (row[key] as num?)?.toInt() ?? 0;
    return AiUsageRecord(
      id: asInt('id'),
      createdAt: DateTime.tryParse(row['created_at'] as String? ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      profileId: row['profile_id'] as String?,
      profileName: row['profile_name'] as String? ?? '未知配置',
      profileType: row['profile_type'] as String?,
      model: row['model'] as String?,
      requestMode: row['request_mode'] as String? ?? 'chat',
      promptTokens: asInt('prompt_tokens'),
      cacheHitTokens: asInt('cache_hit_tokens'),
      cacheMissTokens: asInt('cache_miss_tokens'),
      completionTokens: asInt('completion_tokens'),
      totalTokens: asInt('total_tokens'),
      pricingMode: row['pricing_mode'] as String?,
      priceUnit: row['price_unit'] as String?,
      cacheHitPrice: (row['cache_hit_price'] as num?)?.toDouble(),
      cacheMissPrice: (row['cache_miss_price'] as num?)?.toDouble(),
      outputPrice: (row['output_price'] as num?)?.toDouble(),
      requestPrice: (row['request_price'] as num?)?.toDouble(),
      currencySymbol: row['currency_symbol'] as String?,
      currencyDecimals: asInt('currency_decimals'),
      currencyGrouping: (row['currency_grouping'] as int?) == 1,
      cost: (row['cost'] as num?)?.toDouble(),
    );
  }
}

/// 一段时间内的用量与费用汇总
class AiUsageSummary {
  final int requests;
  final int promptTokens;
  final int cacheHitTokens;
  final int cacheMissTokens;
  final int completionTokens;
  final int totalTokens;
  final double cost;

  const AiUsageSummary({
    required this.requests,
    required this.promptTokens,
    required this.cacheHitTokens,
    required this.cacheMissTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.cost,
  });
}

/// AI 调用用量与计费统计服务（全局单例）
///
/// 仅统计 OpenAI 兼容 / DeepSeek 类型的请求（Aquamarina 官方无 usage，不支持统计）。
/// 价格在请求发生时被快照进记录，修改配置价格不影响历史金额。
class AiUsageService {
  AiUsageService._();

  static final AiUsageService instance = AiUsageService._();

  static const String table = 'ai_usage_records';

  // ── 写入 ──────────────────────────────────────────

  /// 记录一次请求的用量与费用（成功响应）。失败仅记录日志，不影响主流程。
  Future<void> record({
    required AiProfile profile,
    required AiUsageRequestMode requestMode,
    required int promptTokens,
    required int cacheHitTokens,
    required int cacheMissTokens,
    required int completionTokens,
    required int totalTokens,
  }) async {
    final now = DateTime.now();
    final pricing = profile.pricing;

    final cost = pricing == null
        ? null
        : _computeCost(
            pricing,
            cacheHitTokens: cacheHitTokens,
            cacheMissTokens: cacheMissTokens,
            completionTokens: completionTokens,
          );

    final row = <String, Object?>{
      'created_at': now.toIso8601String(),
      'profile_id': profile.id,
      'profile_name': profile.name,
      'profile_type': profile.type.name,
      'model': profile.model,
      'request_mode': requestMode.name,
      'prompt_tokens': promptTokens,
      'cache_hit_tokens': cacheHitTokens,
      'cache_miss_tokens': cacheMissTokens,
      'completion_tokens': completionTokens,
      'total_tokens': totalTokens,
      'pricing_mode': pricing?.mode.name,
      'price_unit': pricing?.unit.name,
      'cache_hit_price': pricing?.cacheHitPrice,
      'cache_miss_price': pricing?.cacheMissPrice,
      'output_price': pricing?.outputPrice,
      'request_price': pricing?.requestPrice,
      'currency_symbol': pricing?.currencySymbol,
      'currency_decimals': pricing?.currencyDecimals ?? 2,
      'currency_grouping': (pricing?.currencyGrouping ?? true) ? 1 : 0,
      'cost': cost,
    };

    try {
      final db = await DatabaseService.database;
      await db.insert(table, row);
    } catch (e, stackTrace) {
      logError('AiUsageService', '记录 AI 用量失败: $e', stackTrace);
    }
  }


  /// 计算一次请求的费用（按该配置的价格快照）。
  double? _computeCost(
    AiUsagePricing pricing, {
    required int cacheHitTokens,
    required int cacheMissTokens,
    required int completionTokens,
  }) {
    if (pricing.isPerRequest) {
      return pricing.requestPrice;
    }

    final divisor = pricing.unit.divisor.toDouble();
    if (divisor <= 0) return null;

    double cost = 0;
    bool hasTerm = false;
    if (pricing.cacheHitPrice != null) {
      cost += cacheHitTokens * pricing.cacheHitPrice! / divisor;
      hasTerm = true;
    }
    if (pricing.cacheMissPrice != null) {
      cost += cacheMissTokens * pricing.cacheMissPrice! / divisor;
      hasTerm = true;
    }
    if (pricing.outputPrice != null) {
      cost += completionTokens * pricing.outputPrice! / divisor;
      hasTerm = true;
    }
    return hasTerm ? cost : null;
  }

  // ── 查询 ──────────────────────────────────────────

  /// 汇总自 [from]（含）之后的用量与费用；为 null 表示全部。
  Future<AiUsageSummary> fetchSummary({DateTime? from}) async {
    try {
      final db = await DatabaseService.database;
      final where = from != null ? 'created_at >= ?' : null;
      final args = from != null ? [from.toIso8601String()] : <Object?>[];
      final result = await db.rawQuery(
        '''
        SELECT
          COUNT(*) AS requests,
          COALESCE(SUM(prompt_tokens), 0) AS prompt,
          COALESCE(SUM(cache_hit_tokens), 0) AS cache_hit,
          COALESCE(SUM(cache_miss_tokens), 0) AS cache_miss,
          COALESCE(SUM(completion_tokens), 0) AS completion,
          COALESCE(SUM(total_tokens), 0) AS total,
          COALESCE(SUM(cost), 0) AS cost
        FROM $table
        ${where != null ? 'WHERE $where' : ''}
        ''',
        args,
      );
      final row = result.isNotEmpty ? result.first : null;
      int v(String k) => (row?[k] as num?)?.toInt() ?? 0;
      return AiUsageSummary(
        requests: v('requests'),
        promptTokens: v('prompt'),
        cacheHitTokens: v('cache_hit'),
        cacheMissTokens: v('cache_miss'),
        completionTokens: v('completion'),
        totalTokens: v('total'),
        cost: (row?['cost'] as num?)?.toDouble() ?? 0,
      );
    } catch (e, stackTrace) {
      logError('AiUsageService', '查询用量汇总失败: $e', stackTrace);
      return const AiUsageSummary(
        requests: 0,
        promptTokens: 0,
        cacheHitTokens: 0,
        cacheMissTokens: 0,
        completionTokens: 0,
        totalTokens: 0,
        cost: 0,
      );
    }
  }

  /// 按时间倒序分页获取请求记录。
  Future<List<AiUsageRecord>> fetchRecords({
    DateTime? from,
    int limit = 50,
    int offset = 0,
  }) async {
    try {
      final db = await DatabaseService.database;
      final where = from != null ? 'created_at >= ?' : null;
      final args = <Object?>[if (from != null) from.toIso8601String()];
      final rows = await db.query(
        table,
        where: where,
        whereArgs: args,
        orderBy: 'id DESC',
        limit: limit,
        offset: offset,
      );
      return rows.map(AiUsageRecord.fromRow).toList();
    } catch (e, stackTrace) {
      logError('AiUsageService', '查询请求记录失败: $e', stackTrace);
      return const [];
    }
  }

  /// 清空所有统计记录。
  Future<void> clear() async {
    try {
      final db = await DatabaseService.database;
      await db.delete(table);
    } catch (e, stackTrace) {
      logError('AiUsageService', '清空用量统计失败: $e', stackTrace);
    }
  }

  // ── 金额格式化 ────────────────────────────────────

  /// 按币种符号与数字格式格式化金额，如 `¥1,234.56`。
  static String formatMoney(
    double amount, {
    String symbol = '¥',
    int decimals = 2,
    bool grouping = true,
  }) {
    final dec = decimals.clamp(0, 4);
    final rounded = amount.toStringAsFixed(dec);
    final neg = rounded.startsWith('-');
    final abs = neg ? rounded.substring(1) : rounded;

    final parts = abs.split('.');
    String intPart = parts[0];
    if (grouping && intPart.length > 3) {
      final buffer = StringBuffer();
      for (int i = 0; i < intPart.length; i++) {
        final idx = intPart.length - 1 - i;
        if (i > 0 && i % 3 == 0) {
          buffer.write(',');
        }
        buffer.write(intPart[idx]);
      }
      intPart = buffer.toString().split('').reversed.join();
    }
    final result = dec > 0 ? '$intPart.${parts[1]}' : intPart;
    final sign = neg ? '-' : '';
    return '$sign$symbol$result';
  }
}

