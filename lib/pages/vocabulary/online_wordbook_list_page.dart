import 'package:flutter/material.dart';
import '../../models/word_book.dart';
import '../../services/online_assets_service.dart';
import '../../services/word_book_service.dart';
import '../../services/dictionary_service.dart';

class OnlineWordbookListPage extends StatefulWidget {
  const OnlineWordbookListPage({super.key});

  @override
  State<OnlineWordbookListPage> createState() => _OnlineWordbookListPageState();
}

class _OnlineWordbookListPageState extends State<OnlineWordbookListPage> {
  List<OnlineCategory> _categories = [];
  bool _isLoadingCategories = true;
  String? _error;

  // 二级页面状态
  OnlineCategory? _selectedCategory;
  List<OnlineAssetEntry> _books = [];
  bool _isLoadingBooks = false;

  // 三级页面状态
  OnlineAssetEntry? _selectedBook;
  List<String> _words = [];
  bool _isLoadingWords = false;
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _loadCategories();
  }

  Future<void> _loadCategories() async {
    setState(() {
      _isLoadingCategories = true;
      _error = null;
    });
    try {
      final categories = await OnlineAssetsService.fetchWordbookCategories();
      if (mounted) {
        setState(() {
          _categories = categories;
          _isLoadingCategories = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '加载失败: $e';
          _isLoadingCategories = false;
        });
      }
    }
  }

  Future<void> _loadBooks(OnlineCategory category) async {
    setState(() {
      _selectedCategory = category;
      _isLoadingBooks = true;
      _selectedBook = null;
      _words = [];
    });
    try {
      final books = await OnlineAssetsService.fetchWordbookSets(category);
      if (mounted) {
        setState(() {
          _books = books;
          _isLoadingBooks = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载失败: $e')));
        setState(() => _isLoadingBooks = false);
      }
    }
  }

  Future<void> _previewBook(OnlineAssetEntry entry) async {
    if (_selectedCategory == null) return;
    setState(() {
      _selectedBook = entry;
      _isLoadingWords = true;
    });
    try {
      final words = await OnlineAssetsService.fetchWordbookData(
        _selectedCategory!,
        entry,
      );
      if (mounted) {
        setState(() {
          _words = words;
          _isLoadingWords = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载失败: $e')));
        setState(() => _isLoadingWords = false);
      }
    }
  }

  Future<void> _importBook() async {
    if (_selectedCategory == null || _selectedBook == null) return;
    setState(() => _isImporting = true);

    try {
      // 1. 批量查询词典，只保留在词典中找到的单词
      final foundMap = await DictionaryService.searchEnExactBatch(_words);
      final validWords = <String>[];
      for (final word in _words) {
        final cleaned = word.trim().toLowerCase();
        if (foundMap.containsKey(cleaned)) {
          validWords.add(cleaned);
        }
      }

      if (validWords.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该词书中所有单词本地词典均无法识别，导入取消')),
          );
        }
        return;
      }

      // 2. 检测已学单词，让用户选择是否过滤
      final filtered = await WordBookService.filterLearnedWords(validWords);
      List<String> wordsToImport;
      if (filtered.learnedWords.isNotEmpty) {
        if (!mounted) return;
        final shouldFilter = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('发现已学单词'),
            content: Text(
              '该词书中有 ${filtered.learnedWords.length} 个单词已学过'
              '（${filtered.newWords.isEmpty ? "全部已学" : "其中 ${filtered.newWords.length} 个未学"}），'
              '是否过滤掉已学单词？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('不过滤'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('过滤'),
              ),
            ],
          ),
        );
        if (shouldFilter == null) return;
        wordsToImport = shouldFilter ? filtered.newWords : validWords;
      } else {
        wordsToImport = validWords;
      }

      if (wordsToImport.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('所有有效单词都已学过，无需导入')));
        }
        return;
      }

      // 3. 创建词书
      final bookName = _selectedBook!.titleZh;
      final book = WordBook(
        title: bookName,
        description: _selectedBook!.titleEn,
        author: _selectedBook!.author.isNotEmpty ? _selectedBook!.author : null,
      );
      final bookId = await WordBookService.createBook(book);

      // 4. 添加单词
      await WordBookService.addWordsToBook(bookId, wordsToImport);

      if (mounted) {
        final skipped = _words.length - wordsToImport.length;
        final parts = <String>['已导入词书 "$bookName"（${wordsToImport.length} 词'];
        if (skipped > 0) {
          parts.add('，$skipped 个已跳过');
        }
        parts.add('）');
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(parts.join())));
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _selectedBook != null
              ? _selectedBook!.titleZh
              : _selectedCategory != null
              ? _selectedCategory!.titleZh
              : '在线词书',
        ),
        actions: [
          if (_selectedCategory != null)
            TextButton(
              onPressed: () {
                setState(() {
                  _selectedCategory = null;
                  _selectedBook = null;
                  _words = [];
                });
              },
              child: const Text('返回分类'),
            ),
        ],
      ),
      body: _buildBody(theme, colorScheme),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme colorScheme) {
    if (_isLoadingCategories) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.cloud_off, size: 64, color: colorScheme.error),
              const SizedBox(height: 16),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadCategories,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    // 三级：预览单词
    if (_selectedBook != null) {
      return _buildWordPreview(theme, colorScheme);
    }

    // 二级：词书列表
    if (_selectedCategory != null) {
      return _buildBookList(theme, colorScheme);
    }

    // 一级：分类列表
    return _buildCategoryList(theme, colorScheme);
  }

  Widget _buildCategoryList(ThemeData theme, ColorScheme colorScheme) {
    return RefreshIndicator(
      onRefresh: _loadCategories,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _categories.length,
        itemBuilder: (context, index) {
          final cat = _categories[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.category_rounded,
                  color: colorScheme.onPrimaryContainer,
                ),
              ),
              title: Text(cat.titleZh),
              subtitle: Text(cat.titleEn),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _loadBooks(cat),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBookList(ThemeData theme, ColorScheme colorScheme) {
    if (_isLoadingBooks) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_books.isEmpty) {
      return Center(child: Text('该分类下暂无词书', style: theme.textTheme.bodyLarge));
    }

    return RefreshIndicator(
      onRefresh: () => _loadBooks(_selectedCategory!),
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _books.length,
        itemBuilder: (context, index) {
          final entry = _books[index];
          return Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.menu_book, color: Colors.white),
              ),
              title: Text(entry.titleZh),
              subtitle: Text(entry.titleEn),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _previewBook(entry),
            ),
          );
        },
      ),
    );
  }

  Widget _buildWordPreview(ThemeData theme, ColorScheme colorScheme) {
    if (_isLoadingWords) {
      return const Center(child: CircularProgressIndicator());
    }

    return Column(
      children: [
        // 导入按钮
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: FilledButton.icon(
              onPressed: _isImporting ? null : _importBook,
              icon: _isImporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded),
              label: Text(
                _isImporting ? '正在导入...' : '导入此词书（${_words.length} 词）',
              ),
            ),
          ),
        ),
        const Divider(height: 1),

        // 单词预览列表
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _words.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, index) {
              return ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 14,
                  backgroundColor: colorScheme.surfaceContainerHighest,
                  child: Text(
                    '${index + 1}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                title: Text(_words[index]),
              );
            },
          ),
        ),
      ],
    );
  }
}
