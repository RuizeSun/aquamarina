import '../../../models/word_entry.dart';
import '../../../services/dictionary_service.dart';
import '../../../services/learning_service.dart';

/// 分批次加载单词释义，每批最多并发 5 个请求。
/// 返回 Map<int, WordEntry?>，key 为单词在 words 列表中的索引。
Future<Map<int, WordEntry?>> loadEntries({
  required List<String> words,
  DictionaryService Function()? dictionaryService,
}) async {
  final cache = <int, WordEntry?>{};
  for (int i = 0; i < words.length; i += 5) {
    final end = i + 5 > words.length ? words.length : i + 5;
    final batch = words.sublist(i, end);
    final batchFutures = batch.asMap().entries.map((e) async {
      final entry = await DictionaryService.searchEnExact(e.value);
      return MapEntry(i + e.key, entry);
    });
    final batchResults = await Future.wait(batchFutures);
    for (final r in batchResults) {
      cache[r.key] = r.value;
    }
  }
  return cache;
}

/// 加载全局干扰项池（从已学单词中随机取 count 个）
/// 优化：释义分批按需加载，控制并发数 ≤5
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
    // 干扰项释义也分批加载，控制并发
    final distractorKeys = distractors.keys.toList();
    for (int i = 0; i < distractorKeys.length; i += 5) {
      final end = i + 5 > distractorKeys.length ? distractorKeys.length : i + 5;
      final batch = distractorKeys.sublist(i, end);
      final batchResults = await Future.wait(
        batch.map((w) async {
          final entry = await DictionaryService.searchEnExact(w);
          if (entry?.translation != null && entry!.translation!.isNotEmpty) {
            return MapEntry(w, entry.translation!);
          }
          return MapEntry(w, '');
        }),
      );
      for (final r in batchResults) {
        if (r.value.isNotEmpty) {
          pool[r.key] = r.value;
        }
      }
    }
  } catch (_) {
    // 加载失败不影响正常流程
  }
  return pool;
}
