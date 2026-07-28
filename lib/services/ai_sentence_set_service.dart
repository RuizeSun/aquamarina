import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/ai_sentence_set.dart';
import '../models/ai_sentence.dart';

/// 句式集管理服务
class SentenceSetService extends ChangeNotifier {
  static const String _prefsSetsKey = 'sentence_sets_v1';
  static const String _prefsSentencesPrefix = 'sentences_set_';

  List<SentenceSet> _sets = [];
  bool _loaded = false;

  static const String builtInSetId = 'builtin_basics';

  List<SentenceSet> get sets => List.unmodifiable(_sets);
  bool get loaded => _loaded;

  // ===== 内置句式 =====
  static List<Sentence> _builtInSentences() {
    return [
      Sentence(
        id: 'b_01',
        setId: builtInSetId,
        english: 'I want to go shopping this weekend.',
        chinese: '这周末我想去购物。',
        extraWords: [
          'I',
          'want',
          'to',
          'go',
          'shopping',
          'this',
          'weekend',
          'always',
          'never',
          'yesterday',
        ],
      ),
      Sentence(
        id: 'b_02',
        setId: builtInSetId,
        english: 'She is good at playing the piano.',
        chinese: '她擅长弹钢琴。',
        extraWords: [
          'She',
          'is',
          'good',
          'at',
          'playing',
          'the',
          'piano',
          'bad',
          'guitar',
          'listen',
        ],
      ),
      Sentence(
        id: 'b_03',
        setId: builtInSetId,
        english: 'It is important to practice English every day.',
        chinese: '每天练习英语很重要。',
        extraWords: [
          'It',
          'is',
          'important',
          'to',
          'practice',
          'English',
          'every',
          'day',
          'book',
          'difficult',
        ],
      ),
      Sentence(
        id: 'b_04',
        setId: builtInSetId,
        english: 'Could you tell me where the nearest hospital is?',
        chinese: '你能告诉我最近的医院在哪里吗？',
        extraWords: [
          'Could',
          'you',
          'tell',
          'me',
          'where',
          'the',
          'nearest',
          'hospital',
          'is',
          'library',
          'far',
          'school',
        ],
      ),
      Sentence(
        id: 'b_05',
        setId: builtInSetId,
        english: 'He has been studying English for three years.',
        chinese: '他已经学了三年英语了。',
        extraWords: [
          'He',
          'has',
          'been',
          'studying',
          'English',
          'for',
          'three',
          'years',
          'learning',
          'two',
          'months',
        ],
      ),
      Sentence(
        id: 'b_06',
        setId: builtInSetId,
        english: 'If it rains tomorrow, we will stay at home.',
        chinese: '如果明天下雨，我们就待在家里。',
        extraWords: [
          'If',
          'it',
          'rains',
          'tomorrow',
          'we',
          'will',
          'stay',
          'at',
          'home',
          'snows',
          'school',
          'park',
        ],
      ),
      Sentence(
        id: 'b_07',
        setId: builtInSetId,
        english: 'The movie that I watched last night was very interesting.',
        chinese: '我昨晚看的那部电影非常有趣。',
        extraWords: [
          'The',
          'movie',
          'that',
          'I',
          'watched',
          'last',
          'night',
          'was',
          'very',
          'interesting',
          'boring',
          'book',
        ],
      ),
      Sentence(
        id: 'b_08',
        setId: builtInSetId,
        english: 'Would you like to have dinner with me tonight?',
        chinese: '今晚你愿意和我一起吃晚餐吗？',
        extraWords: [
          'Would',
          'you',
          'like',
          'to',
          'have',
          'dinner',
          'with',
          'me',
          'tonight',
          'lunch',
          'coffee',
        ],
      ),
      Sentence(
        id: 'b_09',
        setId: builtInSetId,
        english: 'I don\'t know how to solve this problem.',
        chinese: '我不知道如何解决这个问题。',
        extraWords: [
          'I',
          "don't",
          'know',
          'how',
          'to',
          'solve',
          'this',
          'problem',
          'answer',
          'question',
        ],
      ),
      Sentence(
        id: 'b_10',
        setId: builtInSetId,
        english: 'She is the most beautiful girl I have ever seen.',
        chinese: '她是我见过最漂亮的女孩。',
        extraWords: [
          'She',
          'is',
          'the',
          'most',
          'beautiful',
          'girl',
          'I',
          'have',
          'ever',
          'seen',
          'tall',
          'boy',
        ],
      ),
      Sentence(
        id: 'b_11',
        setId: builtInSetId,
        english: 'They enjoy listening to music while doing homework.',
        chinese: '他们喜欢边做作业边听音乐。',
        extraWords: [
          'They',
          'enjoy',
          'listening',
          'to',
          'music',
          'while',
          'doing',
          'homework',
          'reading',
          'playing',
          'books',
        ],
      ),
      Sentence(
        id: 'b_12',
        setId: builtInSetId,
        english: 'There are many books on the shelf.',
        chinese: '架子上有很多书。',
        extraWords: [
          'There',
          'are',
          'many',
          'books',
          'on',
          'the',
          'shelf',
          'pens',
          'table',
          'few',
        ],
      ),
      Sentence(
        id: 'b_13',
        setId: builtInSetId,
        english: 'My father bought me a new computer yesterday.',
        chinese: '我父亲昨天给我买了一台新电脑。',
        extraWords: [
          'My',
          'father',
          'bought',
          'me',
          'a',
          'new',
          'computer',
          'yesterday',
          'mother',
          'old',
          'phone',
        ],
      ),
      Sentence(
        id: 'b_14',
        setId: builtInSetId,
        english: 'The children are playing happily in the park.',
        chinese: '孩子们正在公园里开心地玩耍。',
        extraWords: [
          'The',
          'children',
          'are',
          'playing',
          'happily',
          'in',
          'the',
          'park',
          'sadly',
          'school',
        ],
      ),
      Sentence(
        id: 'b_15',
        setId: builtInSetId,
        english: 'Can you help me carry this heavy box?',
        chinese: '你能帮我搬这个重箱子吗？',
        extraWords: [
          'Can',
          'you',
          'help',
          'me',
          'carry',
          'this',
          'heavy',
          'box',
          'light',
          'bag',
          'move',
        ],
      ),
      Sentence(
        id: 'b_16',
        setId: builtInSetId,
        english: 'I usually get up at seven o\'clock in the morning.',
        chinese: '我通常早上七点起床。',
        extraWords: [
          'I',
          'usually',
          'get',
          'up',
          'at',
          'seven',
          "o'clock",
          'in',
          'the',
          'morning',
          'six',
          'night',
        ],
      ),
      Sentence(
        id: 'b_17',
        setId: builtInSetId,
        english: 'This book is so interesting that I read it twice.',
        chinese: '这本书如此有趣以至于我读了两遍。',
        extraWords: [
          'This',
          'book',
          'is',
          'so',
          'interesting',
          'that',
          'I',
          'read',
          'it',
          'twice',
          'boring',
          'once',
        ],
      ),
      Sentence(
        id: 'b_18',
        setId: builtInSetId,
        english: 'We should try our best to protect the environment.',
        chinese: '我们应该尽力保护环境。',
        extraWords: [
          'We',
          'should',
          'try',
          'our',
          'best',
          'to',
          'protect',
          'the',
          'environment',
          'destroy',
          'nature',
        ],
      ),
      Sentence(
        id: 'b_19',
        setId: builtInSetId,
        english: 'What do you usually do on weekends?',
        chinese: '你周末通常做什么？',
        extraWords: [
          'What',
          'do',
          'you',
          'usually',
          'do',
          'on',
          'weekends',
          'always',
          'weekdays',
          'where',
        ],
      ),
      Sentence(
        id: 'b_20',
        setId: builtInSetId,
        english: 'Although it was raining, they still went out to play.',
        chinese: '虽然在下雨，他们还是出去玩了。',
        extraWords: [
          'Although',
          'it',
          'was',
          'raining',
          'they',
          'still',
          'went',
          'out',
          'to',
          'play',
          'snowing',
          'stay',
        ],
      ),
      Sentence(
        id: 'b_21',
        setId: builtInSetId,
        english: 'I am looking forward to hearing from you soon.',
        chinese: '我期待尽快收到你的回信。',
        extraWords: [
          'I',
          'am',
          'looking',
          'forward',
          'to',
          'hearing',
          'from',
          'you',
          'soon',
          'writing',
          'late',
        ],
      ),
      Sentence(
        id: 'b_22',
        setId: builtInSetId,
        english: 'The more you practice, the better you will become.',
        chinese: '你练习得越多，就会变得越好。',
        extraWords: [
          'The',
          'more',
          'you',
          'practice',
          'the',
          'better',
          'you',
          'will',
          'become',
          'less',
          'worse',
        ],
      ),
      Sentence(
        id: 'b_23',
        setId: builtInSetId,
        english:
            'Not only did he finish his homework, but he also helped others.',
        chinese: '他不仅完成了自己的作业，还帮助了别人。',
        extraWords: [
          'Not',
          'only',
          'did',
          'he',
          'finish',
          'his',
          'homework',
          'but',
          'he',
          'also',
          'helped',
          'others',
          'started',
        ],
      ),
      Sentence(
        id: 'b_24',
        setId: builtInSetId,
        english: 'I prefer tea to coffee because it is healthier.',
        chinese: '比起咖啡我更喜欢茶，因为它更健康。',
        extraWords: [
          'I',
          'prefer',
          'tea',
          'to',
          'coffee',
          'because',
          'it',
          'is',
          'healthier',
          'juice',
          'tastier',
        ],
      ),
      Sentence(
        id: 'b_25',
        setId: builtInSetId,
        english: 'By the time we arrived, the meeting had already started.',
        chinese: '我们到达的时候，会议已经开始了。',
        extraWords: [
          'By',
          'the',
          'time',
          'we',
          'arrived',
          'the',
          'meeting',
          'had',
          'already',
          'started',
          'left',
          'ended',
        ],
      ),
    ];
  }

  static SentenceSet _builtInSet() {
    return SentenceSet(
      id: builtInSetId,
      name: '核心基础句式',
      description: '25 句涵盖日常交流核心句型，适合入门练习',
      sentenceCount: 25,
      isBuiltin: true,
      createdAt: DateTime(2024, 1, 1),
    );
  }

  // ===== 加载 =====
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();

    // 读取句式集列表
    final jsonStr = prefs.getString(_prefsSetsKey);
    if (jsonStr != null) {
      try {
        final list = jsonDecode(jsonStr) as List<dynamic>;
        _sets = list
            .map((e) => SentenceSet.fromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        _sets = [];
      }
    }

    // 确保内置句式集存在
    if (!_sets.any((s) => s.id == builtInSetId)) {
      _sets.add(_builtInSet());
      await _saveSets();
    }

    // 确保内置句式集的句子已保存
    final builtInSentencesKey = _prefsSentencesPrefix + builtInSetId;
    final existingStr = prefs.getString(builtInSentencesKey);
    if (existingStr == null || existingStr.isEmpty) {
      await _saveSentences(builtInSetId, _builtInSentences());
    }

    _loaded = true;
    notifyListeners();
  }

  // ===== 句式集 CRUD =====
  Future<void> addSet(SentenceSet set) async {
    final s = set.copyWith(id: const Uuid().v4(), createdAt: DateTime.now());
    _sets.add(s);
    await _saveSets();
    // 初始化空的句子列表
    await _saveSentences(s.id!, []);
    notifyListeners();
  }

  Future<void> updateSet(SentenceSet set) async {
    final index = _sets.indexWhere((s) => s.id == set.id);
    if (index == -1) throw Exception('句式集不存在');
    _sets[index] = set;
    await _saveSets();
    notifyListeners();
  }

  Future<void> deleteSet(String id) async {
    if (id == builtInSetId) return; // 不可删除内置集
    _sets.removeWhere((s) => s.id == id);
    await _saveSets();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefsSentencesPrefix + id);
    notifyListeners();
  }

  SentenceSet? getSet(String id) {
    try {
      return _sets.firstWhere((s) => s.id == id);
    } catch (_) {
      return null;
    }
  }

  // ===== 句子 CRUD =====
  Future<List<Sentence>> getSentences(String setId) async {
    if (setId == builtInSetId) {
      return _builtInSentences();
    }

    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_prefsSentencesPrefix + setId);
    if (jsonStr == null) return [];
    try {
      final list = jsonDecode(jsonStr) as List<dynamic>;
      return list
          .map((e) => Sentence.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> addSentence(Sentence sentence) async {
    final id = const Uuid().v4();
    final s = sentence.copyWith(id: id);
    final sentences = await getSentences(s.setId);
    sentences.add(s);
    await _saveSentences(s.setId, sentences);
    await _updateSentenceCount(s.setId);
    notifyListeners();
  }

  Future<void> updateSentence(Sentence sentence) async {
    final sentences = await getSentences(sentence.setId);
    final index = sentences.indexWhere((s) => s.id == sentence.id);
    if (index == -1) throw Exception('句子不存在');
    sentences[index] = sentence;
    await _saveSentences(sentence.setId, sentences);
    notifyListeners();
  }

  Future<void> deleteSentence(String setId, String sentenceId) async {
    final sentences = await getSentences(setId);
    sentences.removeWhere((s) => s.id == sentenceId);
    await _saveSentences(setId, sentences);
    await _updateSentenceCount(setId);
    notifyListeners();
  }

  Future<void> addSentences(String setId, List<Sentence> newSentences) async {
    final sentences = await getSentences(setId);
    for (final s in newSentences) {
      sentences.add(s.copyWith(id: const Uuid().v4()));
    }
    await _saveSentences(setId, sentences);
    await _updateSentenceCount(setId);
    notifyListeners();
  }

  // ===== 内部方法 =====
  Future<void> _saveSets() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = _sets.map((s) => s.toJson()).toList();
    await prefs.setString(_prefsSetsKey, jsonEncode(jsonList));
  }

  Future<void> _saveSentences(String setId, List<Sentence> sentences) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = sentences.map((s) => s.toJson()).toList();
    await prefs.setString(_prefsSentencesPrefix + setId, jsonEncode(jsonList));
  }

  Future<void> _updateSentenceCount(String setId) async {
    final sentences = await getSentences(setId);
    final index = _sets.indexWhere((s) => s.id == setId);
    if (index != -1) {
      _sets[index] = _sets[index].copyWith(sentenceCount: sentences.length);
      await _saveSets();
    }
  }
}
