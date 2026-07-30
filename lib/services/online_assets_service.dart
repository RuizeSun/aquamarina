import 'package:dio/dio.dart';

/// 在线资源库基础地址
const String _baseUrl = 'https://assets.aquamarina.78go.work';

/// 在线资源分类项
class OnlineCategory {
  final String titleZh;
  final String titleEn;
  final String indexUrl;

  OnlineCategory({
    required this.titleZh,
    required this.titleEn,
    required this.indexUrl,
  });
}

/// 在线资源条目（句型集或词书）
class OnlineAssetEntry {
  final String titleZh;
  final String titleEn;
  final String author;
  final String file;

  OnlineAssetEntry({
    required this.titleZh,
    required this.titleEn,
    required this.author,
    required this.file,
  });
}

/// 在线句型集句子数据
class OnlineSentence {
  final String en;
  final String zh;
  final List<String> dw;

  OnlineSentence({required this.en, required this.zh, required this.dw});
}

/// 在线词书/句型集搜索工具
class OnlineAssetsService {
  static final Dio _dio = Dio(BaseOptions(baseUrl: _baseUrl));

  // ===== 根入口 =====
  static Future<Map<String, dynamic>> fetchRoot() async {
    final resp = await _dio.get('/index.json');
    return resp.data as Map<String, dynamic>;
  }

  // ===== 句型集（Corpus） =====
  /// 获取句型集分类列表
  static Future<List<OnlineCategory>> fetchCorpusCategories() async {
    final root = await fetchRoot();
    final corpusPath = root['corpus'] as String;
    final resp = await _dio.get(corpusPath);
    final data = resp.data as Map<String, dynamic>;
    final list = data['categlories'] as List<dynamic>;
    return list.map((e) {
      final title = e['title'] as Map<String, dynamic>;
      return OnlineCategory(
        titleZh: title['zh-CN'] as String,
        titleEn: title['en-US'] as String,
        indexUrl: e['index'] as String,
      );
    }).toList();
  }

  /// 获取某分类下的句型集列表
  static Future<List<OnlineAssetEntry>> fetchCorpusSets(
    OnlineCategory category,
  ) async {
    final resp = await _dio.get(category.indexUrl);
    final list = resp.data as List<dynamic>;
    return list.map((e) {
      final title = e['title'] as Map<String, dynamic>;
      final author = e['author'] as Map<String, dynamic>?;
      return OnlineAssetEntry(
        titleZh: title['zh-CN'] as String,
        titleEn: title['en-US'] as String,
        author: author?['en-US'] as String? ?? '',
        file: e['file'] as String,
      );
    }).toList();
  }

  /// 获取具体的句型数据
  static Future<List<OnlineSentence>> fetchCorpusSentences(
    OnlineCategory category,
    OnlineAssetEntry entry,
  ) async {
    final dir = category.indexUrl.replaceAll('/index.json', '');
    final resp = await _dio.get('$dir/${entry.file}');
    final list = resp.data as List<dynamic>;
    return list.map((e) {
      final item = e as Map<String, dynamic>;
      return OnlineSentence(
        en: item['en'] as String,
        zh: item['zh'] as String,
        dw:
            (item['dw'] as List<dynamic>?)?.map((x) => x as String).toList() ??
            [],
      );
    }).toList();
  }

  // ===== 词书（Wordbook） =====
  /// 获取词书分类列表
  static Future<List<OnlineCategory>> fetchWordbookCategories() async {
    final root = await fetchRoot();
    final wbPath = root['wordbook'] as String;
    final resp = await _dio.get(wbPath);
    final data = resp.data as Map<String, dynamic>;
    final list = data['categlories'] as List<dynamic>;
    return list.map((e) {
      final title = e['title'] as Map<String, dynamic>;
      return OnlineCategory(
        titleZh: title['zh-CN'] as String,
        titleEn: title['en-US'] as String,
        indexUrl: e['index'] as String,
      );
    }).toList();
  }

  /// 获取某分类下的词书列表
  static Future<List<OnlineAssetEntry>> fetchWordbookSets(
    OnlineCategory category,
  ) async {
    final resp = await _dio.get(category.indexUrl);
    final list = resp.data as List<dynamic>;
    return list.map((e) {
      final title = e['title'] as Map<String, dynamic>;
      final author = e['author'] as Map<String, dynamic>?;
      return OnlineAssetEntry(
        titleZh: title['zh-CN'] as String,
        titleEn: title['en-US'] as String,
        author: author?['en-US'] as String? ?? '',
        file: e['file'] as String,
      );
    }).toList();
  }

  /// 获取具体词书数据（单词列表）
  static Future<List<String>> fetchWordbookData(
    OnlineCategory category,
    OnlineAssetEntry entry,
  ) async {
    final dir = category.indexUrl.replaceAll('/index.json', '');
    final resp = await _dio.get('$dir/${entry.file}');
    final list = resp.data as List<dynamic>;
    return list.map((e) => e as String).toList();
  }

  // ===== 搜索功能 =====
  /// 搜索所有句型集
  static Future<List<Map<String, dynamic>>> searchCorpus(String keyword) async {
    final results = <Map<String, dynamic>>[];
    final categories = await fetchCorpusCategories();

    for (final category in categories) {
      final sets = await fetchCorpusSets(category);
      for (final entry in sets) {
        final sentences = await fetchCorpusSentences(category, entry);
        final lowerKeyword = keyword.toLowerCase();
        for (final item in sentences) {
          if (item.en.toLowerCase().contains(lowerKeyword) ||
              item.zh.contains(keyword)) {
            results.add({
              'en': item.en,
              'zh': item.zh,
              'dw': item.dw,
              'source': entry.titleZh,
              'category': category.titleZh,
            });
          }
        }
      }
    }
    return results;
  }

  /// 搜索所有词书
  static Future<List<Map<String, dynamic>>> searchWordbook(
    String keyword,
  ) async {
    final results = <Map<String, dynamic>>[];
    final categories = await fetchWordbookCategories();

    for (final category in categories) {
      final books = await fetchWordbookSets(category);
      for (final entry in books) {
        final words = await fetchWordbookData(category, entry);
        final lowerKeyword = keyword.toLowerCase();
        for (final word in words) {
          if (word.toLowerCase().contains(lowerKeyword)) {
            results.add({
              'word': word,
              'source': entry.titleZh,
              'category': category.titleZh,
            });
          }
        }
      }
    }
    return results;
  }

  /// 统一搜索
  static Future<Map<String, dynamic>> searchAll(String keyword) async {
    final wordbookResults = await searchWordbook(keyword);
    final corpusResults = await searchCorpus(keyword);
    return {
      'keyword': keyword,
      'wordbook': wordbookResults,
      'corpus': corpusResults,
    };
  }
}
