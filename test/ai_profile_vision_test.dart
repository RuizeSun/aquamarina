import 'package:aquamarina/models/ai_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AI 配置的图片输入开关', () {
    test('默认关闭', () {
      const profile = AiProfile(
        id: 'p1',
        name: '测试',
        type: AiProfileType.openai,
      );
      expect(profile.enableVision, isFalse);
    });

    test('toJson / fromJson 往返保留', () {
      const profile = AiProfile(
        id: 'p1',
        name: '支持视觉',
        type: AiProfileType.openai,
        model: 'gpt-4o',
        enableVision: true,
      );
      final restored = AiProfile.fromJson(profile.toJson());
      expect(restored.enableVision, isTrue);
    });

    test('旧配置缺少字段时回退为关闭', () {
      final restored = AiProfile.fromJson({
        'id': 'p1',
        'name': '旧配置',
        'type': 'openai',
        'base_url': 'https://api.openai.com/v1',
        'model': 'gpt-4o-mini',
      });
      expect(restored.enableVision, isFalse);
    });

    test('copyWith 可切换开关', () {
      const profile = AiProfile(
        id: 'p1',
        name: '测试',
        type: AiProfileType.openai,
      );
      expect(profile.copyWith(enableVision: true).enableVision, isTrue);
      expect(
        profile
            .copyWith(enableVision: true)
            .copyWith(enableVision: false)
            .enableVision,
        isFalse,
      );
    });
  });

  group('AI 配置的上下文窗口', () {
    test('默认未配置', () {
      const profile = AiProfile(
        id: 'p1',
        name: '测试',
        type: AiProfileType.openai,
      );
      expect(profile.contextWindow, 0);
    });

    test('toJson / fromJson 往返保留', () {
      const profile = AiProfile(
        id: 'p1',
        name: '测试',
        type: AiProfileType.openai,
        contextWindow: 128000,
      );
      final restored = AiProfile.fromJson(profile.toJson());
      expect(restored.contextWindow, 128000);
    });

    test('旧配置缺少字段时回退为未配置', () {
      final restored = AiProfile.fromJson({
        'id': 'p1',
        'name': '旧配置',
        'type': 'openai',
        'base_url': 'https://api.openai.com/v1',
        'model': 'gpt-4o-mini',
      });
      expect(restored.contextWindow, 0);
    });

    test('copyWith 可修改上下文窗口', () {
      const profile = AiProfile(
        id: 'p1',
        name: '测试',
        type: AiProfileType.openai,
      );
      expect(profile.copyWith(contextWindow: 32000).contextWindow, 32000);
    });
  });
}
