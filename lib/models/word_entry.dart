/// 英语词典 (ECDict) 条目
class WordEntry {
  final int id;
  final String word;
  final String? phonetic;
  final String? definition;
  final String? translation;
  final String? pos;
  final int? collins;
  final int? oxford;
  final String? tag;
  final int? bnc;
  final int? frq;
  final String? exchange;
  final String? detail;
  final String? audio;
  final String? sw;

  WordEntry({
    required this.id,
    required this.word,
    this.phonetic,
    this.definition,
    this.translation,
    this.pos,
    this.collins,
    this.oxford,
    this.tag,
    this.bnc,
    this.frq,
    this.exchange,
    this.detail,
    this.audio,
    this.sw,
  });

  factory WordEntry.fromMap(Map<String, dynamic> map) {
    return WordEntry(
      id: map['id'] as int,
      word: map['word'] as String,
      phonetic: map['phonetic'] as String?,
      definition: map['definition'] as String?,
      translation: map['translation'] as String?,
      pos: map['pos'] as String?,
      collins: map['collins'] as int?,
      oxford: map['oxford'] as int?,
      tag: map['tag'] as String?,
      bnc: map['bnc'] as int?,
      frq: map['frq'] as int?,
      exchange: map['exchange'] as String?,
      detail: map['detail'] as String?,
      audio: map['audio'] as String?,
      sw: map['sw'] as String?,
    );
  }

  String get collinsStars {
    if (collins == null || collins == 0) return '';
    return '★' * collins!;
  }

  List<String> get tags {
    if (tag == null || tag!.isEmpty) return [];
    return tag!.split(' ');
  }

  Map<String, String> get exchangeMap {
    if (exchange == null || exchange!.isEmpty) return {};
    final map = <String, String>{};
    final parts = exchange!.split('/');
    for (final part in parts) {
      final kv = part.split(':');
      if (kv.length == 2) {
        map[kv[0]] = kv[1];
      }
    }
    return map;
  }
}

/// 中英词典 (CEDict) 条目
class CedictEntry {
  final int id;
  final String? traditional;
  final String simplified;
  final String? pinyin;
  final String definitions;

  CedictEntry({
    required this.id,
    required this.simplified,
    this.traditional,
    this.pinyin,
    required this.definitions,
  });

  factory CedictEntry.fromMap(Map<String, dynamic> map) {
    return CedictEntry(
      id: map['id'] as int,
      simplified: map['simplified'] as String,
      traditional: map['traditional'] as String?,
      pinyin: map['pinyin'] as String?,
      definitions: map['definitions'] as String,
    );
  }
}

/// 统一搜索结果项
class SearchResult {
  /// 数据来源: 'ecdict' 或 'cedict'
  final String source;
  final WordEntry? enEntry;
  final CedictEntry? cnEntry;
  final String displayWord;
  final String? displaySubtitle;

  SearchResult.enWord(this.enEntry)
    : source = 'ecdict',
      cnEntry = null,
      displayWord = enEntry!.word,
      displaySubtitle = enEntry.translation;

  SearchResult.cnWord(this.cnEntry)
    : source = 'cedict',
      enEntry = null,
      displayWord = cnEntry!.simplified,
      displaySubtitle = cnEntry.definitions;
}
