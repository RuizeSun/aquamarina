import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../models/word_book.dart';
import '../../services/word_book_service.dart';
import 'word_book_create_page.dart';
import 'online_wordbook_list_page.dart';

class WordBookListPage extends StatefulWidget {
  final int? currentBookId;
  final ValueChanged<WordBook>? onBookSelected;

  const WordBookListPage({super.key, this.currentBookId, this.onBookSelected});

  @override
  State<WordBookListPage> createState() => _WordBookListPageState();
}

class _WordBookListPageState extends State<WordBookListPage> {
  static const XTypeGroup _jsonTypeGroup = XTypeGroup(
    label: 'JSON',
    extensions: ['json'],
  );

  List<WordBook> _books = [];
  bool _isLoading = true;
  int? _currentBookId;
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _currentBookId = widget.currentBookId;
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    setState(() => _isLoading = true);
    final books = await WordBookService.getAllBooks();
    if (mounted) {
      setState(() {
        _books = books;
        _isLoading = false;
      });
    }
  }

  /// 导出单本词书为 JSON 文件
  Future<void> _exportBook(WordBook book) async {
    if (book.id == null) return;

    final String jsonStr;
    try {
      jsonStr = await WordBookService.exportBookToJson(book.id!);
    } catch (e) {
      if (mounted) {
        _showSnackBar(context, '导出失败：$e', isSuccess: false);
      }
      return;
    }

    final safeTitle = book.title
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .trim();
    final fileName = '${safeTitle.isEmpty ? 'wordbook' : safeTitle}.json';

    if (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS) {
      // 手机端：保存到临时目录后调用系统分享面板
      try {
        final tmpDir = await getTemporaryDirectory();
        final tmpPath = p.join(tmpDir.path, fileName);
        final tmpFile = await File(tmpPath).writeAsString(jsonStr, flush: true);
        if (!mounted) return;

        final result = await SharePlus.instance.share(
          ShareParams(
            files: [XFile(tmpPath, mimeType: 'application/json')],
            subject: fileName,
          ),
        );
        if (!mounted) return;

        if (result.status == ShareResultStatus.success ||
            result.status == ShareResultStatus.dismissed) {
          _showSnackBar(context, '已导出 "${book.title}"', isSuccess: true);
        }
        // 清理临时文件
        if (await tmpFile.exists()) {
          await tmpFile.delete();
        }
      } catch (e) {
        if (mounted) {
          _showSnackBar(context, '导出失败：$e', isSuccess: false);
        }
      }
    } else {
      // 桌面端：使用系统文件保存对话框
      FileSaveLocation? saveLocation;
      try {
        saveLocation = await getSaveLocation(
          suggestedName: fileName,
          acceptedTypeGroups: const [_jsonTypeGroup],
        );
      } catch (_) {
        if (mounted) {
          _showSnackBar(context, '无法打开文件保存对话框', isSuccess: false);
        }
        return;
      }
      if (saveLocation == null) return; // 用户取消

      try {
        await File(saveLocation.path).writeAsString(jsonStr, flush: true);
        if (mounted) {
          _showSnackBar(
            context,
            '已导出到：\n${saveLocation.path}',
            isSuccess: true,
          );
        }
      } catch (e) {
        if (mounted) {
          _showSnackBar(context, '保存失败：$e', isSuccess: false);
        }
      }
    }
  }

  /// 从 JSON 文件导入单本词书
  Future<void> _importBook() async {
    final XFile? file;
    try {
      file = await openFile(acceptedTypeGroups: const [_jsonTypeGroup]);
    } catch (_) {
      if (mounted) {
        _showSnackBar(context, '无法打开文件选择器', isSuccess: false);
      }
      return;
    }
    if (file == null) return; // 用户取消

    setState(() => _isImporting = true);
    try {
      final jsonStr = await file.readAsString();
      final bookId = await WordBookService.importBookFromJson(jsonStr);
      final book = await WordBookService.getBookById(bookId);
      if (!mounted) return;
      _showSnackBar(context, '已导入词书 "${book?.title ?? ''}"', isSuccess: true);
      await _loadBooks();
    } catch (e) {
      if (mounted) {
        _showSnackBar(context, '导入失败：$e', isSuccess: false);
      }
    } finally {
      if (mounted) {
        setState(() => _isImporting = false);
      }
    }
  }

  void _showSnackBar(
    BuildContext context,
    String message, {
    required bool isSuccess,
  }) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isSuccess ? Colors.green : Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _deleteBook(WordBook book) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除词书 "${book.title}" 吗？\n此操作不可撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirm == true && book.id != null) {
      await WordBookService.deleteBook(book.id!);
      await _loadBooks();

      // 如果删除的是当前选中词书，自动选择剩余的第一本；若没有剩余则清空
      if (book.id == _currentBookId) {
        if (_books.isNotEmpty) {
          setState(() => _currentBookId = _books.first.id);
          widget.onBookSelected?.call(_books.first);
        } else {
          setState(() => _currentBookId = null);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('词书管理'),
        actions: [
          // 导入词书按钮
          IconButton(
            icon: _isImporting
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.file_open_outlined),
            tooltip: '导入词书',
            onPressed: _isImporting ? null : _importBook,
          ),
          if (widget.onBookSelected != null)
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _books.isEmpty
          ? _buildEmptyState(theme, colorScheme)
          : _buildBookList(),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.small(
            heroTag: 'online',
            onPressed: () async {
              final result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => const OnlineWordbookListPage(),
                ),
              );
              if (result == true) _loadBooks();
            },
            child: const Icon(Icons.cloud_download_outlined),
          ),
          const SizedBox(height: 12),
          FloatingActionButton(
            heroTag: 'create',
            onPressed: () async {
              final result = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => const WordBookCreatePage()),
              );
              if (result == true) _loadBooks();
            },
            child: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.menu_book_rounded,
              size: 80,
              color: colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '还没有词书',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '点击右下角 "+" 创建或从在线资源库中添加',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBookList() {
    return RefreshIndicator(
      onRefresh: _loadBooks,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 80),
        itemCount: _books.length,
        itemBuilder: (context, index) => _buildBookCard(_books[index]),
      ),
    );
  }

  Widget _buildBookCard(WordBook book) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isSelected = book.id == _currentBookId;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          if (widget.onBookSelected != null) {
            widget.onBookSelected!(book);
            Navigator.of(context).pop();
          }
        },
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // 封面色块
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: Color(book.coverColor ?? 0xFF00BFA5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.menu_book, color: Colors.white),
              ),
              const SizedBox(width: 16),

              // 词书信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (book.description != null &&
                        book.description!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          book.description!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.abc,
                            size: 14,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '${book.wordCount} 词',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (book.author != null &&
                              book.author!.isNotEmpty) ...[
                            const SizedBox(width: 12),
                            Icon(
                              Icons.person,
                              size: 14,
                              color: colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              book.author!,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // 选中标记
              if (isSelected)
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Icon(
                    Icons.check_circle,
                    color: colorScheme.primary,
                    size: 20,
                  ),
                ),
              // 导出按钮（所有词书都显示）
              IconButton(
                icon: const Icon(Icons.ios_share),
                tooltip: '导出词书',
                onPressed: () => _exportBook(book),
              ),
              // 编辑按钮（所有词书都显示）
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                onPressed: () async {
                  final result = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => WordBookCreatePage(existingBook: book),
                    ),
                  );
                  if (result == true) _loadBooks();
                },
              ),
              // 删除按钮
              IconButton(
                icon: Icon(Icons.delete_outline, color: colorScheme.error),
                onPressed: () => _deleteBook(book),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
