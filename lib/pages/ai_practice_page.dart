import 'dart:async';
import 'package:flutter/material.dart';
import '../services/ai_profile_service.dart';
import '../services/ai_service.dart';

class AiPracticePage extends StatefulWidget {
  const AiPracticePage({super.key});

  @override
  State<AiPracticePage> createState() => _AiPracticePageState();
}

class _AiPracticePageState extends State<AiPracticePage> {
  final AiProfileService _profileService = AiProfileService();
  final AiService _aiService = AiService();
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<ChatMessage> _messages = [];

  bool _isLoading = false;
  bool _isStreaming = false;
  bool _configReady = false;
  StreamSubscription<String>? _streamSub;

  @override
  void initState() {
    super.initState();
    _initConfig();
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    _inputController.dispose();
    _scrollController.dispose();
    _profileService.removeListener(_onConfigChanged);
    super.dispose();
  }

  Future<void> _initConfig() async {
    await _profileService.load();
    if (mounted) {
      final profile = _profileService.defaultProfile;
      setState(() {
        _configReady = profile != null && profile.apiKey.isNotEmpty;
      });
      if (profile != null) {
        _aiService.setCurrentProfile(profile);
      }
      // 监听配置变化
      _profileService.addListener(_onConfigChanged);
    }
  }

  void _onConfigChanged() {
    if (mounted) {
      final profile = _profileService.defaultProfile;
      setState(() {
        _configReady = profile != null && profile.apiKey.isNotEmpty;
      });
      if (profile != null) {
        _aiService.setCurrentProfile(profile);
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;

    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
      _isLoading = true;
    });
    _inputController.clear();
    _scrollToBottom();

    // 构建消息历史
    final messages = _messages
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();

    // 添加占位的 AI 回复
    final aiMsg = ChatMessage(
      role: 'assistant',
      content: '',
      isStreaming: true,
    );
    setState(() {
      _messages.add(aiMsg);
      _isLoading = false;
      _isStreaming = true;
    });

    try {
      final stream = _aiService.chatStream(messages: messages);
      _streamSub = stream.listen(
        (chunk) {
          final index = _messages.length - 1;
          setState(() {
            _messages[index] = _messages[index].copyWith(
              content: _messages[index].content + chunk,
            );
          });
          _scrollToBottom();
        },
        onError: (error) {
          _replaceLastAiMessage(content: error.toString(), isError: true);
        },
        onDone: () {
          final index = _messages.length - 1;
          setState(() {
            _messages[index] = _messages[index].copyWith(isStreaming: false);
            _isStreaming = false;
          });
        },
      );
    } catch (e) {
      _replaceLastAiMessage(content: e.toString(), isError: true);
    }
  }

  void _replaceLastAiMessage({required String content, bool isError = false}) {
    setState(() {
      final index = _messages.length - 1;
      if (index >= 0) {
        _messages[index] = ChatMessage(
          role: 'assistant',
          content: content,
          isError: isError,
        );
      }
      _isStreaming = false;
      _isLoading = false;
    });
  }

  Future<void> _clearConversation() async {
    _streamSub?.cancel();
    setState(() {
      _messages.clear();
      _isStreaming = false;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI 练习'),
        centerTitle: false,
        actions: [
          if (_messages.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空对话',
              onPressed: _clearConversation,
            ),
        ],
      ),
      body: _configReady
          ? _buildChat(theme, colorScheme)
          : _buildNoConfig(theme, colorScheme),
    );
  }

  Widget _buildNoConfig(ThemeData theme, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.settings_suggest,
              size: 80,
              color: colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '请先配置 AI 服务',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '前往「设置」页面配置 API Key 和模型参数',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            Text(
              '支持的 API 服务：OpenAI、Claude、DeepSeek、\nOllama 等任意 OpenAI 兼容接口',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChat(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      children: [
        // 模型信息条
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          child: Text(
            '模型：${_profileService.defaultProfile?.model ?? "未配置"}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
        ),

        // 消息列表
        Expanded(
          child: _messages.isEmpty
              ? _buildEmptyState(colorScheme, theme)
              : ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.all(12),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    return _buildMessageBubble(
                      _messages[index],
                      theme,
                      colorScheme,
                    );
                  },
                ),
        ),

        // 输入区域
        _buildInputBar(colorScheme),
      ],
    );
  }

  Widget _buildEmptyState(ColorScheme colorScheme, ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.chat_bubble_outline,
            size: 64,
            color: colorScheme.primary.withValues(alpha: 0.2),
          ),
          const SizedBox(height: 16),
          Text(
            '开始与 AI 对话',
            style: theme.textTheme.titleMedium?.copyWith(
              color: colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '输入单词或句子，让 AI 帮你练习',
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(
    ChatMessage msg,
    ThemeData theme,
    ColorScheme colorScheme,
  ) {
    final isUser = msg.role == 'user';
    final borderRadius = BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isUser ? 16 : 4),
      bottomRight: Radius.circular(isUser ? 4 : 16),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              radius: 14,
              backgroundColor: colorScheme.primaryContainer,
              child: Icon(
                Icons.smart_toy,
                size: 16,
                color: colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: msg.isError
                    ? colorScheme.errorContainer
                    : isUser
                    ? colorScheme.primaryContainer
                    : colorScheme.surfaceContainerHighest,
                borderRadius: borderRadius,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (msg.isStreaming && msg.content.isEmpty)
                    const SizedBox(
                      width: 20,
                      height: 12,
                      child: Center(
                        child: SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  else ...[
                    SelectableText(
                      msg.content,
                      style: TextStyle(
                        color: msg.isError
                            ? colorScheme.onErrorContainer
                            : isUser
                            ? colorScheme.onPrimaryContainer
                            : colorScheme.onSurface,
                      ),
                    ),
                    if (msg.isStreaming)
                      const SizedBox(
                        width: 8,
                        height: 16,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _CursorBlink(),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildInputBar(ColorScheme colorScheme) {
    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: colorScheme.outlineVariant.withValues(alpha: 0.3),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _inputController,
              enabled: !_isStreaming && !_isLoading,
              decoration: InputDecoration(
                hintText: _isStreaming ? 'AI 正在回复...' : '输入消息...',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                isDense: true,
              ),
              textInputAction: TextInputAction.send,
              onSubmitted: (_isStreaming || _isLoading)
                  ? null
                  : (_) => _sendMessage(),
              maxLines: 4,
              minLines: 1,
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            onPressed: (_isStreaming || _isLoading) ? null : _sendMessage,
            icon: const Icon(Icons.send_rounded),
            style: IconButton.styleFrom(
              backgroundColor: colorScheme.primary,
              foregroundColor: colorScheme.onPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class ChatMessage {
  final String role; // 'user' | 'assistant'
  final String content;
  final bool isStreaming;
  final bool isError;

  const ChatMessage({
    required this.role,
    required this.content,
    this.isStreaming = false,
    this.isError = false,
  });

  ChatMessage copyWith({
    String? role,
    String? content,
    bool? isStreaming,
    bool? isError,
  }) {
    return ChatMessage(
      role: role ?? this.role,
      content: content ?? this.content,
      isStreaming: isStreaming ?? this.isStreaming,
      isError: isError ?? this.isError,
    );
  }
}

class _CursorBlink extends StatefulWidget {
  const _CursorBlink();

  @override
  State<_CursorBlink> createState() => _CursorBlinkState();
}

class _CursorBlinkState extends State<_CursorBlink>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: Container(
        width: 2,
        height: 14,
        color: Theme.of(context).colorScheme.onSurface,
      ),
    );
  }
}
