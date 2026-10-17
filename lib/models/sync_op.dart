import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 混合逻辑时钟（HLC）：毫秒时间 + 逻辑计数。
///
/// 字符串形式固定 16 位毫秒 + 8 位计数（十六进制），可直接按字典序比较。
class SyncHlc implements Comparable<SyncHlc> {
  final int ms;
  final int counter;

  const SyncHlc(this.ms, this.counter);

  factory SyncHlc.parse(String value) {
    final parts = value.split(':');
    if (parts.length != 2) {
      throw const FormatException('HLC 格式错误');
    }
    final ms = int.tryParse(parts[0], radix: 16);
    final counter = int.tryParse(parts[1], radix: 16);
    if (ms == null || counter == null || ms < 0 || counter < 0) {
      throw const FormatException('HLC 数值错误');
    }
    return SyncHlc(ms, counter);
  }

  String get value =>
      '${ms.toRadixString(16).padLeft(16, '0')}:'
      '${counter.toRadixString(16).padLeft(8, '0')}';

  /// 生成下一个 HLC：物理时间前进则计数归零，否则计数递增。
  static SyncHlc next({
    required int nowMs,
    required int lastMs,
    required int lastCounter,
  }) {
    if (nowMs > lastMs) return SyncHlc(nowMs, 0);
    return SyncHlc(lastMs, lastCounter + 1);
  }

  @override
  int compareTo(SyncHlc other) {
    final byMs = ms.compareTo(other.ms);
    if (byMs != 0) return byMs;
    return counter.compareTo(other.counter);
  }

  @override
  bool operator ==(Object other) =>
      other is SyncHlc && other.ms == ms && other.counter == counter;

  @override
  int get hashCode => Object.hash(ms, counter);

  @override
  String toString() => value;
}

/// 批量 op 中的一个实体操作（用于大批量导入压缩 oplog）。
class SyncBulkItem {
  final String entity;
  final Map<String, dynamic> key;
  final Map<String, dynamic> data;
  final Map<String, int> delta;

  const SyncBulkItem({
    required this.entity,
    required this.key,
    this.data = const {},
    this.delta = const {},
  });

  factory SyncBulkItem.fromJson(Map<String, dynamic> json) {
    final entity = json['entity'];
    final key = json['key'];
    final data = json['data'];
    final delta = json['delta'];
    if (entity is! String || entity.isEmpty || key is! Map) {
      throw const FormatException('bulk item 字段缺失');
    }
    return SyncBulkItem(
      entity: entity,
      key: key.cast<String, dynamic>(),
      data: data is Map
          ? data.cast<String, dynamic>()
          : const <String, dynamic>{},
      delta: delta is Map
          ? delta.map((k, v) => MapEntry(k.toString(), (v as num).toInt()))
          : const <String, int>{},
    );
  }

  Map<String, dynamic> toJson() => {
    'entity': entity,
    'key': key,
    if (data.isNotEmpty) 'data': data,
    if (delta.isNotEmpty) 'delta': delta,
  };
}

/// 单条同步操作（oplog 的传输形态）。
class SyncOp {
  static const int currentVersion = 2;

  final int version;
  final String deviceId;
  final int seq;
  final SyncHlc hlc;
  final String entity;

  /// 业务唯一键（跨设备稳定）。
  final Map<String, dynamic> key;

  /// `upsert` 或 `delete`。
  final String op;

  /// 普通数据列（delete 时为空）。
  final Map<String, dynamic> data;

  /// 计数增量（列名 → delta）。
  final Map<String, int> delta;

  /// 删除时间（delete 时存在）。
  final String? deletedAt;

  /// 批量 op 的条目；普通 op 为空。
  final List<SyncBulkItem> items;

  const SyncOp({
    this.version = currentVersion,
    required this.deviceId,
    required this.seq,
    required this.hlc,
    required this.entity,
    required this.key,
    required this.op,
    this.data = const {},
    this.delta = const {},
    this.deletedAt,
    this.items = const [],
  });

  bool get isDelete => op == 'delete';

  bool get isBulk => op == 'bulk';

  /// 供 tombstone 使用的稳定键（键顺序固定）。
  String get keyFingerprint {
    final sorted = key.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return jsonEncode({for (final e in sorted) e.key: e.value});
  }

  factory SyncOp.fromJson(Map<String, dynamic> json) {
    final version = json['v'];
    if (version is! int || version < 1) {
      throw const FormatException('op 版本无效');
    }
    if (version > currentVersion) {
      throw FormatException('op 版本过新（$version），请先升级应用');
    }
    final deviceId = json['device_id'];
    final seq = json['seq'];
    final hlc = json['hlc'];
    final entity = json['entity'];
    final key = json['key'];
    final op = json['op'];
    if (deviceId is! String ||
        deviceId.isEmpty ||
        seq is! int ||
        seq <= 0 ||
        hlc is! String ||
        entity is! String ||
        entity.isEmpty ||
        key is! Map ||
        op is! String) {
      throw const FormatException('op 字段缺失或格式错误');
    }
    if (op != 'upsert' && op != 'delete' && op != 'bulk') {
      throw FormatException('未知 op 类型：$op');
    }
    final rawData = json['data'];
    final rawDelta = json['delta'];
    final rawItems = json['items'];
    final deletedAt = json['deleted_at'];
    if (rawData != null && rawData is! Map) {
      throw const FormatException('op.data 格式错误');
    }
    if (rawDelta != null && rawDelta is! Map) {
      throw const FormatException('op.delta 格式错误');
    }
    if (rawItems != null && rawItems is! List) {
      throw const FormatException('op.items 格式错误');
    }
    final items = <SyncBulkItem>[];
    if (rawItems is List) {
      for (final item in rawItems) {
        if (item is! Map) throw const FormatException('op.items 元素格式错误');
        items.add(SyncBulkItem.fromJson(item.cast<String, dynamic>()));
      }
    }
    if (op == 'bulk' && items.isEmpty) {
      throw const FormatException('bulk op 缺少 items');
    }
    return SyncOp(
      version: version,
      deviceId: deviceId,
      seq: seq,
      hlc: SyncHlc.parse(hlc),
      entity: entity,
      key: key.cast<String, dynamic>(),
      op: op,
      data: rawData == null
          ? const {}
          : (rawData as Map).cast<String, dynamic>(),
      delta: rawDelta == null
          ? const {}
          : (rawDelta as Map).map(
              (k, v) => MapEntry(k.toString(), (v as num).toInt()),
            ),
      deletedAt: deletedAt is String ? deletedAt : null,
      items: items,
    );
  }

  Map<String, dynamic> toJson() => {
    'v': version,
    'device_id': deviceId,
    'seq': seq,
    'hlc': hlc.value,
    'entity': entity,
    'key': key,
    'op': op,
    'data': data,
    'delta': delta,
    if (deletedAt != null) 'deleted_at': deletedAt,
    if (items.isNotEmpty) 'items': items.map((e) => e.toJson()).toList(),
  };
}

/// JSONL 编解码（chunk 的传输格式）。
class SyncChunkCodec {
  SyncChunkCodec._();

  static Uint8List encode(Iterable<SyncOp> ops) {
    final buffer = StringBuffer();
    for (final op in ops) {
      buffer.writeln(jsonEncode(op.toJson()));
    }
    return Uint8List.fromList(utf8.encode(buffer.toString()));
  }

  /// 压缩后的 chunk 内容（gzip）。体积通常只有 JSONL 的 1/5 – 1/10。
  static Uint8List encodeCompressed(Iterable<SyncOp> ops) {
    return Uint8List.fromList(gzip.encode(encode(ops)));
  }

  /// gzip 魔数：`1f 8b`。对象键后缀缺失时也可据此识别。
  static bool isGzip(List<int> bytes) =>
      bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

  /// 自动识别并解压（兼容 v15 及更早的未压缩 `.jsonl`）。
  static List<SyncOp> decodeAuto(List<int> bytes) {
    if (isGzip(bytes)) {
      return decode(gzip.decode(bytes));
    }
    return decode(bytes);
  }

  static List<SyncOp> decode(List<int> bytes) {
    final text = utf8.decode(bytes);
    final ops = <SyncOp>[];
    final lines = const LineSplitter().convert(text);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      try {
        final decoded = jsonDecode(line);
        if (decoded is! Map) {
          throw const FormatException('chunk 行不是对象');
        }
        ops.add(SyncOp.fromJson(decoded.cast<String, dynamic>()));
      } on FormatException catch (e) {
        throw FormatException('chunk 第 ${i + 1} 行损坏：${e.message}');
      }
    }
    return ops;
  }
}
