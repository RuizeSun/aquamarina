class WordBook {
  final int? id;
  final String title;
  final String? description;
  final String? coverPath;
  final int? coverColor;
  final String? author;
  final int wordCount;
  final bool isBuiltin;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  WordBook({
    this.id,
    required this.title,
    this.description,
    this.coverPath,
    this.coverColor,
    this.author,
    this.wordCount = 0,
    this.isBuiltin = false,
    this.createdAt,
    this.updatedAt,
  });

  factory WordBook.fromMap(Map<String, dynamic> map) {
    return WordBook(
      id: map['id'] as int?,
      title: map['title'] as String,
      description: map['description'] as String?,
      coverPath: map['cover_path'] as String?,
      coverColor: map['cover_color'] as int?,
      author: map['author'] as String?,
      wordCount: (map['word_count'] as int?) ?? 0,
      isBuiltin: (map['is_builtin'] as int?) == 1,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : null,
      updatedAt: map['updated_at'] != null
          ? DateTime.parse(map['updated_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'title': title,
      'description': description,
      'cover_path': coverPath,
      'cover_color': coverColor,
      'author': author,
      'word_count': wordCount,
      'is_builtin': isBuiltin ? 1 : 0,
      'created_at': createdAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
  }

  WordBook copyWith({
    int? id,
    String? title,
    String? description,
    String? coverPath,
    int? coverColor,
    String? author,
    int? wordCount,
    bool? isBuiltin,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return WordBook(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      coverPath: coverPath ?? this.coverPath,
      coverColor: coverColor ?? this.coverColor,
      author: author ?? this.author,
      wordCount: wordCount ?? this.wordCount,
      isBuiltin: isBuiltin ?? this.isBuiltin,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
