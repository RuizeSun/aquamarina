import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'log_service.dart';

class DatabaseService {
  static Database? _db;

  /// 句型练习批改结果缓存的建表语句（v9 新增）。
  ///
  /// 抽成常量以便 `onCreate` / `onUpgrade` 共用同一份 DDL（避免结构漂移），
  /// 单元测试也可直接引用它创建内存测试库。
  static const String sentenceEvalCacheTableSql = '''
          CREATE TABLE IF NOT EXISTS sentence_eval_cache (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            mode INTEGER NOT NULL DEFAULT 0,
            sentence_english TEXT NOT NULL,
            sentence_chinese TEXT NOT NULL,
            user_answer TEXT NOT NULL,
            score INTEGER NOT NULL,
            markup TEXT NOT NULL DEFAULT '',
            comment TEXT NOT NULL DEFAULT '',
            profile_name TEXT,
            model TEXT,
            hit_count INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            last_hit_at TEXT,
            UNIQUE(mode, sentence_english, sentence_chinese, user_answer)
          )
        ''';

  /// 缓存表按创建时间的索引（清理「N 天前缓存」时走索引）
  static const String sentenceEvalCacheIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_sentence_eval_cache_created_at '
      'ON sentence_eval_cache(created_at)';

  /// 错题本建表语句（v10）。
  ///
  /// 同一句子只保留一条记录：`wrong_count` 记录累计答错次数，
  /// `last_wrong_at` 记录最近一次答错时间（`created_at` 为首次收录时间）。
  static const String wrongSentencesTableSql = '''
          CREATE TABLE IF NOT EXISTS wrong_sentences (
            id TEXT PRIMARY KEY,
            sentence_id TEXT NOT NULL,
            set_id TEXT NOT NULL,
            english TEXT NOT NULL,
            chinese TEXT NOT NULL,
            score INTEGER NOT NULL,
            user_answer TEXT NOT NULL,
            mode INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            wrong_count INTEGER NOT NULL DEFAULT 1,
            last_wrong_at TEXT
          )
        ''';

  /// 错题本按句子的唯一索引（v10）：从数据库层面保证同一句子只有一条错题记录，
  /// 同时让「按句子查询错题」走索引。
  static const String wrongSentencesUniqueIndexSql =
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_wrong_sentences_sentence_unique '
      'ON wrong_sentences(sentence_id)';

  /// 「AI 生成句式集」预估矫正样本表（v11）。
  ///
  /// 每次实际请求结束后记录「预估 vs 实际」的 token 用量，以及影响用量的上下文
  /// （模型 / 温度 / 思考模式 / 思考强度 / 难度 / 每词句数 / 本批句子数）。
  /// 下次预估时按这些维度加权统计历史偏差，对预估做矫正。
  static const String aiEstimateSamplesTableSql = '''
          CREATE TABLE IF NOT EXISTS ai_estimate_samples (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            model TEXT NOT NULL,
            temperature REAL,
            enable_thinking INTEGER NOT NULL DEFAULT 0,
            reasoning_effort TEXT,
            difficulty TEXT,
            sentences_per_word INTEGER NOT NULL DEFAULT 1,
            sentence_count INTEGER NOT NULL DEFAULT 0,
            estimated_prompt_tokens INTEGER NOT NULL DEFAULT 0,
            estimated_completion_tokens INTEGER NOT NULL DEFAULT 0,
            prompt_tokens INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0
          )
        ''';

  /// 矫正样本按「模型 + 创建时间」查询的索引（按模型筛选近期样本时走索引）
  static const String aiEstimateSamplesIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_ai_estimate_samples_model_time '
      'ON ai_estimate_samples(model, created_at)';

  /// 初始化 Future，防止并发重复初始化
  /// 初始化失败时重置，允许后续调用重试
  static Future<Database>? _dbInitFuture;

  static Future<void> _initFfi() async {
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS)) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }
  }

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _dbInitFuture ??= _initDb().then((db) {
      _db = db;
      return db;
    });
    try {
      return await _dbInitFuture!;
    } catch (_) {
      _dbInitFuture = null;
      rethrow;
    }
  }

  static Future<Database> _initDb() async {
    await _initFfi();
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, 'aquamarina.db');
    logInfo('DatabaseService', '打开数据库: $dbPath');

    return await openDatabase(
      dbPath,
      version: 11,
      onCreate: (db, version) async {
        // ── 词库相关 ──
        await db.execute('''
          CREATE TABLE IF NOT EXISTS word_books (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            description TEXT,
            cover_path TEXT,
            cover_color INTEGER,
            author TEXT,
            word_count INTEGER DEFAULT 0,
            is_builtin INTEGER DEFAULT 0,
            created_at TEXT,
            updated_at TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE IF NOT EXISTS word_book_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id INTEGER NOT NULL,
            word TEXT NOT NULL COLLATE NOCASE,
            added_at TEXT,
            FOREIGN KEY (book_id) REFERENCES word_books(id) ON DELETE CASCADE,
            UNIQUE(book_id, word)
          )
        ''');

        await db.execute('''
          CREATE TABLE IF NOT EXISTS user_word_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            word TEXT NOT NULL UNIQUE COLLATE NOCASE,
            stage INTEGER DEFAULT 0,
            is_weak INTEGER DEFAULT 0,
            is_mastered INTEGER DEFAULT 0,
            next_review_date TEXT,
            last_reviewed_at TEXT,
            review_count INTEGER DEFAULT 0,
            created_at TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE IF NOT EXISTS wrong_words (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            word TEXT NOT NULL UNIQUE COLLATE NOCASE,
            scheduled_date TEXT NOT NULL,
            created_at TEXT
          )
        ''');

        await db.execute('''
          CREATE TABLE IF NOT EXISTS daily_activity (
            date TEXT PRIMARY KEY,
            words_learned INTEGER DEFAULT 0,
            words_reviewed INTEGER DEFAULT 0,
            correct_count INTEGER DEFAULT 0,
            wrong_count INTEGER DEFAULT 0,
            completed INTEGER DEFAULT 0,
            daily_goal INTEGER
          )
        ''');

        // ── 句型练习相关 ──
        await db.execute('''
          CREATE TABLE IF NOT EXISTS sentences (
            id TEXT PRIMARY KEY,
            set_id TEXT NOT NULL,
            english TEXT NOT NULL,
            chinese TEXT NOT NULL,
            extra_words TEXT,
            created_at TEXT
          )
        ''');

        await db.execute(wrongSentencesTableSql);

        await db.execute('''
          CREATE TABLE IF NOT EXISTS practiced_sentence_ids (
            set_id TEXT NOT NULL,
            sentence_id TEXT NOT NULL,
            PRIMARY KEY (set_id, sentence_id)
          )
        ''');

        // 句型练习批改结果缓存（相同句子 + 相同回答 + 相同模式可复用）
        await db.execute(sentenceEvalCacheTableSql);

        // ── 单词收藏与笔记相关 ──
        await db.execute('''
          CREATE TABLE IF NOT EXISTS word_notes (
            word TEXT PRIMARY KEY COLLATE NOCASE,
            note TEXT,
            is_favorited INTEGER NOT NULL DEFAULT 0,
            created_at TEXT,
            updated_at TEXT
          )
        ''');

        // ── 句子收藏与笔记相关 ──
        await db.execute('''
          CREATE TABLE IF NOT EXISTS sentence_notes (
            sentence_id TEXT PRIMARY KEY,
            set_id TEXT,
            english TEXT NOT NULL,
            chinese TEXT NOT NULL,
            note TEXT,
            is_favorited INTEGER NOT NULL DEFAULT 0,
            created_at TEXT,
            updated_at TEXT
          )
        ''');

        // 索引
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_book_entries_book_id ON word_book_entries(book_id)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_book_entries_word ON word_book_entries(word)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_records_next_review ON user_word_records(next_review_date)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_records_status_review ON user_word_records(is_mastered, next_review_date)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_wrong_words_scheduled ON wrong_words(scheduled_date)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_sentences_set_id ON sentences(set_id)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_wrong_sentences_set_id ON wrong_sentences(set_id)',
        );
        await db.execute(wrongSentencesUniqueIndexSql);
        await db.execute(sentenceEvalCacheIndexSql);

        // ── 学习时长统计相关 ──
        await db.execute('''
          CREATE TABLE IF NOT EXISTS learning_sessions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            session_type TEXT NOT NULL,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            duration_seconds INTEGER NOT NULL DEFAULT 0,
            date TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_learning_sessions_date ON learning_sessions(date)',
        );

        // ── 词汇测试历史记录相关 ──
        await db.execute('''
          CREATE TABLE IF NOT EXISTS vocab_test_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            date TEXT NOT NULL,
            total_count INTEGER NOT NULL,
            correct_count INTEGER NOT NULL,
            accuracy REAL NOT NULL,
            book_id INTEGER,
            book_title TEXT
          )
        ''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_vocab_test_history_date ON vocab_test_history(date)',
        );
        // ── AI 调用用量统计相关 ──
        await db.execute('''
          CREATE TABLE IF NOT EXISTS ai_usage_records (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            profile_id TEXT,
            profile_name TEXT,
            profile_type TEXT,
            model TEXT,
            request_mode TEXT NOT NULL DEFAULT 'chat',
            prompt_tokens INTEGER NOT NULL DEFAULT 0,
            cache_hit_tokens INTEGER NOT NULL DEFAULT 0,
            cache_miss_tokens INTEGER NOT NULL DEFAULT 0,
            completion_tokens INTEGER NOT NULL DEFAULT 0,
            total_tokens INTEGER NOT NULL DEFAULT 0,
            pricing_mode TEXT,
            price_unit TEXT,
            cache_hit_price REAL,
            cache_miss_price REAL,
            output_price REAL,
            request_price REAL,
            currency_symbol TEXT,
            currency_decimals INTEGER NOT NULL DEFAULT 2,
            currency_grouping INTEGER NOT NULL DEFAULT 1,
            cost REAL
          )
        ''');
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_ai_usage_created_at ON ai_usage_records(created_at)',
        );

        // ── AI 生成句式集「消耗预估」矫正样本 ──
        await db.execute(aiEstimateSamplesTableSql);
        await db.execute(aiEstimateSamplesIndexSql);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // 1 → 2：为 daily_activity 表增加 daily_goal 列（记录达标时的目标值）
        if (oldVersion < 2) {
          await _ensureColumn(db, 'daily_activity', 'daily_goal', 'INTEGER');
        }
        // 2 → 3：新增 word_notes 表（单词收藏与笔记）
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS word_notes (
              word TEXT PRIMARY KEY COLLATE NOCASE,
              note TEXT,
              is_favorited INTEGER NOT NULL DEFAULT 0,
              created_at TEXT,
              updated_at TEXT
            )
          ''');
        }
        // 3 → 4：新增 learning_sessions 表（学习时长统计）
        if (oldVersion < 4) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS learning_sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              session_type TEXT NOT NULL,
              started_at TEXT NOT NULL,
              ended_at TEXT,
              duration_seconds INTEGER NOT NULL DEFAULT 0,
              date TEXT NOT NULL
            )
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_learning_sessions_date ON learning_sessions(date)',
          );
        }
        // 4 → 5：新增 vocab_test_history 表（词汇测试历史记录）
        if (oldVersion < 5) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS vocab_test_history (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              date TEXT NOT NULL,
              total_count INTEGER NOT NULL,
              correct_count INTEGER NOT NULL,
              accuracy REAL NOT NULL,
              book_id INTEGER,
              book_title TEXT
            )
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_vocab_test_history_date ON vocab_test_history(date)',
          );
        }
        // 5 → 6：新增 sentence_notes 表（句子收藏与笔记）
        if (oldVersion < 6) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS sentence_notes (
              sentence_id TEXT PRIMARY KEY,
              set_id TEXT,
              english TEXT NOT NULL,
              chinese TEXT NOT NULL,
              note TEXT,
              is_favorited INTEGER NOT NULL DEFAULT 0,
              created_at TEXT,
              updated_at TEXT
            )
          ''');
        }
        // 6 → 7：新增 ai_usage_records 表（AI 调用用量与计费统计）
        if (oldVersion < 7) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS ai_usage_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              created_at TEXT NOT NULL,
              profile_id TEXT,
              profile_name TEXT,
              profile_type TEXT,
              model TEXT,
              request_mode TEXT NOT NULL DEFAULT 'chat',
              prompt_tokens INTEGER NOT NULL DEFAULT 0,
              cache_hit_tokens INTEGER NOT NULL DEFAULT 0,
              cache_miss_tokens INTEGER NOT NULL DEFAULT 0,
              completion_tokens INTEGER NOT NULL DEFAULT 0,
              total_tokens INTEGER NOT NULL DEFAULT 0,
              pricing_mode TEXT,
              price_unit TEXT,
              cache_hit_price REAL,
              cache_miss_price REAL,
              output_price REAL,
              request_price REAL,
              currency_symbol TEXT,
              currency_decimals INTEGER NOT NULL DEFAULT 2,
              currency_grouping INTEGER NOT NULL DEFAULT 1,
              cost REAL
            )
          ''');
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_ai_usage_created_at ON ai_usage_records(created_at)',
          );
        }
        // 7 → 8：为既有库补齐学习相关的业务索引（幂等，可安全重复执行）。
        // 全新安装会走 onCreate 的“索引”块；此处保证从旧版本升级上来的库
        // 同样具备这些索引，从而让“待复习/复习计划/每日统计”等热查询走索引。
        if (oldVersion < 8) {
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_book_entries_book_id ON word_book_entries(book_id)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_book_entries_word ON word_book_entries(word)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_records_next_review ON user_word_records(next_review_date)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_records_status_review ON user_word_records(is_mastered, next_review_date)',
          );
          await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_wrong_words_scheduled ON wrong_words(scheduled_date)',
          );
        }
        // 8 → 9：新增 sentence_eval_cache 表（句型练习批改结果缓存）
        if (oldVersion < 9) {
          await db.execute(sentenceEvalCacheTableSql);
          await db.execute(sentenceEvalCacheIndexSql);
        }
        // 9 → 10：错题本同一句子的重复记录合并为一条
        if (oldVersion < 10) {
          await migrateWrongSentencesToV10(db);
        }
        // 10 → 11：新增 ai_estimate_samples 表（AI 生成句式集的预估矫正样本）
        if (oldVersion < 11) {
          await db.execute(aiEstimateSamplesTableSql);
          await db.execute(aiEstimateSamplesIndexSql);
        }
      },
    );
  }

  /// v9 → v10 迁移：错题本支持「同一句子只保留一条记录」。
  ///
  /// 1. 补列：`wrong_count`（累计错误次数）、`last_wrong_at`（最近一次答错时间）
  /// 2. 归一化：无句子 ID 的历史记录用英文原文生成稳定键（`bytext:...`），
  ///    避免不同句子共用空键而被误合并 / 误删除
  /// 3. 合并：同一句子的多条记录累计错误次数，保留最近一次（得分/回答/模式/时间），
  ///    `created_at` 回正为最早一次（首次收录时间）
  /// 4. 建唯一索引，从数据库层面防止再次产生重复
  ///
  /// 抽成独立方法以便单元测试直接对旧库结构验证迁移结果。
  static Future<void> migrateWrongSentencesToV10(Database db) async {
    // 兼容极旧版本库：确保表结构存在（已存在时为 no-op，不会覆盖数据）
    await db.execute(wrongSentencesTableSql);
    await _ensureColumn(
      db,
      'wrong_sentences',
      'wrong_count',
      'INTEGER NOT NULL DEFAULT 1',
    );
    await _ensureColumn(db, 'wrong_sentences', 'last_wrong_at', 'TEXT');

    // 无 ID 的句子：与收藏 / 笔记一致，用英文原文生成稳定键
    await db.execute(
      "UPDATE wrong_sentences SET sentence_id = 'bytext:' || english "
      "WHERE sentence_id = ''",
    );
    // 旧记录的最近一次答错时间回填为收录时间
    await db.execute(
      'UPDATE wrong_sentences SET last_wrong_at = created_at '
      'WHERE last_wrong_at IS NULL',
    );
    // 同一句子：错误次数取记录条数（与已累计次数取较大值，重复执行不丢次数）；
    // 最近答错时间取最大；created_at 统一为最早一次（首次收录时间）
    await db.execute('''
      UPDATE wrong_sentences SET
        wrong_count = MAX(
          (
            SELECT COUNT(*) FROM wrong_sentences AS d
            WHERE d.sentence_id = wrong_sentences.sentence_id
          ),
          (
            SELECT COALESCE(MAX(d.wrong_count), 1)
            FROM wrong_sentences AS d
            WHERE d.sentence_id = wrong_sentences.sentence_id
          )
        ),
        last_wrong_at = (
          SELECT MAX(d.created_at) FROM wrong_sentences AS d
          WHERE d.sentence_id = wrong_sentences.sentence_id
        ),
        created_at = (
          SELECT MIN(d.created_at) FROM wrong_sentences AS d
          WHERE d.sentence_id = wrong_sentences.sentence_id
        )
    ''');
    // 删除重复记录：每个句子只保留一条。
    // 同一句子的记录已统一 created_at，故按 id 取最大者 ——
    // 错题 id 为毫秒时间戳字符串，最大即最近一次答错，保留的得分/回答也最新。
    await db.execute('''
      DELETE FROM wrong_sentences WHERE EXISTS (
        SELECT 1 FROM wrong_sentences AS newer
        WHERE newer.sentence_id = wrong_sentences.sentence_id
          AND newer.id > wrong_sentences.id
      )
    ''');
    await db.execute(wrongSentencesUniqueIndexSql);
  }

  /// 检查表中是否存在指定列，缺失则添加（幂等，可安全重复调用）
  static Future<void> _ensureColumn(
    Database db,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await db.rawQuery('PRAGMA table_info($table)');
    final exists = columns.any((c) => c['name'] == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }

  static Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
    // 同时重置初始化 Future，避免再次访问时返回已关闭的连接
    _dbInitFuture = null;
  }

  /// 导出一份数据库的一致快照到 [targetPath]。
  ///
  /// 使用 SQLite 的 `VACUUM INTO` 命令，由 SQLite 引擎在内部生成
  /// 与主连接一致（含 WAL 中未合并事务）的独立副本，
  /// 全程保持主连接打开，不会产生「关闭 → 拷贝 → 重开」的窗口期，
  /// 因此其他异步写入（如 StudyTimerService 的定时持久化）不受影响。
  ///
  /// 注意：`VACUUM INTO` 的目标必须是不存在的文件，否则会抛错。
  static Future<void> exportDatabaseCopy(String targetPath) async {
    final db = await database;
    await db.rawQuery('VACUUM INTO ?', [targetPath]);
  }

  /// 当前数据库文件的完整路径。
  static Future<String> get databasePath async {
    final dir = await getApplicationSupportDirectory();
    return p.join(dir.path, 'aquamarina.db');
  }
}
