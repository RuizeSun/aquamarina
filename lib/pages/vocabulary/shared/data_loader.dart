import '../../../models/word_entry.dart';
import '../../../services/dictionary_service.dart';
import '../../../services/learning_service.dart';

/// 批量加载单词释义，只执行一次 IN 查询。
/// 返回 Map，key 为单词在 words 列表中的索引，value 为释义；
/// 未命中词典的单词对应 null。
Future<Map<int, WordEntry?>> loadEntries({
  required List<String> words,
}) async {
  final cache = <int, WordEntry?>{};
  if (words.isEmpty) return cache;

  // 一次 IN 查询批量取出全部释义，替代逐词 N 条独立 SQL
  final found = await DictionaryService.searchEnExactBatch(words);
  for (int i = 0; i < words.length; i++) {
    cache[i] = found[words[i].trim().toLowerCase()];
  }
  return cache;
}

/// 加载全局干扰项池（从已学单词中随机取 count 个）
/// 优化：一次性批量查询释义，替代逐词 N 条独立 SQL
Future<Map<String, String>> loadDistractorPool({
  required List<String> excludeWords,
  int count = 10,
}) async {
  final pool = <String, String>{};
  try {
    final distractors = await LearningService.getRandomDistractors(
      excludeWords: excludeWords,
      count: count,
    );
    final distractorKeys = distractors.keys.toList();
    if (distractorKeys.isEmpty) return pool;

    final found = await DictionaryService.searchEnExactBatch(distractorKeys);
    for (final w in distractorKeys) {
      final entry = found[w.trim().toLowerCase()];
      if (entry?.translation != null && entry!.translation!.isNotEmpty) {
        pool[w] = entry.translation!;
      }
    }
  } catch (_) {
    // 加载失败不影响正常流程
  }
  return pool;
}
