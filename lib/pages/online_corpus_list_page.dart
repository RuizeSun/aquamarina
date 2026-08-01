import 'package:flutter/material.dart';
import '../models/ai_sentence_set.dart';
import '../models/ai_sentence.dart';
import '../services/online_assets_service.dart';
import '../services/ai_sentence_set_service.dart';

class OnlineCorpusListPage extends StatefulWidget {
  const OnlineCorpusListPage({super.key});

  @override
  State<OnlineCorpusListPage> createState() => _OnlineCorpusListPageState();
}

class _OnlineCorpusListPageState extends State<OnlineCorpusListPage> {
  final SentenceSetService _setService = SentenceSetService.instance;
  List<OnlineCategory> _categories = [];
  bool _isLoadingCategories = true;
  String? _error;

  // 二级页面状态
  OnlineCategory? _selectedCategory;
  List<OnlineAssetEntry> _sets = [];
  bool _isLoadingSets = false;

  // 三级页面状态
  OnlineAssetEntry? _selectedSet;
  List<OnlineSentence> _sentences = [];
  bool _isLoadingSentences = false;
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _loadCategories();
    _setService.load();
  }

  Future<void> _loadCategories() async {
    setState(() {
      _isLoadingCategories = true;
      _error = null;
    });
    try {
      final categories = await OnlineAssetsService.fetchCorpusCategories();
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

  Future<void> _loadSets(OnlineCategory category) async {
    setState(() {
      _selectedCategory = category;
      _isLoadingSets = true;
      _selectedSet = null;
      _sentences = [];
    });
    try {
      final sets = await OnlineAssetsService.fetchCorpusSets(category);
      if (mounted) {
        setState(() {
          _sets = sets;
          _isLoadingSets = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载失败: $e')));
        setState(() => _isLoadingSets = false);
      }
    }
  }

  Future<void> _previewSet(OnlineAssetEntry entry) async {
    if (_selectedCategory == null) return;
    setState(() {
      _selectedSet = entry;
      _isLoadingSentences = true;
    });
    try {
      final sentences = await OnlineAssetsService.fetchCorpusSentences(
        _selectedCategory!,
        entry,
      );
      if (mounted) {
        setState(() {
          _sentences = sentences;
          _isLoadingSentences = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('加载失败: $e')));
        setState(() => _isLoadingSentences = false);
      }
    }
  }

  Future<void> _importSet() async {
    if (_selectedCategory == null || _selectedSet == null) return;
    setState(() => _isImporting = true);

    try {
      // 1. 创建句式集（名称冲突时自动加序号，类似 Windows 重命名）
      final setName = _setService.generateUniqueSetName(_selectedSet!.titleZh);
      final newSet = SentenceSet(
        name: setName,
        description: _selectedSet!.titleEn,
      );
      await _setService.addSet(newSet);

      // 等待 set 获得 id
      await _setService.load();
      final addedSet = _setService.sets.last;

      // 2. 转换并添加句子
      final sentenceModels = _sentences.map((s) {
        return Sentence(
          setId: addedSet.id!,
          english: s.en,
          chinese: s.zh,
          extraWords: s.dw,
        );
      }).toList();

      if (sentenceModels.isNotEmpty) {
        await _setService.addSentences(addedSet.id!, sentenceModels);
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已成功导入句式集 "$setName"（${sentenceModels.length} 句）'),
          ),
        );
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
          _selectedSet != null
              ? _selectedSet!.titleZh
              : _selectedCategory != null
              ? _selectedCategory!.titleZh
              : '在线句型集',
        ),
        actions: [
          if (_selectedCategory != null)
            TextButton(
              onPressed: () {
                setState(() {
                  _selectedCategory = null;
                  _selectedSet = null;
                  _sentences = [];
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

    // 三级：预览句子
    if (_selectedSet != null) {
      return _buildSentencePreview(theme, colorScheme);
    }

    // 二级：句型集列表
    if (_selectedCategory != null) {
      return _buildSetList(theme, colorScheme);
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
              onTap: () => _loadSets(cat),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSetList(ThemeData theme, ColorScheme colorScheme) {
    if (_isLoadingSets) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_sets.isEmpty) {
      return Center(child: Text('该分类下暂无句型集', style: theme.textTheme.bodyLarge));
    }

    return RefreshIndicator(
      onRefresh: () => _loadSets(_selectedCategory!),
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _sets.length,
        itemBuilder: (context, index) {
          final entry = _sets[index];
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
                child: Icon(
                  Icons.format_quote,
                  color: colorScheme.onSecondaryContainer,
                ),
              ),
              title: Text(entry.titleZh),
              subtitle: Text(entry.titleEn),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _previewSet(entry),
            ),
          );
        },
      ),
    );
  }

  Widget _buildSentencePreview(ThemeData theme, ColorScheme colorScheme) {
    if (_isLoadingSentences) {
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
              onPressed: _isImporting ? null : _importSet,
              icon: _isImporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download_rounded),
              label: Text(
                _isImporting ? '正在导入...' : '导入此句型集（${_sentences.length} 句）',
              ),
            ),
          ),
        ),
        const Divider(height: 1),

        // 句子预览列表
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: _sentences.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, index) {
              final s = _sentences[index];
              return ListTile(
                title: Text(s.en, style: theme.textTheme.bodyMedium),
                subtitle: Text(
                  s.zh,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
