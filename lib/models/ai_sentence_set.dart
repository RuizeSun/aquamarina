/// 句式集模型（类似 WordBook）
class SentenceSet {
  final String? id;
  final String name;
  final String? description;
  final int sentenceCount;
  final bool isBuiltin;
  final DateTime? createdAt;

  SentenceSet({
    this.id,
    required this.name,
    this.description,
    this.sentenceCount = 0,
    this.isBuiltin = false,
    this.createdAt,
  });

  factory SentenceSet.fromJson(Map<String, dynamic> json) {
    return SentenceSet(
      id: json['id'] as String?,
      name: json['name'] as String,
      description: json['description'] as String?,
      sentenceCount: (json['sentence_count'] as int?) ?? 0,
      isBuiltin: (json['is_builtin'] as bool?) ?? false,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'name': name,
    'description': description,
    'sentence_count': sentenceCount,
    'is_builtin': isBuiltin,
    'created_at': createdAt?.toIso8601String(),
  };

  SentenceSet copyWith({
    String? id,
    String? name,
    String? description,
    int? sentenceCount,
    bool? isBuiltin,
    DateTime? createdAt,
  }) {
    return SentenceSet(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      sentenceCount: sentenceCount ?? this.sentenceCount,
      isBuiltin: isBuiltin ?? this.isBuiltin,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
