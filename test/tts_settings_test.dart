import 'dart:convert';
import 'dart:typed_data';

import 'package:aquamarina/pages/settings/sections/tts_section.dart';
import 'package:aquamarina/services/mimo_tts_engine.dart';
import 'package:aquamarina/services/tts_service.dart';
import 'package:aquamarina/services/tts_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TtsProvider 枚举与兼容性', () {
    test('历史 index 保持不变，MiMo 追加在末尾', () {
      expect(TtsProvider.values[0], TtsProvider.system);
      expect(TtsProvider.values[1], TtsProvider.edge);
      expect(TtsProvider.values[2], TtsProvider.mimo);
      expect(TtsProvider.mimo.index, 2);
    });

    test('越界 / 缺省 index 安全回退到 Edge', () {
      expect(TtsSettings.providerFromIndex(null), TtsProvider.edge);
      expect(TtsSettings.providerFromIndex(-1), TtsProvider.edge);
      expect(TtsSettings.providerFromIndex(99), TtsProvider.edge);
      expect(TtsSettings.providerFromIndex(2), TtsProvider.mimo);
    });
  });

  group('TtsSettings 持久化', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('默认值：Edge 服务商 + MiMo 官方默认配置', () async {
      final settings = await TtsSettings.load();
      expect(settings.provider, TtsProvider.edge);
      expect(settings.mimoBaseUrl, TtsSettings.defaultMimoBaseUrl);
      expect(settings.mimoModel, TtsSettings.defaultMimoModel);
      expect(settings.mimoInstruction, isEmpty);
      expect(settings.mimoStyleTag, isEmpty);
      expect(settings.voiceName, isNull);
    });

    test('保存后重新加载可还原 MiMo 配置', () async {
      await const TtsSettings(
        provider: TtsProvider.mimo,
        voiceName: '冰糖',
        mimoBaseUrl: 'https://example.com/v1',
        mimoInstruction: '语速稍慢',
        mimoStyleTag: '东北话',
      ).save();

      final loaded = await TtsSettings.load();
      expect(loaded.provider, TtsProvider.mimo);
      expect(loaded.voiceName, '冰糖');
      expect(loaded.mimoBaseUrl, 'https://example.com/v1');
      expect(loaded.mimoModel, TtsSettings.defaultMimoModel);
      expect(loaded.mimoInstruction, '语速稍慢');
      expect(loaded.mimoStyleTag, '东北话');
    });

    test('音色按服务商分别存储，切换服务商不会互相覆盖', () async {
      const edge = TtsSettings(
        provider: TtsProvider.edge,
        voiceName: 'en-US-AriaNeural',
      );
      await edge.save();

      // 切到 MiMo（模拟 UI：先取回目标服务商音色，无则清空）
      final mimoVoice = await TtsSettings.loadVoiceFor(TtsProvider.mimo);
      expect(mimoVoice, isNull);
      await edge
          .copyWith(
            provider: TtsProvider.mimo,
            voiceName: mimoVoice,
            clearVoiceName: mimoVoice == null,
          )
          .save();

      // MiMo 选择音色
      var current = await TtsSettings.load();
      expect(current.provider, TtsProvider.mimo);
      expect(current.voiceName, isNull);
      await current.copyWith(voiceName: 'Mia').save();

      // 切回 Edge：Edge 音色未被 MiMo 覆盖
      current = await TtsSettings.load();
      final edgeVoice = await TtsSettings.loadVoiceFor(TtsProvider.edge);
      expect(edgeVoice, 'en-US-AriaNeural');
      await current
          .copyWith(provider: TtsProvider.edge, voiceName: edgeVoice)
          .save();

      current = await TtsSettings.load();
      expect(current.provider, TtsProvider.edge);
      expect(current.voiceName, 'en-US-AriaNeural');

      // MiMo 音色同样保留
      expect(await TtsSettings.loadVoiceFor(TtsProvider.mimo), 'Mia');
    });

    test('effectiveVoiceName：MiMo 未选音色时回退默认音色', () {
      const mimo = TtsSettings(provider: TtsProvider.mimo);
      expect(mimo.effectiveVoiceName, TtsSettings.defaultMimoVoice);

      const edge = TtsSettings(provider: TtsProvider.edge);
      expect(edge.effectiveVoiceName, isNull);

      const picked = TtsSettings(provider: TtsProvider.mimo, voiceName: '茉莉');
      expect(picked.effectiveVoiceName, '茉莉');
    });
  });

  group('音色与服务商匹配', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('Edge 下丢弃历史遗留的 MiMo 音色', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tts_provider': TtsProvider.edge.index,
        'tts_voice': 'mimo_default',
      });

      final settings = await TtsSettings.load();
      expect(settings.provider, TtsProvider.edge);
      expect(settings.voiceName, isNull);
      expect(settings.effectiveVoiceName, isNull);
      expect(await TtsSettings.loadVoiceFor(TtsProvider.edge), isNull);
    });

    test('MiMo 下丢弃历史遗留的 Edge 音色', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tts_provider': TtsProvider.mimo.index,
        'tts_voice_mimo': 'en-US-AriaNeural',
      });

      final settings = await TtsSettings.load();
      expect(settings.voiceName, isNull);
      expect(settings.effectiveVoiceName, TtsSettings.defaultMimoVoice);
    });

    test('匹配的音色正常保留', () async {
      expect(
        TtsSettings.sanitizeVoice(TtsProvider.edge, 'en-US-AriaNeural'),
        'en-US-AriaNeural',
      );
      expect(
        TtsSettings.sanitizeVoice(
          TtsProvider.edge,
          'zh-CN-liaoning-XiaobeiNeural',
        ),
        'zh-CN-liaoning-XiaobeiNeural',
      );
      expect(TtsSettings.sanitizeVoice(TtsProvider.mimo, '冰糖'), '冰糖');
      expect(
        TtsSettings.sanitizeVoice(TtsProvider.edge, 'mimo_default'),
        isNull,
      );
      expect(
        TtsSettings.sanitizeVoice(TtsProvider.mimo, 'zh-CN-XiaoxiaoNeural'),
        isNull,
      );
      expect(
        TtsSettings.sanitizeVoice(
          TtsProvider.mimo,
          'zh-CN-liaoning-XiaobeiNeural',
        ),
        isNull,
      );
    });

    test('copyWith 切换服务商时自动清理不匹配音色', () {
      const edge = TtsSettings(
        provider: TtsProvider.edge,
        voiceName: 'en-US-AriaNeural',
      );
      expect(edge.copyWith(provider: TtsProvider.mimo).voiceName, isNull);

      const mimo = TtsSettings(provider: TtsProvider.mimo, voiceName: 'Mia');
      expect(mimo.copyWith(provider: TtsProvider.edge).voiceName, isNull);

      // 服务商不变时不会误删合法音色，但会拦截串台音色
      expect(edge.copyWith(volume: 0.5).voiceName, 'en-US-AriaNeural');
      expect(edge.copyWith(voiceName: 'mimo_default').voiceName, isNull);
    });

    test('保存时不会把 MiMo 音色写入 Edge 音色槽', () async {
      await const TtsSettings(
        provider: TtsProvider.edge,
        voiceName: 'mimo_default',
      ).save();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('tts_voice'), isNull);
    });

    test('音色列表按服务商返回，不串用当前引擎', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tts_provider': TtsProvider.edge.index,
      });

      final mimoVoices = await TtsService.instance.getVoices(
        provider: TtsProvider.mimo,
      );
      expect(mimoVoices, hasLength(MimoTtsEngine.presetVoices.length));
      expect(mimoVoices, contains(TtsSettings.defaultMimoVoice));
      expect(
        await TtsService.instance.getVoices(provider: TtsProvider.system),
        isEmpty,
      );
    });
  });

  group('MimoTtsEngine 请求体', () {
    test('文本放在 assistant 消息，无风格指令时不发 user 消息', () {
      final body = MimoTtsEngine.buildRequestBody(
        model: 'mimo-v2.5-tts',
        text: 'hello',
        voice: 'mimo_default',
      );

      expect(body['model'], 'mimo-v2.5-tts');
      expect(body['audio'], {'format': 'mp3', 'voice': 'mimo_default'});

      final messages = body['messages'] as List<dynamic>;
      expect(messages, hasLength(1));
      expect(messages.single, {'role': 'assistant', 'content': 'hello'});
    });

    test('风格指令作为 user 消息，且排在 assistant 之前', () {
      final body = MimoTtsEngine.buildRequestBody(
        model: 'mimo-v2.5-tts',
        text: 'hello',
        voice: 'Mia',
        instruction: '  语速稍慢  ',
      );

      final messages = (body['messages'] as List<dynamic>)
          .cast<Map<String, String>>();
      expect(messages, hasLength(2));
      expect(messages[0], {'role': 'user', 'content': '语速稍慢'});
      expect(messages[1]['role'], 'assistant');
      expect(messages[1]['content'], 'hello');
    });

    test('空模型 / 空音色回退默认值，音频标签前缀自动补括号', () {
      final body = MimoTtsEngine.buildRequestBody(
        model: '  ',
        text: '你好',
        voice: '',
        styleTag: '东北话',
      );

      expect(body['model'], MimoTtsEngine.defaultModel);
      expect((body['audio'] as Map)['voice'], MimoTtsEngine.defaultVoice);

      final messages = body['messages'] as List<dynamic>;
      expect((messages.single as Map)['content'], '(东北话)你好');
    });

    test('applyStyleTag 保留已有括号写法', () {
      expect(MimoTtsEngine.applyStyleTag('hi', ''), 'hi');
      expect(MimoTtsEngine.applyStyleTag('hi', '   '), 'hi');
      expect(MimoTtsEngine.applyStyleTag('hi', '唱歌'), '(唱歌)hi');
      expect(MimoTtsEngine.applyStyleTag('hi', '(唱歌)'), '(唱歌)hi');
      expect(MimoTtsEngine.applyStyleTag('hi', '（粤语）'), '（粤语）hi');
      expect(MimoTtsEngine.applyStyleTag('hi', '[叹气]'), '[叹气]hi');
    });

    test('预置音色包含官方 9 个音色且默认音色在列', () {
      final ids = MimoTtsEngine.presetVoices.map((v) => v.id).toList();
      expect(ids, hasLength(9));
      expect(ids, contains(MimoTtsEngine.defaultVoice));
      expect(
        ids,
        containsAll(['冰糖', '茉莉', '苏打', '白桦', 'Mia', 'Chloe', 'Milo', 'Dean']),
      );
    });
  });

  group('MimoTtsEngine 响应解析', () {
    test('从 choices[0].message.audio.data 解码 base64 音频', () {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final json = {
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': '',
              'audio': {'data': base64Encode(bytes), 'format': 'mp3'},
            },
          },
        ],
      };

      expect(MimoTtsEngine.extractAudioBytes(json), bytes);
    });

    test('结构缺失或 base64 非法时返回 null', () {
      expect(MimoTtsEngine.extractAudioBytes(null), isNull);
      expect(MimoTtsEngine.extractAudioBytes('not a map'), isNull);
      expect(MimoTtsEngine.extractAudioBytes(<String, dynamic>{}), isNull);
      expect(MimoTtsEngine.extractAudioBytes({'choices': <dynamic>[]}), isNull);
      expect(
        MimoTtsEngine.extractAudioBytes({
          'choices': [
            {'message': <String, dynamic>{}},
          ],
        }),
        isNull,
      );
      expect(
        MimoTtsEngine.extractAudioBytes({
          'choices': [
            {
              'message': {
                'audio': {'data': '!!!not-base64!!!'},
              },
            },
          ],
        }),
        isNull,
      );
    });
  });

  group('语音设置页 MiMo UI', () {
    Future<void> pumpSection(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: TtsSettingsSection()),
          ),
        ),
      );
      // 等待异步设置加载完成（不使用 pumpAndSettle：加载态含无限动画）
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    testWidgets('选择 MiMo 后展示 API Key、音色与风格指令入口', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tts_enabled': true,
        'tts_provider': TtsProvider.mimo.index,
      });

      await pumpSection(tester);

      // 服务商三选一，当前选中 MiMo
      expect(find.text('MiMo'), findsWidgets);
      expect(find.text('当前：MiMo'), findsOneWidget);

      // MiMo 专属设置
      expect(find.text('MiMo API Key'), findsOneWidget);
      expect(find.text('风格指令（可选）'), findsOneWidget);
      expect(find.text('MiMo 高级设置'), findsOneWidget);

      // 音色显示默认音色
      expect(find.text('音色'), findsOneWidget);
      expect(find.text(TtsSettings.defaultMimoVoice), findsOneWidget);

      // 音调不可用：提示文案 + Slider 置灰
      expect(find.text('音调: MiMo 不支持调整'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider).last).onChanged, isNull);

      // 试听测试模块
      expect(find.text('测试文本'), findsOneWidget);
      expect(find.text('试听'), findsOneWidget);
      expect(find.text('停止'), findsOneWidget);
      expect(
        find.text('Hello, this is a TTS test. 你好，这是一段语音测试。'),
        findsOneWidget,
      );
    });

    testWidgets('选择系统 TTS 时不展示音色与 MiMo 配置', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tts_enabled': true,
        'tts_provider': TtsProvider.system.index,
      });

      await pumpSection(tester);

      expect(find.text('当前：系统'), findsOneWidget);
      expect(find.text('MiMo API Key'), findsNothing);
      expect(find.text('音色'), findsNothing);
      // 系统 TTS 支持音调
      expect(
        tester.widget<Slider>(find.byType(Slider).last).onChanged,
        isNotNull,
      );
      // 试听测试模块对所有服务商可用
      expect(find.text('试听'), findsOneWidget);
    });

    testWidgets('Edge 服务商不会显示 MiMo 音色', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tts_enabled': true,
        'tts_provider': TtsProvider.edge.index,
        // 历史脏数据：MiMo 音色被写进了 Edge 的音色槽
        'tts_voice': 'mimo_default',
      });

      await pumpSection(tester);

      expect(find.text('当前：Edge'), findsOneWidget);
      // 音色行回退到默认音色，不再显示 MiMo 音色
      expect(find.text('mimo_default'), findsNothing);
      expect(find.text('默认音色'), findsOneWidget);

      // 音色弹窗中不应出现 MiMo 预置音色
      await tester.tap(find.text('音色'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('选择音色'), findsAny);
      for (final voice in MimoTtsEngine.presetVoices) {
        expect(find.text(voice.id), findsNothing);
      }
    });

    testWidgets('MiMo 高级设置展开后 Base URL 标签完整可见', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tts_enabled': true,
        'tts_provider': TtsProvider.mimo.index,
      });
      // 放大测试视口，保证高级设置展开后输入框在屏幕内
      tester.view.physicalSize = const Size(600, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await pumpSection(tester);
      await tester.tap(find.text('MiMo 高级设置'));
      await tester.pumpAndSettle();

      // ExpansionTile（Expansible）用 ClipRect 裁剪展开内容，
      // 而 OutlineInputBorder 的悬浮 label 会绘制到输入框上边界之外，
      // 若 childrenPadding 顶部没有留白，label 上半部分会被裁掉。
      final clipRect = tester.getRect(
        find
            .descendant(
              of: find.byType(ExpansionTile),
              matching: find.byType(ClipRect),
            )
            .first,
      );
      final labelRect = tester.getRect(find.text('Base URL'));

      expect(labelRect.top, greaterThanOrEqualTo(clipRect.top));
      expect(labelRect.bottom, lessThanOrEqualTo(clipRect.bottom));
    });

    testWidgets('测试文本为空时点击试听给出提示', (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'tts_enabled': true,
        'tts_provider': TtsProvider.system.index,
      });

      await pumpSection(tester);

      await tester.enterText(find.byType(TextField).last, '');
      await tester.tap(find.text('试听'));
      await tester.pump();

      expect(find.text('请输入测试文本'), findsOneWidget);
    });
  });
}
