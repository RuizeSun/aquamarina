import 'package:aquamarina/models/ai_context.dart';
import 'package:aquamarina/services/ai/ai_chat_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AiChatSettings settings;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    settings = AiChatSettings();
  });

  group('默认值', () {
    test('未配置时使用默认值', () async {
      expect(await settings.getProfileId(), isNull);
      expect(
        await settings.getSystemPrompt(),
        AiChatSettings.defaultSystemPrompt,
      );
      expect(await settings.getTemperatureOverride(), isNull);
      expect(await settings.getMaxTokensOverride(), isNull);
      final policy = await settings.getContextPolicy();
      expect(policy.compressionEnabled, isTrue);
      expect(policy.thresholdMode, AiContextThresholdMode.absolute);
      expect(
        policy.absoluteThreshold,
        AiContextPolicy.defaultAbsoluteThreshold,
      );
      expect(policy.usageWarningEnabled, isTrue);
      expect(
        policy.usageWarningRatio,
        AiContextPolicy.defaultUsageWarningRatio,
      );
      expect(await settings.getToolsEnabled(), isTrue);
      expect(await settings.getAutoApproveReadOnly(), isTrue);
      expect(
        await settings.getMaxToolRounds(),
        AiChatSettings.defaultToolRounds,
      );
      expect(await settings.getStreamEnabled(), isTrue);
      expect(await settings.getDisabledToolNames(), isEmpty);
    });
  });

  group('越界收敛', () {
    test('上下文策略保存并可换算比例阈值', () async {
      await settings.setContextPolicy(
        const AiContextPolicy(
          compressionEnabled: true,
          thresholdMode: AiContextThresholdMode.ratio,
          ratioThreshold: 0.5,
          usageWarningEnabled: true,
          usageWarningRatio: 0.8,
        ),
      );
      final policy = await settings.getContextPolicy();
      expect(policy.compressionEnabled, isTrue);
      expect(policy.thresholdMode, AiContextThresholdMode.ratio);
      expect(policy.resolveThresholdTokens(32000), 16000);
      expect(policy.resolveUsageWarningTokens(32000), 25600);
    });

    test('上下文策略越界值被收敛', () async {
      await settings.setContextPolicy(
        const AiContextPolicy(
          compressionEnabled: true,
          thresholdMode: AiContextThresholdMode.absolute,
          absoluteThreshold: 1,
          ratioThreshold: 5,
          usageWarningRatio: 2,
        ),
      );
      final policy = await settings.getContextPolicy();
      expect(policy.absoluteThreshold, AiContextPolicy.minAbsoluteThreshold);
      expect(policy.ratioThreshold, AiContextPolicy.maxRatio);
      expect(policy.usageWarningRatio, AiContextPolicy.maxUsageWarningRatio);
    });

    test('工具轮次被 clamp 到 1..10', () async {
      await settings.setMaxToolRounds(0);
      expect(await settings.getMaxToolRounds(), AiChatSettings.minToolRounds);
      await settings.setMaxToolRounds(99);
      expect(await settings.getMaxToolRounds(), AiChatSettings.maxToolRounds);
    });

    test('Max Tokens 被 clamp 到 64..8192', () async {
      await settings.setMaxTokensOverride(1);
      expect(
        await settings.getMaxTokensOverride(),
        AiChatSettings.minMaxTokens,
      );
      await settings.setMaxTokensOverride(999999);
      expect(
        await settings.getMaxTokensOverride(),
        AiChatSettings.maxMaxTokens,
      );
    });

    test('Temperature 被 clamp 到 0..2', () async {
      await settings.setTemperatureOverride(-1);
      expect(await settings.getTemperatureOverride(), 0.0);
      await settings.setTemperatureOverride(5);
      expect(await settings.getTemperatureOverride(), 2.0);
    });

    test('置空覆盖值会移除偏好', () async {
      await settings.setTemperatureOverride(1.0);
      await settings.setTemperatureOverride(null);
      expect(await settings.getTemperatureOverride(), isNull);
    });
  });

  group('工具黑名单', () {
    test('enabledToolNames 返回差集并保持顺序无关', () async {
      await settings.setDisabledToolNames({
        'set_word_note',
        'set_word_favorite',
      });
      final enabled = await settings.enabledToolNames(const [
        'search_dictionary',
        'set_word_note',
        'set_word_favorite',
      ]);
      expect(enabled, {'search_dictionary'});
    });

    test('系统提示词为空时回退默认', () async {
      await settings.setSystemPrompt('   ');
      expect(
        await settings.getSystemPrompt(),
        AiChatSettings.defaultSystemPrompt,
      );
    });
  });
}
