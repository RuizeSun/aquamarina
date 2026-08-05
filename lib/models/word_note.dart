/// 单词收藏与笔记记录
class WordNote {
  final String word;
  final String? note;
  final bool isFavorited;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const WordNote({
    required this.word,
    this.note,
    this.isFavorited = false,
    this.createdAt,
    this.updatedAt,
  });

  factory WordNote.fromMap(Map<String, dynamic> map) {
    return WordNote(
      word: map['word'] as String,
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
