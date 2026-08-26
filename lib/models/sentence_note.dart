/// 句子收藏与笔记记录
class SentenceNote {
  final String sentenceId;
  final String? setId;
  final String english;
  final String chinese;
  final String? note;
  final bool isFavorited;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const SentenceNote({
    required this.sentenceId,
    this.setId,
    required this.english,
    required this.chinese,
    this.note,
    this.isFavorited = false,
    this.createdAt,
    this.updatedAt,
  });

  factory SentenceNote.fromMap(Map<String, dynamic> map) {
    return SentenceNote(
      sentenceId: map['sentence_id'] as String,
      setId: map['set_id'] as String?,
      english: map['english'] as String,
      chinese: map['chinese'] as String,
      note: map['note'] as String?,
      isFavorited: ((map['is_favorited'] as int?) ?? 0) == 1,
      createdAt: map['created_at'] != null
          ? DateTime.tryParse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'] as String)
          : null,
    );
  }
}
