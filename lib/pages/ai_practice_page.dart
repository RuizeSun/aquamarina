import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/ai_sentence_set.dart';
import '../models/ai_sentence.dart';
import '../services/ai_sentence_set_service.dart';
import '../services/ai_sentence_service.dart';
import '../services/ai_profile_service.dart';
import 'ai_sentence_set_list_page.dart';
import 'ai_practice_session_page.dart';
import 'wrong_sentence_book_page.dart';

/// 全局路由观察者，用于检测子页面弹出后刷新数据
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();

class AiPracticePage extends StatefulWidget {
  const AiPracticePage({super.key});

  @override
  State<AiPracticePage> createState() => _AiPracticePageState();
}

class _AiPracticePageState extends State<AiPracticePage> with RouteAware {
  final SentenceSetService _setService = SentenceSetService.instance;
  final AiSentenceService _sentenceService = AiSentenceService();

  // 仪表盘状态
  bool _isLoading = true;

  // 可用的句式集
  List<SentenceSet> _availableSets = [];
  SentenceSet? _selectedSet;

  // 练习设置（从设置页读取）
  PracticeMode _practiceMode = PracticeMode.beginner;
  int _extraWordCount = 3;
  int _sentenceLimit = 10;

  // 错题本状态
  int _wrongSentenceCount = 0;

  // 进度状态
  int _practicedCount = 0;
  int _totalCount = 0;

  // 不重复练习开关
  bool _skipRepeated = false;

  @override
  void initState() {
    super.initState();
    _initData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    routeObserver.subscribe(this, ModalRoute.of(context)!);
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _setService.removeListener(_onSetsChanged);
    super.dispose();
  }

  @override
  void didPopNext() {
    // 从子页面（设置页、练习会话页等）返回时，重新加载设置和进度
    _loadSettings().then((_) {
      _refreshProgress();
    });
  }

  void _onSetsChanged() {
    if (!mounted) return;
    setState(() {
      _availableSets = _setService.sets;
      if (_selectedSet != null) {
        // 用最新列表中的对象替换 _selectedSet
        // （SentenceSet 不可变，更新 sentenceCount 后必须替换引用才能拿到最新数据）
        final updated = _availableSets
            .where((s) => s.id == _selectedSet!.id)
            .toList();
        if (updated.isNotEmpty) {
          _selectedSet = updated.first;
        } else {
          // 当前选中的句式集被删除了，自动切换
          _selectedSet = _availableSets.isNotEmpty
              ? _availableSets.first
              : null;
        }
      }
      // 原本没有选中（例如刚导入第一个句式集），自动选中第一个
      if (_selectedSet == null && _availableSets.isNotEmpty) {
        _selectedSet = _availableSets.first;
      }
    });
    _refreshProgress();
  }

  Future<void> _initData() async {
    setState(() => _isLoading = true);

    // 加载句式集
    await _setService.load();
    _setService.addListener(_onSetsChanged);

    // 加载设置
    await _loadSettings();

    if (mounted) {
      setState(() {
        _availableSets = _setService.sets;
        // 默认选中第一个句式集
        if (_availableSets.isNotEmpty && _selectedSet == null) {
          _selectedSet = _availableSets.first;
        }
        _isLoading = false;
      });
    }
    // 刷新进度和错题数量
    await _refreshProgress();
  }

  Future<void> _loadSettings() async {
    _extraWordCount = await _sentenceService.getExtraWordCount();
    _sentenceLimit = await _sentenceService.getSentenceLimit();
    _practiceMode = await _sentenceService.getPracticeMode();
    _skipRepeated = await _sentenceService.getSkipRepeated();
  }

  Future<void> _refreshProgress() async {
    // 用最新引用替换 _selectedSet，确保 sentenceCount 为最新值
    if (_selectedSet != null) {
      final updated = _setService.sets
          .where((s) => s.id == _selectedSet!.id)
          .toList();
      if (updated.isNotEmpty) {
        _selectedSet = updated.first;
      }
    }
    // 获取错题数量
    final wrongCount = await _sentenceService.getWrongSentenceCount();
    // 获取当前句式集进度
    int practiced = 0;
    int total = 0;
    if (_selectedSet != null) {
      total = _selectedSet!.sentenceCount;
      final practicedIds = await _sentenceService.getPracticedSentenceIds(
        _selectedSet!.id!,
      );
      practiced = practicedIds.length;
    }
    if (mounted) {
      setState(() {
        _wrongSentenceCount = wrongCount;
        _practicedCount = practiced;
        _totalCount = total;
      });
    }
  }

  // ===== 隐私政策检查（仅对 Aquamarina 官方配置） =====
  static const String _privacyPolicyKeyPrefix = 'privacy_policy_accepted_';
  static const String _aquamarinaOfficialHost = 'aquamarina.78go.work';

  /// 检查是否需要弹出隐私政策
  /// 返回 true 表示已同意或无需检查，false 表示用户不同意已退出
  Future<bool> _checkPrivacyPolicy() async {
    final profileService = AiProfileService();
    await profileService.load();
    final profile = profileService.defaultProfile;

    // 非 Aquamarina 官方配置，无需检查隐私政策
    if (profile == null ||
        !profile.isAquamarina ||
        !profile.baseUrl.contains(_aquamarinaOfficialHost)) {
      return true;
    }

    // 检查是否已同意
    final prefs = await SharedPreferences.getInstance();
    final accepted =
        prefs.getBool('$_privacyPolicyKeyPrefix${profile.id}') ?? false;
    if (accepted) return true;

    // 未同意，弹出对话框
    if (!mounted) return false;
    final agreed = await _showPrivacyPolicyDialog();
    if (agreed) {
      await prefs.setBool('$_privacyPolicyKeyPrefix${profile.id}', true);
      return true;
    } else {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已退出句型练习')));
      }
      return false;
    }
  }

  Future<bool> _showPrivacyPolicyDialog() async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          title: const Text('隐私政策'),
          content: SingleChildScrollView(
            child: Text('''
本 App 内置的句型练习功能，需要将您提交的英文译文与系统内置的标准答案进行智能比对。在此过程中，您的设备会向我们的服务器传输与 App 功能相关的必要数据。

为实现更精准的语义理解和纠错反馈，我们采用第三方大语言模型 API 进行辅助判断，所有发往该模型的请求均由我们的服务器统一拼接生成标准化提示词，您的译文本身不会作为独立语料被直接传输或暴露给第三方模型用于训练或其他任何目的。我们所中转调用的所有大语言模型均已按照国家相关规定完成算法备案，模型服务提供方均为合法备案的合规服务商；相关请求经由部署于中华人民共和国香港特别行政区的服务器进行技术中转处理，全程不会将任何数据转递至未备案或未经合规审查的境外模型服务。

为保障服务质量、进行必要的故障排查以及在发生争议或合规审查时能够提供有效证据，我们会记录每次请求所涉及的英文原句、中文释义、您提交的译文以及模型返回的比对结果，上述记录采取加密存储方式，仅用于内部审计与纠纷核查，不会用于任何其他商业目的或主动向第三方披露。我们同时记录发起请求的IP地址、请求时间及API调用状态码，该IP信息仅用于频率限制和异常流量识别，不会与您的译文内容进行任何形式的关联分析或用于用户画像。

上述全部记录仅在有权机关依法出具正式法律文书要求配合时，经核实对方身份与文书真实性后依法提供；在未收到上述法定要求前，我们不会主动调取或查阅任何用户的译文内容记录。本功能传输的所有练习内容均不包含您的用户ID、设备指纹或其他可定位至您个人身份的信息，因此上述记录本身亦不具有个人识别性。记录的保留期限为三十日，超出期限后系统将自动执行不可逆的删除操作。

如您不同意上述数据处理方式，我们提供替代方案供您选择：您可以选择在本地部署开源大语言模型以实现完全离线比对，亦可选择使用您自行注册的国内合规平台接口进行配置，此时您的请求将直接发往您所指定的平台，不再经由我们的服务器中转，我们亦不会记录任何相关数据。

您随时可以在设置中撤销隐私政策的授权。撤回同意不影响撤回前已合法进行的处理活动。'''),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('不同意'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('同意并继续'),
            ),
          ],
        );
      },
    );
    return result ?? false;
  }

  // ===== 开始句式集练习 =====
  Future<void> _startPractice({required bool isWrongBook}) async {
    // 重新加载最新设置（确保设置页的修改已生效）
    await _loadSettings();

    // 隐私政策检查（Aquamarina 官方配置首次使用时）
    final canProceed = await _checkPrivacyPolicy();
    if (!canProceed) return;

    if (isWrongBook) {
      final wrongSentences = await _sentenceService.getWrongSentences();
      if (wrongSentences.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('错题本为空，请先进行句式集练习')));
        }
        return;
      }

      if (!mounted) return;

      // 将错题记录转换为 Sentence 对象
      final sentences = wrongSentences
          .map(
            (r) => Sentence(
              id: r.sentenceId,
              setId: r.setId,
              english: r.english,
              chinese: r.chinese,
            ),
          )
          .toList();

      await Navigator.of(context).push<dynamic>(
        MaterialPageRoute(
          builder: (_) => AiPracticeSessionPage(
            selectedSet: _selectedSet ?? SentenceSet(name: '错题本'),
            practiceMode: _practiceMode,
            extraWordCount: _extraWordCount,
            sentenceLimit: _sentenceLimit,
            wrongBookSentences: sentences,
            isWrongBookPractice: true,
          ),
        ),
      );

      await _refreshProgress();
      if (mounted) setState(() {});
      return;
    }

    if (_selectedSet == null) return;

    // 获取句式集所有句子
    final allSentences = await _setService.getSentences(_selectedSet!.id!);
    if (allSentences.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('该句式集没有句子，请先添加')));
      }
      return;
    }

    // 如果开启了"不重复练习"，过滤掉已练习的句子
    final skipRepeated = await _sentenceService.getSkipRepeated();
    List<Sentence> practiceSentences;
    if (skipRepeated) {
      final practicedIds = await _sentenceService.getPracticedSentenceIds(
        _selectedSet!.id!,
      );
      practiceSentences = allSentences
          .where((s) => !practicedIds.contains(s.id))
          .toList();
      if (practiceSentences.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('该句式集所有句子已练习完成，可关闭"不重复练习"重试')),
          );
        }
        return;
      }
    } else {
      practiceSentences = allSentences;
    }

    if (!mounted) return;

    // 跳转到练习会话页面
    await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(
        builder: (_) => AiPracticeSessionPage(
          selectedSet: _selectedSet!,
          practiceMode: _practiceMode,
          extraWordCount: _extraWordCount,
          sentenceLimit: _sentenceLimit,
          preFilteredSentences: practiceSentences,
        ),
      ),
    );

    // 返回后刷新数据
    await _loadSettings();
    await _refreshProgress();
    if (mounted) setState(() {});
  }

  // ===== UI 构建 =====
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('句型练习'), centerTitle: false),
      body: _buildBody(theme, colorScheme),
    );
  }

  Widget _buildBody(ThemeData theme, ColorScheme colorScheme) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_selectedSet == null) {
      return _buildNoSetState(theme, colorScheme);
    }

    return _buildDashboard(theme, colorScheme);
  }

  Widget _buildNoSetState(ThemeData theme, ColorScheme colorScheme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.format_quote_rounded,
              size: 80,
              color: colorScheme.primary.withValues(alpha: 0.3),
            ),
            const SizedBox(height: 16),
            Text(
              '还没有句型集',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '请先创建或从在线资源库中添加一个句型集',
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _openSetSelector,
              icon: const Icon(Icons.add),
              label: const Text('添加句型集'),
            ),
          ],
        ),
      ),
    );
  }

  // ===== 仪表盘 =====
  Widget _buildDashboard(ThemeData theme, ColorScheme colorScheme) {
    final modeLabel = _practiceMode == PracticeMode.beginner ? '入门版' : '高阶版';

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---- 句式集区域 ----
            Text('句式集', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _openSetSelector,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
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
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selectedSet?.name ?? '请选择句式集',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (_selectedSet != null)
                              Text(
                                '${_selectedSet!.sentenceCount} 句 · $modeLabel',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right),
                    ],
                  ),
                ),
              ),
            ),

            // 句式集练习进度（仅不重复练习开启时显示）
            if (_selectedSet != null && _totalCount > 0 && _skipRepeated) ...[
              const SizedBox(height: 12),
              _buildProgressRow(
                theme: theme,
                colorScheme: colorScheme,
                icon: Icons.menu_book_rounded,
                label: '句式集练习',
                current: _practicedCount,
                total: _totalCount,
              ),
            ],

            const SizedBox(height: 20),

            // ---- 错题本区域 ----
            Row(
              children: [
                Icon(Icons.error_outline, color: colorScheme.error, size: 20),
                const SizedBox(width: 6),
                Text('错题本', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 8),
            Card(
              color: colorScheme.errorContainer.withValues(alpha: 0.3),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: _openWrongBook,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: colorScheme.error.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          Icons.format_list_numbered,
                          color: colorScheme.error,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '错题本',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              _wrongSentenceCount > 0
                                  ? '$_wrongSentenceCount 道错题待练习'
                                  : '暂无错题',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Icon(Icons.chevron_right, size: 20),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 12),

            // ---- 两个练习按钮 ----
            SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton.icon(
                onPressed: _selectedSet != null
                    ? () => _startPractice(isWrongBook: false)
                    : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('句式集练习', style: TextStyle(fontSize: 18)),
                style: FilledButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 56,
              child: OutlinedButton.icon(
                onPressed: _wrongSentenceCount > 0
                    ? () => _startPractice(isWrongBook: true)
                    : null,
                icon: const Icon(Icons.replay),
                label: const Text('错题本练习', style: TextStyle(fontSize: 18)),
                style: OutlinedButton.styleFrom(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 24),

            // 设置提示
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '练习模式、句数、错题本等请在「设置」中配置',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 构建进度行
  Widget _buildProgressRow({
    required ThemeData theme,
    required ColorScheme colorScheme,
    required IconData icon,
    required String label,
    required int current,
    required int total,
  }) {
    final progress = total > 0 ? current / total : 0.0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colorScheme.primary),
            const SizedBox(width: 8),
            Text(label, style: theme.textTheme.bodyMedium),
            const Spacer(),
            Text(
              '$current / $total',
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 80,
              child: LinearProgressIndicator(
                value: progress,
                borderRadius: BorderRadius.circular(4),
                minHeight: 6,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 打开错题本查看页面
  Future<void> _openWrongBook() async {
    await Navigator.of(context).push<dynamic>(
      MaterialPageRoute(builder: (_) => const WrongSentenceBookPage()),
    );
    // 返回后刷新错题数量（可能删除了错题或练习了错题）
    await _refreshProgress();
  }

  Future<void> _openSetSelector() async {
    // 确保句式集列表页面使用的是同一服务实例（共享数据）
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SentenceSetListPage(
          currentSetId: _selectedSet?.id,
          onSetSelected: (set) {
            setState(() => _selectedSet = set);
          },
        ),
      ),
    );
    // 从 SharedPreferences 重新加载，确保拿到导入/删除后的最新数据
    await _setService.load();
    if (!mounted) return;
    setState(() {
      _availableSets = _setService.sets;
      if (_selectedSet != null) {
        // 用最新列表中的对象替换 _selectedSet
        // （SentenceSet 不可变，更新 sentenceCount 后必须替换引用才能拿到最新数据）
        final updated = _availableSets
            .where((s) => s.id == _selectedSet!.id)
            .toList();
        if (updated.isNotEmpty) {
          _selectedSet = updated.first;
        } else {
          // 当前选中的句式集被删除了，重置
          _selectedSet = _availableSets.isNotEmpty
              ? _availableSets.first
              : null;
        }
      } else if (_availableSets.isNotEmpty) {
        // 原本没有选中句式集（例如刚导入了第一个），自动选中第一个
        _selectedSet = _availableSets.first;
      }
    });
    await _refreshProgress();
  }
}
