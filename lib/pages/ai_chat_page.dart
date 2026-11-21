import 'dart:async';

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/ai_chat.dart';
import '../models/ai_context.dart';
import '../services/ai/ai_chat_controller.dart';
import '../services/ai/ai_chat_export.dart';
import '../services/ai/ai_chat_prompt_suggestions.dart';
import '../services/ai/ai_chat_service.dart';
import '../services/ai/ai_chat_settings.dart';
import '../services/ai/ai_image_service.dart';
import '../services/ai/ai_profile_service.dart';
import '../services/ai/ai_token_estimator.dart';
import '../services/ai/tools/ai_tool_registry.dart';
import '../services/ai/tools/app_tools.dart';
import '../services/ai/tools/tool_approval.dart';
import '../widgets/chat/attachment_image.dart';
import '../widgets/chat/chat_labels.dart';
import '../widgets/chat/context_note_card.dart';
import '../widgets/chat/message_usage_badge.dart';
import '../widgets/chat/thinking_section.dart';
import '../widgets/chat/tool_approval_sheet.dart';
import '../widgets/chat/tool_call_card.dart';
import 'settings/settings_page.dart';
import 'settings/sections/ai_chat_section.dart';

/// AI 对话 Tab。
///
/// 布局：宽屏（≥900dp）左侧会话列表 + 右侧对话区；窄屏对话区 + 抽屉式列表。
class AiChatPage extends StatefulWidget {
  const AiChatPage({
    super.key,
    this.controller,
    this.chatService,
    this.profileService,
  });

  /// 测试可注入自定义 controller。
  final AiChatController? controller;

  /// 测试可注入自定义持久化服务。
  final AiChatService? chatService;

  /// 测试可注入自定义配置服务。
  final AiProfileService? profileService;

  @override
  State<AiChatPage> createState() => AiChatPageState();
}

class AiChatPageState extends State<AiChatPage> {
  static const double _wideBreakpoint = 900;
  static const double _sidebarWidth = 280;

  late final AiChatController _controller;
  late final AiChatService _chatService =
      widget.chatService ?? AiChatService.instance;
  late final AiProfileService _profileService =
      widget.profileService ?? AiProfileService();
  final AiChatSettings _settings = AiChatSettings();

  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  /// 待发送的图片附件。
  final List<AiChatAttachment> _pendingAttachments = [];

  /// 当前对话配置是否声明支持图片输入（决定是否允许添加图片）。
  bool _visionEnabled = false;

  List<AiChatSession> _sessions = const [];
  bool _loadingSessions = true;
  String? _setupHint;

  /// 会话搜索框。
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  String _searchQuery = '';
  List<AiChatSearchHit> _searchHits = const [];
  bool _searching = false;

  /// 是否在消息下方显示 token / 费用角标（设置项，默认开启）。
  bool _showUsage = true;

  /// 空态展示的预设提问，进入页面时抽一批，「换一批」时重抽。
  List<String> _suggestions = AiChatPromptSuggestions.pick();

  @override
  void initState() {
    super.initState();
    _controller =
        widget.controller ??
        AiChatController(
          toolRegistry: AiToolRegistry(AppTools.build()),
          approvalHandler: _requestApproval,
        );
    _controller.addListener(_onControllerChanged);
    _load();
    _loadUsageBadgeSetting();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    if (widget.controller == null) {
      _controller.dispose();
    }
    _searchDebounce?.cancel();
    _inputController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// 供 MainShell 切 Tab 时刷新会话列表。
  Future<void> refresh() => _load();

  Future<void> _load() async {
    final sessions = await _chatService.listSessions();
    if (!mounted) return;

    // 首次进入自动打开最近一个会话，没有则保持空态
    if (_controller.session == null && sessions.isNotEmpty) {
      await _controller.openSession(sessions.first);
    }

    await _checkProfile();

    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _loadingSessions = false;
    });
  }

  /// 检查是否已有可用于对话的 AI 配置。
  ///
  /// 任何插件不可用的场景（如测试环境）都只记日志并跳过提示，不影响对话本身。
  Future<void> _checkProfile() async {
    String? hint;
    var vision = false;
    try {
      await _profileService.load();
      final settings = AiChatSettings();
      final id = await settings.getProfileId();
      final profile = id == null
          ? _profileService.defaultProfile
          : _profileService.getProfile(id);
      vision = profile?.enableVision ?? false;
      if (profile == null) {
        hint = '还没有可用的 AI 配置，请先在设置中添加 OpenAI 兼容或 DeepSeek 配置。';
      } else if (profile.isAquamarina) {
        hint = 'Aquamarina 官方配置不支持通用对话，请在「AI 对话设置」中选择其它配置。';
      } else if (profile.apiKey.isEmpty) {
        hint = '当前 AI 配置缺少 API Key，请在设置中补全。';
      }
    } catch (_) {
      hint = null;
    }
    if (!mounted) return;
    setState(() {
      _setupHint = hint;
      _visionEnabled = vision;
      if (!vision) _pendingAttachments.clear();
    });
  }

  void _onControllerChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleScrollToBottom();
  }

  void _scheduleScrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  /// 工具批准回调：弹出批准面板。
  Future<AiToolApprovalDecision> _requestApproval(
    AiToolCall call,
    dynamic tool,
  ) async {
    if (!mounted) return AiToolApprovalDecision.denied;
    final decision = await showToolApprovalSheet(
      context,
      call: call,
      tool: tool,
    );
    return decision ?? AiToolApprovalDecision.denied;
  }

  // ── 操作 ──────────────────────────────────────────

  Future<void> _newSession() async {
    final isNarrow = MediaQuery.sizeOf(context).width < _wideBreakpoint;
    await _controller.createSession();
    _reloadSessions();
    if (isNarrow && mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _selectSession(AiChatSession session) async {
    final isNarrow = MediaQuery.sizeOf(context).width < _wideBreakpoint;
    await _controller.openSession(session);
    if (isNarrow && mounted) {
      Navigator.of(context).maybePop();
    }
  }

  Future<void> _reloadSessions() async {
    final sessions = await _chatService.listSessions();
    if (!mounted) return;
    setState(() => _sessions = sessions);
  }

  Future<void> _renameCurrent() async {
    final session = _controller.session;
    if (session == null) return;
    final controller = TextEditingController(text: session.title);
    final title = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重命名对话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: AiChatService.titleMaxChars,
          decoration: const InputDecoration(hintText: '会话标题'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || title.isEmpty) return;
    await _chatService.renameSession(session.id, title);
    await _controller.openSession(
      (await _chatService.getSession(session.id)) ?? session,
    );
    _reloadSessions();
  }

  Future<void> _deleteSession(AiChatSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除对话'),
        content: Text('确定删除「${session.title}」吗？该对话会从所有已同步设备中删除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _controller.deleteSession(session.id);
    _reloadSessions();
  }

  Future<void> _clearCurrent() async {
    final session = _controller.session;
    if (session == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('清空当前对话'),
        content: const Text('将删除本会话的全部消息，且会同步到其它设备。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _controller.clearCurrentSession();
    _reloadSessions();
  }

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SettingsCategoryPage(
          category: SettingsCategory(
            title: 'AI 对话',
            icon: Icons.chat_bubble_outline,
            builder: () => Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: const [AiChatSection()],
            ),
          ),
        ),
      ),
    );
    await _checkProfile();
    await _loadUsageBadgeSetting();
  }

  /// 读取「显示 token / 费用角标」开关。
  Future<void> _loadUsageBadgeSetting() async {
    final enabled = await _settings.getShowUsageBadge();
    if (!mounted) return;
    setState(() => _showUsage = enabled);
  }

  // ── 会话搜索 ──────────────────────────────────────

  void _onSearchChanged(String value) {
    _searchDebounce?.cancel();
    final query = value.trim();
    setState(() {
      _searchQuery = query;
      if (query.isEmpty) {
        _searchHits = const [];
        _searching = false;
      }
    });
    if (query.isEmpty) return;
    _searchDebounce = Timer(
      const Duration(milliseconds: 250),
      () => _runSearch(query),
    );
  }

  Future<void> _runSearch(String query) async {
    if (!mounted) return;
    setState(() => _searching = true);
    final hits = await _chatService.searchSessions(query);
    if (!mounted || _searchQuery != query) return;
    setState(() {
      _searchHits = hits;
      _searching = false;
    });
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    setState(() {
      _searchQuery = '';
      _searchHits = const [];
      _searching = false;
    });
  }

  // ── 导出 ──────────────────────────────────────────

  Future<void> _exportCurrentSession() async {
    final session = _controller.session;
    final messages = _controller.messages;
    if (session == null || messages.isEmpty) {
      _showSnack('当前对话还没有可导出的内容');
      return;
    }

    final format = await showDialog<_ChatExportFormat>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('导出对话'),
        children: [
          SimpleDialogOption(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_ChatExportFormat.markdown),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.description_outlined),
              title: Text('Markdown'),
              subtitle: Text('便于阅读、粘贴与分享'),
            ),
          ),
          SimpleDialogOption(
            onPressed: () =>
                Navigator.of(dialogContext).pop(_ChatExportFormat.json),
            child: const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.data_object),
              title: Text('JSON'),
              subtitle: Text('结构化备份，包含工具调用与用量'),
            ),
          ),
        ],
      ),
    );
    if (format == null || !mounted) return;

    final isMarkdown = format == _ChatExportFormat.markdown;
    final content = isMarkdown
        ? AiChatExport.toMarkdown(
            session: session,
            messages: messages,
            includeUsage: _showUsage,
          )
        : AiChatExport.toJson(session: session, messages: messages);
    final fileName = AiChatExport.fileNameFor(
      session,
      extension: isMarkdown
          ? AiChatExport.markdownExtension
          : AiChatExport.jsonExtension,
    );
    await _saveTextFile(
      content: content,
      fileName: fileName,
      typeGroup: isMarkdown ? _markdownTypeGroup : _jsonTypeGroup,
    );
  }

  /// 保存/分享文本：手机走系统分享，桌面走保存对话框（与日志、句式集导出一致）。
  Future<void> _saveTextFile({
    required String content,
    required String fileName,
    required XTypeGroup typeGroup,
  }) async {
    final mobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
    if (mobile) {
      try {
        final dir = await getTemporaryDirectory();
        final path = p.join(dir.path, fileName);
        final file = File(path);
        await file.writeAsString(content, flush: true);
        if (!mounted) return;
        final result = await SharePlus.instance.share(
          ShareParams(
            files: [XFile(path, mimeType: typeGroup.mimeTypes?.first)],
            subject: fileName,
          ),
        );
        if (await file.exists()) await file.delete();
        if (!mounted) return;
        if (result.status != ShareResultStatus.unavailable) {
          _showSnack('已导出 $fileName');
        }
      } catch (e) {
        if (mounted) _showSnack('导出失败：$e');
      }
      return;
    }

    FileSaveLocation? location;
    try {
      location = await getSaveLocation(
        suggestedName: fileName,
        acceptedTypeGroups: [typeGroup],
      );
    } catch (_) {
      if (mounted) _showSnack('无法打开文件保存对话框');
      return;
    }
    if (location == null) return; // 用户取消
    try {
      await File(location.path).writeAsString(content, flush: true);
      if (mounted) _showSnack('已导出到：\n${location.path}');
    } catch (e) {
      if (mounted) _showSnack('保存失败：$e');
    }
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  /// 汇总一轮问答里所有模型轮次的用量（工具调用会产生多轮）。
  AiMessageUsage? _aggregateUsage(_ChatTurn turn) {
    final usages = <AiMessageUsage>[
      for (final round in turn.rounds)
        if (round.usage != null) round.usage!,
    ];
    return usages.isEmpty ? null : AiMessageUsage.combine(usages);
  }

  /// 从文件选择器添加图片。
  Future<void> _pickImages() async {
    const typeGroup = XTypeGroup(
      label: '图片',
      extensions: ['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'],
    );
    List<XFile> files;
    try {
      files = await openFiles(acceptedTypeGroups: const [typeGroup]);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('无法打开文件选择器：$e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (files.isEmpty) return;

    final size = await _settings.getImageThumbnailSize();
    var skipped = 0;
    for (final file in files) {
      if (_pendingAttachments.length >=
          AiImageService.maxAttachmentsPerMessage) {
        skipped += 1;
        continue;
      }
      final attachment = await AiImageService.instance.importFile(
        File(file.path),
        thumbnailSize: size,
      );
      if (attachment == null) {
        skipped += 1;
        continue;
      }
      _pendingAttachments.add(attachment);
    }
    if (!mounted) return;
    setState(() {});
    if (skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('有 $skipped 张图片未能添加（超出数量上限或格式不支持）'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// 从剪贴板粘贴图片（桌面端常用）。
  Future<void> _pasteImage() async {
    final bytes = await Pasteboard.image;
    if (bytes == null || bytes.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('剪贴板中没有图片'),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (_pendingAttachments.length >= AiImageService.maxAttachmentsPerMessage) {
      return;
    }
    final size = await _settings.getImageThumbnailSize();
    final attachment = await AiImageService.instance.prepareFromBytesPersisted(
      bytes,
      fileName: 'clipboard.png',
      thumbnailSize: size,
    );
    if (attachment == null || !mounted) return;
    setState(() => _pendingAttachments.add(attachment));
  }

  Future<void> _send() async {
    final text = _inputController.text;
    if (text.trim().isEmpty && _pendingAttachments.isEmpty) return;
    if (_setupHint != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_setupHint!),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final attachments = List<AiChatAttachment>.of(_pendingAttachments);
    _inputController.clear();
    setState(() => _pendingAttachments.clear());
    await _controller.send(text, attachments: attachments);
    _reloadSessions();
    _inputFocus.requestFocus();
    _showImageWarningIfAny();
  }

  // ── 构建 ──────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= _wideBreakpoint;
        if (isWide) {
          return Scaffold(
            appBar: _buildAppBar(context, showDrawerButton: false),
            body: Row(
              children: [
                SizedBox(width: _sidebarWidth, child: _buildSessionList()),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: _buildConversationPane()),
              ],
            ),
          );
        }
        return Scaffold(
          appBar: _buildAppBar(context, showDrawerButton: true),
          endDrawer: Drawer(child: _buildSessionList()),
          body: _buildConversationPane(),
        );
      },
    );
  }

  PreferredSizeWidget _buildAppBar(
    BuildContext context, {
    required bool showDrawerButton,
  }) {
    final session = _controller.session;
    final theme = Theme.of(context);
    return AppBar(
      title: InkWell(
        onTap: session == null ? null : _renameCurrent,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              session?.title ?? 'AI 对话',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleMedium,
            ),
            Text(
              _controller.isBusy ? '正在生成…' : '点击标题可重命名',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          tooltip: '新对话',
          onPressed: _newSession,
          icon: const Icon(Icons.add_comment_outlined),
        ),
        IconButton(
          tooltip: '清空当前对话',
          onPressed: session == null ? null : _clearCurrent,
          icon: const Icon(Icons.cleaning_services_outlined),
        ),
        if (showDrawerButton)
          Builder(
            builder: (ctx) => IconButton(
              tooltip: '会话列表',
              onPressed: () => Scaffold.of(ctx).openEndDrawer(),
              icon: const Icon(Icons.list_alt),
            ),
          ),
        IconButton(
          tooltip: '导出当前对话',
          onPressed: _exportCurrentSession,
          icon: const Icon(Icons.ios_share),
        ),
        IconButton(
          tooltip: 'AI 对话设置',
          onPressed: _openSettings,
          icon: const Icon(Icons.tune),
        ),
      ],
    );
  }

  Widget _buildSessionList() {
    final theme = Theme.of(context);
    if (_loadingSessions) {
      return const Center(child: CircularProgressIndicator());
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Text(
                '会话',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              IconButton(
                tooltip: '新对话',
                onPressed: _newSession,
                icon: const Icon(Icons.add, size: 20),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          child: TextField(
            controller: _searchController,
            onChanged: _onSearchChanged,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              isDense: true,
              hintText: '搜索会话或内容',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _searchQuery.isEmpty
                  ? null
                  : IconButton(
                      tooltip: '清除搜索',
                      icon: const Icon(Icons.close, size: 16),
                      onPressed: _clearSearch,
                    ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 8,
              ),
            ),
          ),
        ),
        Expanded(
          child: _searchQuery.isNotEmpty
              ? _buildSearchResults(theme)
              : _sessions.isEmpty
              ? Center(
                  child: Text(
                    '还没有对话',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _sessions.length,
                  itemBuilder: (context, index) {
                    final session = _sessions[index];
                    final selected = session.id == _controller.session?.id;
                    return ListTile(
                      dense: true,
                      selected: selected,
                      leading: const Icon(Icons.chat_bubble_outline, size: 18),
                      title: Text(
                        session.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        _formatTime(session.updatedAt),
                        style: theme.textTheme.labelSmall,
                      ),
                      trailing: IconButton(
                        tooltip: '删除',
                        icon: const Icon(Icons.delete_outline, size: 18),
                        onPressed: () => _deleteSession(session),
                      ),
                      onTap: () => _selectSession(session),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// 会话搜索结果列表。
  Widget _buildSearchResults(ThemeData theme) {
    if (_searching) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_searchHits.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '没有找到匹配「$_searchQuery」的内容',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }
    return ListView.builder(
      itemCount: _searchHits.length,
      itemBuilder: (context, index) {
        final hit = _searchHits[index];
        final snippet = hit.snippet;
        return ListTile(
          dense: true,
          selected: hit.session.id == _controller.session?.id,
          leading: Icon(
            hit.matchedTitle ? Icons.title : Icons.subject,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          title: Text(
            hit.session.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            snippet == null || snippet.isEmpty ? '标题匹配' : snippet,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall,
          ),
          onTap: () async {
            _clearSearch();
            await _selectSession(hit.session);
          },
        );
      },
    );
  }

  Widget _buildConversationPane() {
    final messages = _controller.messages;
    final turns = _groupIntoTurns(messages);
    return Column(
      children: [
        if (_setupHint != null) _buildSetupBanner(_setupHint!),
        if (_controller.contextUsage?.isWarning ?? false)
          _buildContextUsageBanner(_controller.contextUsage!),
        Expanded(
          child: messages.isEmpty && !_controller.isBusy
              ? _buildEmptyState()
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  itemCount: turns.length + (_controller.isBusy ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= turns.length) {
                      return _buildStreamingBubble();
                    }
                    return _buildTurn(turns[index]);
                  },
                ),
        ),
        _buildInputBar(),
      ],
    );
  }

  /// 把扁平的消息流折叠成「提问 → 回答」。
  ///
  /// 一次提问可能触发多轮「工具调用 → 继续生成」，但界面上只应该是一个回答
  /// 气泡：中间轮次的思维链与工具调用全部收进「思考过程」手风琴，正文按轮次
  /// 顺序拼接，工具结果也不再单独占一行灰条。
  List<_ChatTurn> _groupIntoTurns(List<AiChatMessage> messages) {
    final turns = <_ChatTurn>[];
    _ChatTurn? current;

    for (final message in messages) {
      switch (message.role) {
        case AiChatRole.user:
          current = _ChatTurn(
            user: message,
            contextNote: _controller.contextNoteFor(message.id),
          );
          turns.add(current);
        case AiChatRole.assistant:
          if (current == null) {
            current = _ChatTurn();
            turns.add(current);
          }
          current.rounds.add(message);
          for (final call in message.toolCalls) {
            current.tools.add(
              AiToolCallRecord(
                call: call,
                toolDescription: '',
                isMutating: false,
                state: AiToolCallState.pending,
              ),
            );
          }
        case AiChatRole.tool:
          final owner = current;
          if (owner == null || owner.rounds.isEmpty) {
            // 没有归属的工具消息（如轮数上限提示）单独成一条系统说明
            turns.add(_ChatTurn(notice: message));
            current = null;
            continue;
          }
          final index = owner.tools.indexWhere(
            (record) => record.call.id == message.toolCallId,
          );
          final record = index >= 0
              ? owner.tools[index]
              : (owner.tools.isEmpty ? null : owner.tools.last);
          if (record == null) {
            turns.add(_ChatTurn(notice: message));
            current = null;
            continue;
          }
          final failed = message.status == AiChatMessageStatus.error;
          record.state = failed
              ? (message.errorMessage == 'denied_by_user'
                    ? AiToolCallState.denied
                    : AiToolCallState.failed)
              : AiToolCallState.done;
          record.resultPreview = message.content;
          record.errorCode = failed ? message.errorMessage : null;
        case AiChatRole.system:
          break;
      }
    }
    return turns;
  }

  Widget _buildTurn(_ChatTurn turn) {
    final notice = turn.notice;
    if (notice != null) return _buildSystemNotice(notice);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (turn.user != null) _buildUserBubble(turn.user!),
        if (turn.rounds.isNotEmpty) _buildAnswerBubble(turn),
      ],
    );
  }

  Widget _buildSetupBanner(String hint) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.info_outline, size: 18, color: theme.colorScheme.error),
            const SizedBox(width: 8),
            Expanded(child: Text(hint, style: theme.textTheme.bodySmall)),
            TextButton(onPressed: _openSettings, child: const Text('去设置')),
          ],
        ),
      ),
    );
  }

  Widget _buildContextUsageBanner(AiContextUsage usage) {
    final theme = Theme.of(context);
    final percent = (usage.ratio * 100).round();
    return Material(
      color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          children: [
            Icon(Icons.data_usage, size: 18, color: theme.colorScheme.tertiary),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '本会话历史约 ${AiChatExport.formatTokenCount(usage.usedTokens)} tokens，'
                '已占上下文窗口 $percent%'
                '（${AiChatExport.formatTokenCount(usage.windowTokens)}）',
                style: theme.textTheme.bodySmall,
              ),
            ),
            TextButton(onPressed: _openSettings, child: const Text('调整')),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    final theme = Theme.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.smart_toy_outlined,
              size: 56,
              color: theme.colorScheme.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 12),
            Text('开始一段新对话', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '可以查词、看学习进度，也能在获得你的批准后修改数据',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            for (final prompt in _suggestions)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: OutlinedButton(
                  onPressed: () {
                    _inputController.text = prompt;
                    _send();
                  },
                  child: Text(prompt, textAlign: TextAlign.center),
                ),
              ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () {
                setState(() {
                  _suggestions = AiChatPromptSuggestions.pick();
                });
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('换一批'),
            ),
          ],
        ),
      ),
    );
  }

  /// 用户提问气泡（右侧）。
  Widget _buildUserBubble(AiChatMessage message) {
    final colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (message.hasAttachments)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final attachment in message.attachments)
                      _buildMessageImage(attachment),
                  ],
                ),
              ),
            if (message.content.isNotEmpty) SelectableText(message.content),
            if (_showUsage && message.content.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: MessageUsageBadge(
                  estimateTokens: AiTokenEstimator.estimate(message.content),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// AI 回答气泡（左侧）：思考过程折叠在上，正式回答直接铺开。
  Widget _buildAnswerBubble(_ChatTurn turn) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final content = turn.content;
    final reasoning = turn.reasoning;
    final note = turn.contextNote;
    final status = turn.status;
    final usage = _showUsage ? _aggregateUsage(turn) : null;

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (reasoning.trim().isNotEmpty ||
                turn.tools.isNotEmpty ||
                note != null)
              ThinkingSection(
                reasoning: reasoning,
                summary: _thinkingSummary(turn),
                statusText: status == AiChatMessageStatus.cancelled
                    ? '已停止'
                    : '',
                children: [
                  if (note != null)
                    ContextNoteCard(
                      note: note,
                      tags: AiChatController.contextTagsOf(note),
                    ),
                  for (final record in turn.tools) ToolCallCard(record: record),
                ],
              ),
            if (content.isNotEmpty)
              SelectionArea(
                child: GptMarkdown(
                  content,
                  style: theme.textTheme.bodyMedium,
                  onLinkTap: (url, _) => _openLink(url),
                ),
              ),
            if (status == AiChatMessageStatus.error)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  children: [
                    Icon(
                      Icons.error_outline,
                      size: 16,
                      color: colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        turn.errorMessage ?? '生成失败',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.error,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: _controller.retryLast,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            if (status == AiChatMessageStatus.cancelled)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '已停止生成',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            if (usage != null)
              Align(
                alignment: Alignment.centerRight,
                child: MessageUsageBadge(usage: usage),
              ),
          ],
        ),
      ),
    );
  }

  /// 没有归属的系统说明（轮数上限、未知工具等）。
  Widget _buildSystemNotice(AiChatMessage message) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final name = message.toolName ?? '';
    final prefix = name.isEmpty || name == 'system'
        ? ''
        : '${ChatLabels.tool(name)}：';
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: colorScheme.outlineVariant),
        ),
        child: Text(
          '$prefix${_shorten(message.content, 200)}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 折叠行摘要：用了哪些工具、最后一步的状态。
  String _thinkingSummary(_ChatTurn turn) {
    if (turn.tools.isEmpty) return '';
    final names = <String>[];
    for (final record in turn.tools) {
      final label = ChatLabels.tool(record.call.name);
      if (!names.contains(label)) names.add(label);
    }
    final joined = names.length <= 2
        ? names.join(' · ')
        : '${names.take(2).join(' · ')} 等 ${names.length} 项';
    final state = switch (turn.tools.last.state) {
      AiToolCallState.pending => '等待批准',
      AiToolCallState.approved => '执行中',
      AiToolCallState.denied => '已被拒绝',
      AiToolCallState.done => '已执行',
      AiToolCallState.failed => '执行失败',
    };
    return '$joined · $state';
  }

  /// 消息中的图片：本机有原图时显示原图，跨设备只显示同步过来的缩略图。
  Widget _buildMessageImage(AiChatAttachment attachment) {
    final theme = Theme.of(context);
    final provider = myAttachmentProvider(attachment);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 160,
        height: 160,
        color: theme.colorScheme.surfaceContainerHighest,
        child: provider == null
            ? Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : Image(
                image: provider,
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => Center(
                  child: Icon(
                    Icons.broken_image_outlined,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildStreamingBubble() {
    final theme = Theme.of(context);
    final text = _controller.streamingText;
    final reasoning = _controller.streamingReasoning;
    final active = _controller.activeToolCalls;

    final statusText = switch (_controller.state) {
      AiChatStreamState.awaitingApproval => '等待你批准',
      AiChatStreamState.waitingTool => '正在执行工具',
      AiChatStreamState.compressing => '正在压缩上下文',
      _ => '',
    };

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 720),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: 0.45,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (reasoning.isNotEmpty || active.isNotEmpty)
              ThinkingSection(
                reasoning: reasoning,
                summary: active.isEmpty
                    ? ''
                    : ChatLabels.tool(active.last.call.name),
                statusText: statusText,
                initiallyExpanded:
                    _controller.state == AiChatStreamState.awaitingApproval ||
                    _controller.state == AiChatStreamState.waitingTool,
                children: [
                  for (final record in active) ToolCallCard(record: record),
                ],
              ),
            if (statusText.isNotEmpty && active.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  switch (_controller.state) {
                    AiChatStreamState.awaitingApproval => '等待你批准工具调用…',
                    AiChatStreamState.compressing => '正在压缩上下文…',
                    _ => '正在执行工具…',
                  },
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
            if (text.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text('正在生成…', style: theme.textTheme.bodySmall),
                  ],
                ),
              )
            else
              SelectionArea(
                child: GptMarkdown(
                  text,
                  style: theme.textTheme.bodyMedium,
                  onLinkTap: (url, _) => _openLink(url),
                ),
              ),
            if (_showUsage && text.isNotEmpty)
              Align(
                alignment: Alignment.centerRight,
                child: MessageUsageBadge(
                  estimateTokens: AiTokenEstimator.estimate(text),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    final theme = Theme.of(context);
    final busy = _controller.isBusy;
    return Material(
      elevation: 3,
      color: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_pendingAttachments.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  height: 72,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: _pendingAttachments.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 8),
                    itemBuilder: (context, index) => _buildPendingThumbnail(
                      _pendingAttachments[index],
                      index,
                    ),
                  ),
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: _visionEnabled ? '添加图片' : '当前 AI 配置未开启图片输入',
                  onPressed: busy || !_visionEnabled ? null : _pickImages,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                ),
                IconButton(
                  tooltip: _visionEnabled
                      ? '粘贴图片（Ctrl+Shift+V）'
                      : '当前 AI 配置未开启图片输入',
                  onPressed: busy || !_visionEnabled ? null : _pasteImage,
                  icon: const Icon(Icons.content_paste_go),
                ),
                Expanded(
                  child: CallbackShortcuts(
                    bindings: {
                      const SingleActivator(LogicalKeyboardKey.enter): _send,
                      const SingleActivator(
                        LogicalKeyboardKey.enter,
                        control: true,
                      ): () {},
                      const SingleActivator(
                        LogicalKeyboardKey.keyV,
                        control: true,
                        shift: true,
                      ): _pasteImage,
                    },
                    child: TextField(
                      controller: _inputController,
                      focusNode: _inputFocus,
                      minLines: 1,
                      maxLines: 6,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: '和你配置的 AI 聊天…',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                      ),
                      onSubmitted: (_) {
                        if (!busy) _send();
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                busy
                    ? IconButton.filled(
                        tooltip: '停止生成',
                        onPressed: _controller.cancel,
                        icon: const Icon(Icons.stop),
                      )
                    : IconButton.filled(
                        tooltip: '发送',
                        onPressed: _send,
                        icon: const Icon(Icons.send),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPendingThumbnail(AiChatAttachment attachment, int index) {
    final theme = Theme.of(context);
    final provider = myAttachmentProvider(attachment);
    return Stack(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: theme.colorScheme.outlineVariant),
            color: theme.colorScheme.surfaceContainerHighest,
          ),
          clipBehavior: Clip.antiAlias,
          child: provider == null
              ? Icon(Icons.image, color: theme.colorScheme.onSurfaceVariant)
              : Image(
                  image: provider,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: InkWell(
            onTap: () => setState(() => _pendingAttachments.removeAt(index)),
            child: Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.scrim.withValues(alpha: 0.6),
                shape: BoxShape.circle,
              ),
              padding: const EdgeInsets.all(2),
              child: Icon(
                Icons.close,
                size: 14,
                color: theme.colorScheme.onInverseSurface,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 图片降级时给出明确提示，避免用户误以为模型「看不清」是模型能力问题。
  void _showImageWarningIfAny() {
    final warning = _controller.imageWarning;
    if (warning == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(warning),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 6),
        action: SnackBarAction(label: '重新添加', onPressed: () => _pickImages()),
      ),
    );
  }

  Future<void> _openLink(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('无法打开链接：$url'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 7) return '${diff.inDays} 天前';
    return '${time.year}-${time.month.toString().padLeft(2, '0')}-'
        '${time.day.toString().padLeft(2, '0')}';
  }

  String _shorten(String text, int max) {
    final oneLine = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (oneLine.length <= max) return oneLine;
    return '${oneLine.substring(0, max)}…';
  }
}

/// 导出格式。
enum _ChatExportFormat { markdown, json }

const XTypeGroup _markdownTypeGroup = XTypeGroup(
  label: 'Markdown',
  extensions: ['md'],
  mimeTypes: ['text/markdown'],
  uniformTypeIdentifiers: ['net.daringfireball.markdown'],
);

const XTypeGroup _jsonTypeGroup = XTypeGroup(
  label: 'JSON',
  extensions: ['json'],
  mimeTypes: ['application/json'],
  uniformTypeIdentifiers: ['public.json'],
);

/// UI 层的一轮问答：一次提问 + 它触发的全部模型轮次与工具调用。
///
/// 控制器仍然逐条落库（assistant / tool 分成多条消息，回灌协议需要），
/// 这里只负责把它们重新折成一个气泡。
class _ChatTurn {
  _ChatTurn({this.user, this.contextNote, this.notice});

  /// 提问消息；没有提问的多轮续写时为 null。
  final AiChatMessage? user;

  /// 该提问冻结的上下文注入（若有）。
  final String? contextNote;

  /// 没有归属的系统说明消息。
  final AiChatMessage? notice;

  /// 该轮里模型产出的所有 assistant 消息，按发生顺序。
  final List<AiChatMessage> rounds = [];

  /// 该轮发起的工具调用记录，与 [rounds] 里的 tool_calls 一一对应。
  final List<AiToolCallRecord> tools = [];

  /// 各轮正文拼接后的正式回答。
  String get content => rounds
      .map((m) => m.content.trim())
      .where((t) => t.isNotEmpty)
      .join('\n\n');

  /// 各轮思维链拼接。
  String get reasoning => rounds
      .map((m) => m.reasoning?.trim() ?? '')
      .where((t) => t.isNotEmpty)
      .join('\n\n');

  /// 以最后一条为准的状态与错误信息。
  AiChatMessageStatus get status =>
      rounds.isEmpty ? AiChatMessageStatus.complete : rounds.last.status;

  String? get errorMessage => rounds.isEmpty ? null : rounds.last.errorMessage;
}
