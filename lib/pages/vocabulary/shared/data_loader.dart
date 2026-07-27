import '../../../models/word_entry.dart';
import '../../../services/dictionary_service.dart';
import '../../../services/learning_service.dart';

/// 并行加载所有单词的释义缓存
Future<Map<int, WordEntry?>> loadEntries({
  required List<String> words,
  DictionaryService Function()? dictionaryService,
}) async {
  final futures = words.asMap().entries.map((e) async {
    final entry = await DictionaryService.searchEnExact(e.value);
    return MapEntry(e.key, entry);
  });
  final results = await Future.wait(futures);
  final cache = <int, WordEntry?>{};
  for (final r in results) {
    cache[r.key] = r.value;
  }
  return cache;
}

/// 加载全局干扰项池（从已学单词中随机取 count 个）
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
    final distractorFutures = distractors.keys.map((w) async {
      final entry = await DictionaryService.searchEnExact(w);
      if (entry?.translation != null && entry!.translation!.isNotEmpty) {
        return MapEntry(w, entry.translation!);
      }
      return MapEntry(w, '');
    });
    final distractorResults = await Future.wait(distractorFutures);
    for (final r in distractorResults) {
      if (r.value.isNotEmpty) {
        pool[r.key] = r.value;
      }
    }
  } catch (_) {
    // 加载失败不影响正常流程
  }
  return pool;
}
