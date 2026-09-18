import 'package:aquamarina/models/ai_profile.dart';
import 'package:aquamarina/models/sentence_difficulty.dart';
import 'package:aquamarina/services/ai_estimate_calibration_service.dart';
import 'package:aquamarina/services/ai_profile_service.dart';
import 'package:aquamarina/services/ai_sentence_generate_service.dart';
import 'package:aquamarina/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 用可注入的假配置服务替代真实实现，避免在单测里触碰安全存储与网络。
class _FakeProfileService extends AiProfileService {
  final AiProfile? profile;

  _FakeProfileService(this.profile);

  @override
  Future<void> load() async {}

  @override
  AiProfile? get defaultProfile => profile;
}

AiProfile _openAiProfile() => const AiProfile(
  id: 'p1',
  name: '测试配置',
  type: AiProfileType.openai,
  apiKey: 'sk-test',
  model: 'gpt-4o-mini',
  maxTokens: 8192,
  temperature: 0.7,
);

List<WordPromptEntry> _entries(int count) =>
    List.generate(count, (i) => WordPromptEntry(word: 'word$i', gloss: '释义$i'));

AiEstimateSample _sample({
  String model = 'gpt-4o-mini',
  double? temperature = 0.7,
  bool thinking = false,
  String? effort,
  SentenceDifficulty difficulty = SentenceDifficulty.starter,
  int sentenceCount = 12,
  int estimatedPrompt = 1000,
  int estimatedCompletion = 600,
  int prompt = 1100,
  int completion = 900,
  DateTime? createdAt,
}) => AiEstimateSample(
  createdAt: createdAt ?? DateTime(2026, 1, 1),
  model: model,
  temperature: temperature,
  thinking: thinking,
  reasoningEffort: effort,
  difficulty: difficulty,
  sentencesPerWord: 1,
  sentenceCount: sentenceCount,
  estimatedPromptTokens: estimatedPrompt,
  estimatedCompletionTokens: estimatedCompletion,
  promptTokens: prompt,
  completionTokens: completion,
);

AiEstimateContext _context({
  String model = 'gpt-4o-mini',
  double? temperature = 0.7,
  bool thinking = false,
  String? effort,
  SentenceDifficulty difficulty = SentenceDifficulty.starter,
  int sentenceCount = 12,
}) => AiEstimateContext(
  model: model,
  temperature: temperature,
  thinking: thinking,
  reasoningEffort: effort,
  difficulty: difficulty,
  sentenceCount: sentenceCount,
);

void main() {
  final now = DateTime(2026, 1, 1);

  group('AiEstimateCalibration 单维度相似度', () {
    test('温度：都未设置 / 相同为 1，差异越大越低', () {
      expect(AiEstimateCalibration.temperatureSimilarity(null, null), 1.0);
      expect(AiEstimateCalibration.temperatureSimilarity(0.7, 0.7), 1.0);
      expect(AiEstimateCalibration.temperatureSimilarity(null, 0.7), 0.5);
      expect(
        AiEstimateCalibration.temperatureSimilarity(0.5, 0.75),
        closeTo(0.5, 1e-9),
      );
      expect(AiEstimateCalibration.temperatureSimilarity(0.0, 0.9), 0.0);
    });

    test('思考强度：未开启思考时不参与，不同取值权重更低', () {
      expect(
        AiEstimateCalibration.effortSimilarity(null, 'high', thinking: false),
        1.0,
      );
      expect(
        AiEstimateCalibration.effortSimilarity('high', 'high', thinking: true),
        1.0,
      );
      expect(
        AiEstimateCalibration.effortSimilarity(null, 'high', thinking: true),
        0.5,
      );
      expect(
        AiEstimateCalibration.effortSimilarity('high', 'max', thinking: true),
        0.25,
      );
    });

    test('难度：同档为 1，相距越远越低', () {
      expect(
        AiEstimateCalibration.difficultySimilarity(
          SentenceDifficulty.starter,
          SentenceDifficulty.starter,
        ),
        1.0,
      );
      final near = AiEstimateCalibration.difficultySimilarity(
        SentenceDifficulty.starter,
        SentenceDifficulty.basic,
      );
      final far = AiEstimateCalibration.difficultySimilarity(
        SentenceDifficulty.starter,
        SentenceDifficulty.mastery,
      );
      expect(near, greaterThan(far));
      expect(far, greaterThanOrEqualTo(0.1));
    });

    test('相似长度：句子数比值，差异过大时保留极小权重', () {
      expect(AiEstimateCalibration.lengthSimilarity(12, 12), 1.0);
      expect(AiEstimateCalibration.lengthSimilarity(6, 12), 0.5);
      expect(AiEstimateCalibration.lengthSimilarity(1, 100), 0.1);
      expect(AiEstimateCalibration.lengthSimilarity(0, 12), 0.5);
    });

    test('时间衰减：半衰期 14 天，久远样本保底权重', () {
      expect(AiEstimateCalibration.recencyWeight(now, now), closeTo(1.0, 1e-9));
      expect(
        AiEstimateCalibration.recencyWeight(
          now.subtract(const Duration(days: 14)),
          now,
        ),
        closeTo(0.5, 1e-3),
      );
      expect(
        AiEstimateCalibration.recencyWeight(
          now.subtract(const Duration(days: 365)),
          now,
        ),
        AiEstimateCalibration.minRecencyWeight,
      );
    });
  });

  group('AiEstimateCalibration 多维度加权', () {
    test('不同模型是硬门槛：权重为 0，不参与矫正', () {
      final weight = AiEstimateCalibration.sampleWeight(
        _sample(model: 'gpt-4o'),
        _context(model: 'gpt-4o-mini'),
        now,
      );
      expect(weight, 0);

      final calibration = AiEstimateCalibration.compute(
        samples: [_sample(model: 'gpt-4o')],
        context: _context(model: 'gpt-4o-mini'),
        now: now,
      );
      expect(calibration.applied, isFalse);
      expect(calibration.matchedSamples, 0);
    });

    test('思考模式不一致会显著降权', () {
      final matched = AiEstimateCalibration.sampleWeight(
        _sample(thinking: true, effort: 'high'),
        _context(thinking: true, effort: 'high'),
        now,
      );
      final mismatched = AiEstimateCalibration.sampleWeight(
        _sample(thinking: false),
        _context(thinking: true, effort: 'high'),
        now,
      );
      expect(matched, greaterThan(mismatched * 3));
    });

    test('难度 / 长度差异越大权重越低', () {
      final same = AiEstimateCalibration.sampleWeight(
        _sample(),
        _context(),
        now,
      );
      final differentDifficulty = AiEstimateCalibration.sampleWeight(
        _sample(difficulty: SentenceDifficulty.mastery),
        _context(),
        now,
      );
      final differentLength = AiEstimateCalibration.sampleWeight(
        _sample(sentenceCount: 1),
        _context(sentenceCount: 12),
        now,
      );
      expect(differentDifficulty, lessThan(same));
      expect(differentLength, lessThan(same));
    });
  });

  group('AiEstimateCalibration.compute', () {
    test('无样本时不矫正', () {
      final calibration = AiEstimateCalibration.compute(
        samples: const [],
        context: _context(),
        now: now,
      );
      expect(calibration.applied, isFalse);
      expect(calibration.promptFactor, 1.0);
      expect(calibration.completionFactor, 1.0);
      expect(calibration.confidence, 0);
    });

    test('同维度样本按观测偏差矫正，样本越多越接近真实比例', () {
      AiEstimateCalibration calibrationWith(int count) {
        final samples = List.generate(count, (i) => _sample(createdAt: now));
        return AiEstimateCalibration.compute(
          samples: samples,
          context: _context(),
          now: now,
        );
      }

      final two = calibrationWith(2);
      final twenty = calibrationWith(20);

      // 观测比例：输入 1100/1000 = 1.1，输出 900/600 = 1.5
      expect(two.applied, isTrue);
      expect(two.promptFactor, greaterThan(1.0));
      expect(two.promptFactor, lessThan(1.1));
      expect(two.completionFactor, greaterThan(1.0));
      expect(two.completionFactor, lessThan(1.5));
      expect(two.matchedSamples, 2);

      // 随着样本增加，矫正系数单调逼近真实偏差
      expect(twenty.confidence, greaterThan(two.confidence));
      expect(
        (twenty.completionFactor - 1.5).abs(),
        lessThan((two.completionFactor - 1.5).abs()),
      );
      // 5 条样本时系数为 1 + 0.5 * 5/8 = 1.3125（可精确断言）
      expect(calibrationWith(5).completionFactor, closeTo(1.3125, 1e-9));
    });

    test('样本权重不足时保持不矫正', () {
      final calibration = AiEstimateCalibration.compute(
        samples: [_sample(sentenceCount: 1)],
        context: _context(sentenceCount: 12),
        now: now,
      );
      // 1 * 1/12 ≈ 0.083，低于 minEffectiveSamples
      expect(calibration.applied, isFalse);
    });

    test('矫正系数被限制在安全区间内', () {
      final calibration = AiEstimateCalibration.compute(
        samples: List.generate(
          50,
          (i) => _sample(createdAt: now, prompt: 100, completion: 100),
        ),
        context: _context(),
        now: now,
      );
      // 观测比例极低，但输入系数不低于 0.5、输出不低于 0.4
      expect(calibration.promptFactor, greaterThanOrEqualTo(0.5));
      expect(calibration.completionFactor, greaterThanOrEqualTo(0.4));
    });

    test('无效样本（tokens 为 0）被忽略', () {
      final calibration = AiEstimateCalibration.compute(
        samples: [
          _sample(createdAt: now, prompt: 0, completion: 0),
          _sample(createdAt: now),
        ],
        context: _context(),
        now: now,
      );
      expect(calibration.matchedSamples, 1);
    });

    test('correctPrompt / correctCompletion 不会产生负数', () {
      const calibration = AiEstimateCalibration(
        promptFactor: 0.5,
        completionFactor: 0.4,
        effectiveSamples: 1,
        matchedSamples: 1,
        confidence: 0.25,
      );
      expect(calibration.correctPrompt(10), 5);
      expect(calibration.correctCompletion(10), 4);
      expect(calibration.correctPrompt(0), 0);
    });
  });

  group('AiEstimateCalibrationService 读写', () {
    late Database db;
    late AiEstimateCalibrationService writer;

    setUp(() async {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      db = await databaseFactory.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await db.execute(DatabaseService.aiEstimateSamplesTableSql);
            await db.execute(DatabaseService.aiEstimateSamplesIndexSql);
          },
        ),
      );
      writer = AiEstimateCalibrationService.withDatabase(() async => db);
    });

    tearDown(() async {
      await db.close();
    });

    test('记录样本后可被新实例加载并用于矫正', () async {
      await writer.recordSample(
        model: 'gpt-4o-mini',
        temperature: 0.7,
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
        sentenceCount: 12,
        estimatedPromptTokens: 1000,
        estimatedCompletionTokens: 600,
        promptTokens: 1100,
        completionTokens: 900,
      );
      expect(writer.samples.length, 1);
      expect(await writer.count(), 1);

      final reader = AiEstimateCalibrationService.withDatabase(() async => db);
      await reader.load();
      expect(reader.isLoaded, isTrue);
      expect(reader.samples.length, 1);
      expect(reader.samples.first.model, 'gpt-4o-mini');
      expect(reader.samples.first.difficulty, SentenceDifficulty.starter);
      expect(reader.samples.first.thinking, isFalse);

      final calibration = reader.calibrationFor(_context());
      expect(calibration.applied, isTrue);
      expect(calibration.promptFactor, greaterThan(1.0));
      expect(calibration.completionFactor, greaterThan(1.0));

      await reader.clear();
      expect(await reader.count(), 0);
      expect(reader.samples, isEmpty);
    });

    test('无效样本不落库', () async {
      await writer.recordSample(
        model: 'gpt-4o-mini',
        temperature: 0.7,
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
        sentenceCount: 12,
        estimatedPromptTokens: 0,
        estimatedCompletionTokens: 0,
        promptTokens: 0,
        completionTokens: 0,
      );
      expect(await writer.count(), 0);
      expect(writer.samples, isEmpty);
    });

    test('load 只加载保留期内的近期样本', () async {
      await writer.recordSample(
        model: 'gpt-4o-mini',
        temperature: 0.7,
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
        sentenceCount: 12,
        estimatedPromptTokens: 1000,
        estimatedCompletionTokens: 600,
        promptTokens: 1100,
        completionTokens: 900,
        createdAt: DateTime.now().subtract(const Duration(days: 200)),
      );
      // 写入时数据合法，落库应成功
      expect(await writer.count(), 1);

      final reader = AiEstimateCalibrationService.withDatabase(() async => db);
      await reader.load();
      expect(reader.samples, isEmpty);
    });
  });

  group('AiSentenceGenerator 预估接入矫正', () {
    final profile = _openAiProfile();

    test('存在历史样本时按矫正系数调整预估 tokens', () {
      // 样本需与本次预估上下文一致：长度为 5 句、近期（recency 不衰减）
      final calibration = AiEstimateCalibrationService.withSamples(
        List.generate(
          12,
          (i) => _sample(createdAt: DateTime.now(), sentenceCount: 5),
        ),
      );
      final generator = AiSentenceGenerator(
        profileService: _FakeProfileService(profile),
        calibrationService: calibration,
      );

      final estimate = generator.estimate(
        profile: profile,
        entries: _entries(5),
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );

      expect(estimate.calibrationApplied, isTrue);
      expect(estimate.calibrationSamples, 12);
      expect(estimate.calibrationPromptFactor, greaterThan(1.0));
      expect(estimate.calibrationCompletionFactor, greaterThan(1.0));
      expect(
        estimate.promptTokens,
        (estimate.rawPromptTokens * estimate.calibrationPromptFactor).round(),
      );
      expect(
        estimate.completionTokens,
        (estimate.rawCompletionTokens * estimate.calibrationCompletionFactor)
            .round(),
      );
    });

    test('无历史样本时保持原始经验估算', () {
      final generator = AiSentenceGenerator(
        profileService: _FakeProfileService(profile),
        calibrationService: AiEstimateCalibrationService.withSamples(const []),
      );

      final estimate = generator.estimate(
        profile: profile,
        entries: _entries(5),
        difficulty: SentenceDifficulty.starter,
        sentencesPerWord: 1,
      );

      expect(estimate.calibrationApplied, isFalse);
      expect(estimate.calibrationSamples, 0);
      expect(estimate.promptTokens, estimate.rawPromptTokens);
      expect(estimate.completionTokens, estimate.rawCompletionTokens);
    });
  });
}
