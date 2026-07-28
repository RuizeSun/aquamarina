/// 句子模型
class Sentence {
  final String? id;
  final String setId; // 所属句式集 ID
  final String english; // 英文原句
  final String chinese; // 中文翻译
  final List<String> extraWords; // 入门版多余词列表（1~5个）

  Sentence({
    this.id,
    required this.setId,
    required this.english,
    required this.chinese,
    this.extraWords = const [],
  });

  factory Sentence.fromJson(Map<String, dynamic> json) {
    return Sentence(
      id: json['id'] as String?,
      setId: json['set_id'] as String,
      english: json['english'] as String,
      chinese: json['chinese'] as String,
      extraWords:
          (json['extra_words'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'set_id': setId,
    'english': english,
    'chinese': chinese,
    'extra_words': extraWords,
  };

  Sentence copyWith({
    String? id,
    String? setId,
    String? english,
    String? chinese,
    List<String>? extraWords,
  }) {
    return Sentence(
      id: id ?? this.id,
      setId: setId ?? this.setId,
      english: english ?? this.english,
      chinese: chinese ?? this.chinese,
      extraWords: extraWords ?? this.extraWords,
    );
  }
}

/// AI 返回的批改结果
class AiSentenceResult {
  final int score; // 0-10
  final String markup; // 带 HTML 标签的原文
  final String comment; // 中文批注

  AiSentenceResult({
    required this.score,
    required this.markup,
    required this.comment,
  });

  factory AiSentenceResult.fromJson(Map<String, dynamic> json) {
    return AiSentenceResult(
      score: (json['score'] as num).toInt().clamp(0, 10),
      markup: json['markup'] as String? ?? '',
      comment: json['comment'] as String? ?? '',
    );
  }
}

/// 练习模式
enum PracticeMode { beginner, advanced }

/// 练习记录
class PracticeRecord {
  final Sentence sentence;
  final String userAnswer;
  final AiSentenceResult result;
  final PracticeMode mode;

  PracticeRecord({
    required this.sentence,
    required this.userAnswer,
    required this.result,
    required this.mode,
  });
}

/// 错题本记录
class WrongSentenceRecord {
  final String id;
  final String sentenceId;
  final String setId;
  final String english;
  final String chinese;
  final int score;
  final String userAnswer;
  final PracticeMode mode;
  final DateTime createdAt;

  WrongSentenceRecord({
    required this.id,
    required this.sentenceId,
    required this.setId,
    required this.english,
    required this.chinese,
    required this.score,
    required this.userAnswer,
    required this.mode,
    required this.createdAt,
  });

  factory WrongSentenceRecord.fromJson(Map<String, dynamic> json) {
    return WrongSentenceRecord(
      id: json['id'] as String,
      sentenceId: json['sentence_id'] as String,
      setId: json['set_id'] as String,
      english: json['english'] as String,
      chinese: json['chinese'] as String,
      score: (json['score'] as num).toInt(),
      userAnswer: json['user_answer'] as String,
      mode: (json['mode'] as int) == 0
          ? PracticeMode.beginner
          : PracticeMode.advanced,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'sentence_id': sentenceId,
    'set_id': setId,
    'english': english,
    'chinese': chinese,
    'score': score,
    'user_answer': userAnswer,
    'mode': mode == PracticeMode.beginner ? 0 : 1,
    'created_at': createdAt.toIso8601String(),
  };

  WrongSentenceRecord copyWith({
    String? id,
    int? score,
    String? userAnswer,
    DateTime? createdAt,
  }) {
    return WrongSentenceRecord(
      id: id ?? this.id,
      sentenceId: sentenceId,
      setId: setId,
      english: english,
      chinese: chinese,
      score: score ?? this.score,
      userAnswer: userAnswer ?? this.userAnswer,
      mode: mode,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
