class UserWordRecord {
  final int? id;
  final String word;
  final int stage;
  final bool isWeak;
  final bool isMastered;
  final String? nextReviewDate;
  final DateTime? lastReviewedAt;
  final int reviewCount;
  final DateTime? createdAt;

  UserWordRecord({
    this.id,
    required this.word,
    this.stage = 0,
    this.isWeak = false,
    this.isMastered = false,
    this.nextReviewDate,
    this.lastReviewedAt,
    this.reviewCount = 0,
    this.createdAt,
  });

  factory UserWordRecord.fromMap(Map<String, dynamic> map) {
    return UserWordRecord(
      id: map['id'] as int?,
      word: map['word'] as String,
      stage: (map['stage'] as int?) ?? 0,
      isWeak: (map['is_weak'] as int?) == 1,
      isMastered: (map['is_mastered'] as int?) == 1,
      nextReviewDate: map['next_review_date'] as String?,
      lastReviewedAt: map['last_reviewed_at'] != null
          ? DateTime.parse(map['last_reviewed_at'] as String)
          : null,
      reviewCount: (map['review_count'] as int?) ?? 0,
      createdAt: map['created_at'] != null
          ? DateTime.parse(map['created_at'] as String)
          : null,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      if (id != null) 'id': id,
      'word': word,
      'stage': stage,
      'is_weak': isWeak ? 1 : 0,
      'is_mastered': isMastered ? 1 : 0,
      'next_review_date': nextReviewDate,
      'last_reviewed_at': lastReviewedAt?.toIso8601String(),
      'review_count': reviewCount,
      'created_at': createdAt?.toIso8601String(),
    };
  }

  UserWordRecord copyWith({
    int? id,
    String? word,
    int? stage,
    bool? isWeak,
    bool? isMastered,
    String? nextReviewDate,
    DateTime? lastReviewedAt,
    int? reviewCount,
    DateTime? createdAt,
  }) {
    return UserWordRecord(
      id: id ?? this.id,
      word: word ?? this.word,
      stage: stage ?? this.stage,
      isWeak: isWeak ?? this.isWeak,
      isMastered: isMastered ?? this.isMastered,
      nextReviewDate: nextReviewDate ?? this.nextReviewDate,
      lastReviewedAt: lastReviewedAt ?? this.lastReviewedAt,
      reviewCount: reviewCount ?? this.reviewCount,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// 获取该梯级对应的下次间隔天数
  static int intervalDaysForStage(int stage) {
    const intervals = [1, 3, 7, 14, 21, 28];
    if (stage < 0) return 1;
    if (stage >= intervals.length) return 28;
    return intervals[stage];
  }

  /// 计算下次复习日期
  String computeNextReviewDate() {
    final days = intervalDaysForStage(stage);
    final next = DateTime.now().add(Duration(days: days));
    return '${next.year}-${next.month.toString().padLeft(2, '0')}-${next.day.toString().padLeft(2, '0')}';
  }
}
