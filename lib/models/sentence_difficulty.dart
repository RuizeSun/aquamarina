/// 句式难度档位：AI 生成句式集时用于约束句子的 CEFR 等级。
///
/// 六档与 CEFR（欧洲语言共同参考框架）的对应关系：
///
/// | 档位 | CEFR |
/// | --- | --- |
/// | 入门 | A1 |
/// | 基础 | A2 |
/// | 进阶 | B1 |
/// | 中级 | B2 |
/// | 高级 | C1 |
/// | 自由运用 | C2 |
enum SentenceDifficulty {
  starter(
    label: '入门',
    cefr: 'A1',
    promptHint:
        '只使用最高频的基础词汇与一般现在时 / 情态动词（can、like、want、have 等），'
        '句子长度 5~8 个单词，结构为「主语 + 谓语 + 宾语」的简单句，不使用任何从句。',
    tokensPerSentence: 45,
  ),
  basic(
    label: '基础',
    cefr: 'A2',
    promptHint:
        '使用日常生活高频词汇与一般过去时 / 一般将来时，句子长度 7~11 个单词，'
        '可用 and、but、because、so 连接并列句，主题贴近日常场景（购物、出行、学习等）。',
    tokensPerSentence: 52,
  ),
  intermediate(
    label: '进阶',
    cefr: 'B1',
    promptHint:
        '使用常见话题词汇与较丰富的时态（现在完成时、被动语态等），句子长度 10~15 个单词，'
        '可包含定语从句、时间 / 条件状语从句，允许出现连接副词。',
    tokensPerSentence: 60,
  ),
  upperIntermediate(
    label: '中级',
    cefr: 'B2',
    promptHint:
        '使用半抽象或半专业词汇与固定搭配，句子长度 13~19 个单词，'
        '可包含名词性从句、非谓语动词短语、让步 / 原因状语从句，逻辑衔接自然。',
    tokensPerSentence: 68,
  ),
  advanced(
    label: '高级',
    cefr: 'C1',
    promptHint:
        '使用地道书面表达、习语与精准搭配，句子长度 16~24 个单词，'
        '可包含倒装、虚拟语气、多重从句嵌套与复杂的修饰成分。',
    tokensPerSentence: 78,
  ),
  mastery(
    label: '自由运用',
    cefr: 'C2',
    promptHint:
        '完全贴近母语者的自然表达，词汇与句式不设限，句子长度 18~30 个单词，'
        '可包含修辞手法、省略、插入语与复杂逻辑衔接，读起来应像原版读物中的句子。',
    tokensPerSentence: 88,
  );

  /// 中文档位名（入门 / 基础 / 进阶 / 中级 / 高级 / 自由运用）
  final String label;

  /// 对应的 CEFR 等级（A1 ~ C2）
  final String cefr;

  /// 写入提示词、对 AI 描述该难度句子形态的说明
  final String promptHint;

  /// 该难度下单句英文 + 中文翻译 + 多余词的输出 token 粗略估算值（含 JSON 结构开销）
  final int tokensPerSentence;

  const SentenceDifficulty({
    required this.label,
    required this.cefr,
    required this.promptHint,
    required this.tokensPerSentence,
  });

  /// 面向用户的展示名，如 `入门（A1）`
  String get displayName => '$label（$cefr）';

  /// 从序列化名解析，未知时回退到「入门」
  static SentenceDifficulty fromName(String? name) => values.firstWhere(
    (e) => e.name == name,
    orElse: () => SentenceDifficulty.starter,
  );
}
