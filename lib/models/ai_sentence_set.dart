/// 句式集模型（类似 WordBook）
class SentenceSet {
  final String? id;
  final String name;
  final String? description;
  final int sentenceCount;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  SentenceSet({
    this.id,
    required this.name,
    this.description,
    this.sentenceCount = 0,
    this.createdAt,
    this.updatedAt,
  });

  factory SentenceSet.fromJson(Map<String, dynamic> json) {
    return SentenceSet(
      id: json['id'] as String?,
      name: json['name'] as String,
      description: json['description'] as String?,
      sentenceCount: (json['sentence_count'] as int?) ?? 0,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : null,
      updatedAt: json['updated_at'] != null
          ? DateTime.parse(json['updated_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'name': name,
    'description': description,
    'sentence_count': sentenceCount,
    'created_at': createdAt?.toIso8601String(),
    'updated_at': updatedAt?.toIso8601String(),
  };

  SentenceSet copyWith({
    String? id,
    String? name,
    String? description,
    int? sentenceCount,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SentenceSet(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      sentenceCount: sentenceCount ?? this.sentenceCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
