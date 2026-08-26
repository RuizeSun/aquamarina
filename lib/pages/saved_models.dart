import '../models/sentence_note.dart';
import '../models/word_note.dart';

/// 收藏/笔记条目的来源类型
enum SavedType { word, sentence }

/// 排序方式
enum SavedSort { time, alphabet, length }

/// 个人「收藏 / 笔记」页的统一条目（单词或句子）
class SavedEntry {
  final SavedType type;
  final String title;
  final String? subtitle;
  final String? note;
  final DateTime? updatedAt;
  final bool isFavorited;
  final WordNote? wordNote;
  final SentenceNote? sentenceNote;
  final int length;

  SavedEntry({
    required this.type,
    required this.title,
    this.subtitle,
    this.note,
    this.updatedAt,
    required this.isFavorited,
    this.wordNote,
    this.sentenceNote,
    required this.length,
  });

  factory SavedEntry.fromWord(WordNote note, {String? subtitle}) {
    return SavedEntry(
      type: SavedType.word,
      title: note.word,
      subtitle: subtitle,
      note: note.note,
      updatedAt: note.updatedAt,
      isFavorited: note.isFavorited,
      wordNote: note,
      length: note.word.length,
    );
  }

  factory SavedEntry.fromSentence(SentenceNote note) {
    return SavedEntry(
      type: SavedType.sentence,
      title: note.english,
      subtitle: note.chinese,
      note: note.note,
      updatedAt: note.updatedAt,
      isFavorited: note.isFavorited,
      sentenceNote: note,
      length: note.english
          .split(RegExp(r'\s+'))
          .where((w) => w.isNotEmpty)
          .length,
    );
  }
}

/// 按类型筛选（[type] 为 null 表示全部）
List<SavedEntry> filterSavedEntries(
  List<SavedEntry> entries,
  SavedType? type,
) {
  if (type == null) return entries;
  return entries.where((e) => e.type == type).toList();
}

/// 排序
List<SavedEntry> sortSavedEntries(List<SavedEntry> entries, SavedSort sort) {
  final list = List<SavedEntry>.from(entries);
  switch (sort) {
    case SavedSort.time:
      list.sort((a, b) {
        final at = a.updatedAt;
        final bt = b.updatedAt;
        if (at == null && bt == null) return 0;
        if (at == null) return 1;
        if (bt == null) return -1;
        return bt.compareTo(at);
      });
      break;
    case SavedSort.alphabet:
      list.sort(
        (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
      );
      break;
    case SavedSort.length:
      list.sort((a, b) => a.length.compareTo(b.length));
      break;
  }
  return list;
}
