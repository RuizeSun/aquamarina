import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'log_service.dart';
import '../models/sync_op.dart';
import 'sync_schema.dart';
import 'sync_table_spec.dart';

class DatabaseService {
  /// 业务数据库当前 Schema 版本（备份导入预检也使用这个值）
  static const int schemaVersion = 18;

  /// 句式集元数据表（v14 从 SharedPreferences 迁入，便于事务与增量同步）。
  static const String sentenceSetsTableSql = '''
          CREATE TABLE IF NOT EXISTS sentence_sets (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            sentence_count INTEGER NOT NULL DEFAULT 0,
            created_at TEXT,
            updated_at TEXT
          )
        ''';

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

  /// 已练习（练过即计入，不论对错）句子表的建表语句（v12 新增）。
  ///
  /// 与 `practiced_sentence_ids` 的区别：后者只记录「得分超过阈值」的句子，
  /// 用于「不重复练习」跳过；本表记录所有练习过的句子，用于展示练习进度。
  static const String attemptedSentenceIdsTableSql = '''
          CREATE TABLE IF NOT EXISTS attempted_sentence_ids (
            set_id TEXT NOT NULL,
            sentence_id TEXT NOT NULL,
            PRIMARY KEY (set_id, sentence_id)
          )
        ''';

  /// v11 → v12 迁移用的回填语句：把历史上「已答对」的句子补进已练习表
  /// （答对必然练过）。幂等，可安全重复执行。
  static const String attemptedSentenceIdsBackfillSql =
      'INSERT OR IGNORE INTO attempted_sentence_ids (set_id, sentence_id) '
      'SELECT set_id, sentence_id FROM practiced_sentence_ids';

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
      version: schemaVersion,
      onConfigure: (db) async {
        // 外键约束默认关闭；开启后 ON DELETE CASCADE 才会生效
        await db.execute('PRAGMA foreign_keys = ON');
        // WAL 提升读写并发与写入性能
        await db.rawQuery('PRAGMA journal_mode = WAL');
      },
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

        // 已练习（练过即计入）句子：用于展示练习进度
        await db.execute(attemptedSentenceIdsTableSql);

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

        // ── v13：同步就绪 schema（uuid / sort_index / oplog / 触发器） ──
        await migrateToV13(db);
        // ── v15：设备 head / state 水位与 GC 所需的列 ──
        await migrateToV15(db);
        // ── v16：oplog 记录写入墙钟，导出时生成 HLC ──
        await migrateToV16(db);
        // ── v17：批量 op 表 ──
        await migrateToV17(db);
        // ── v18：后端标识与快照来源水位 ──
        await migrateToV18(db);
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
        // 11 → 12：新增 attempted_sentence_ids 表（练习进度：练过即计入），
        // 并把历史上「已答对」的句子回填进去（答对必然练过）。
        if (oldVersion < 12) {
          await db.execute(attemptedSentenceIdsTableSql);
          await db.execute(attemptedSentenceIdsBackfillSql);
        }
        // 12 → 13：同步就绪 schema（稳定 ID、顺序键、oplog 与触发器）
        if (oldVersion < 13) {
          await migrateToV13(db);
        }
        // 13 → 14：句式集元数据入库（便于事务与增量同步）
        if (oldVersion < 14) {
          await migrateToV14(db);
        }
        // 14 → 15：设备 head / state 水位、chunk HLC 边界与应用记录 GC
        if (oldVersion < 15) {
          await migrateToV15(db);
        }
        // 15 → 16：oplog 捕获时间列与触发器重建
        if (oldVersion < 16) {
          await migrateToV16(db);
        }
        // 16 → 17：批量 op 表
        if (oldVersion < 17) {
          await migrateToV17(db);
        }
        // 17 → 18：后端标识与快照来源水位
        if (oldVersion < 18) {
          await migrateToV18(db);
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

  /// v12 → v13：为同步准备稳定标识、顺序键与捕获层。
  ///
  /// 幂等：新装、升级、重复执行均安全。内容：
  /// 1. 补列：`word_books.uuid`、`word_book_entries.book_uuid`、
  ///    `learning_sessions.uuid`、`vocab_test_history.uuid`、
  ///    `sentences.sort_index`；
  /// 2. 回填：为存量行生成 UUID、从词书回填条目的 book_uuid、按 rowid 回填句子顺序；
  /// 3. 索引：跨设备稳定键与顺序查询；
  /// 4. 安装同步系统表、oplog 表与触发器。
  static Future<void> migrateToV13(Database db) async {
    await db.execute(sentenceSetsTableSql);
    await _ensureColumn(db, 'word_books', 'uuid', 'TEXT');
    await _ensureColumn(db, 'word_book_entries', 'book_uuid', 'TEXT');
    await _ensureColumn(db, 'learning_sessions', 'uuid', 'TEXT');
    await _ensureColumn(db, 'vocab_test_history', 'uuid', 'TEXT');
    await _ensureColumn(db, 'sentences', 'sort_index', 'REAL');

    await _backfillUuid(db, 'word_books');
    await _backfillUuid(db, 'learning_sessions');
    await _backfillUuid(db, 'vocab_test_history');
    await _backfillBookUuid(db);
    await _backfillSentenceSortIndex(db);

    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_word_books_uuid '
      'ON word_books(uuid)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_learning_sessions_uuid '
      'ON learning_sessions(uuid)',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_vocab_test_history_uuid '
      'ON vocab_test_history(uuid)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_book_entries_book_uuid '
      'ON word_book_entries(book_uuid)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_sentences_set_sort '
      'ON sentences(set_id, sort_index)',
    );

    await SyncSchema.ensure(db);
    await _ensureColumn(
      db,
      'sync_meta',
      'baseline_hlc',
      "TEXT NOT NULL DEFAULT ''",
    );
    await _ensureColumn(
      db,
      'sync_meta',
      'capture_enabled',
      'INTEGER NOT NULL DEFAULT 0',
    );
    logInfo('DatabaseService', 'v13 同步 schema 迁移完成');
  }

  /// v13 → v14：句式集元数据表 + 同步触发器安装。
  ///
  /// Prefs → DB 的数据搬运由 `SentenceSetService.load()` 惰性完成，
  /// 这样旧备份恢复后也能触发迁移。
  static Future<void> migrateToV14(Database db) async {
    await db.execute(sentenceSetsTableSql);
    await SyncSchema.ensure(db);
    logInfo('DatabaseService', 'v14 句式集 schema 迁移完成');
  }

  /// v14 → v15：增量同步的设备 head / state 水位与 GC 支撑列。
  ///
  /// `SyncSchema.ensure` 会幂等补齐所有新列（含旧库升级），
  /// 这里额外把已有 `sync_chunks` 的起始 HLC 从对象键回填，
  /// 以便 GC 能按 HLC 水位判断哪些 chunk 已经无人需要。
  static Future<void> migrateToV15(Database db) async {
    await SyncSchema.ensure(db);
    final rows = await db.query(
      'sync_chunks',
      columns: ['device_id', 'chunk_key', 'min_hlc'],
      where: 'min_hlc IS NULL OR min_hlc = ?',
      whereArgs: [''],
    );
    for (final row in rows) {
      final key = row['chunk_key'];
      if (key is! String) continue;
      final hlc = _chunkStartHlc(key);
      if (hlc == null) continue;
      await db.update(
        'sync_chunks',
        {'min_hlc': hlc.value, 'max_hlc': hlc.value},
        where: 'device_id = ? AND chunk_key = ?',
        whereArgs: [row['device_id'], key],
      );
    }
    await _backfillSyncState(db);
    logInfo('DatabaseService', 'v15 云同步水位 schema 迁移完成');
  }

  /// v15 → v16：oplog 增加 `captured_at_ms`，并重建触发器。
  ///
  /// 历史待上传行没有捕获时间：保持 NULL，由导出逻辑回退到当前时间。
  static Future<void> migrateToV16(Database db) async {
    await SyncSchema.reinstallTriggers(db);
    // 已有待上传行若已分配 HLC，可用它近似捕获时间；未分配的行保持 NULL，
    // 由导出逻辑回退到当前时间。
    for (final spec in SyncSpecs.all) {
      try {
        await db.rawUpdate(
          'UPDATE "${spec.oplogTable}" '
          'SET captured_at_ms = hlc_ms '
          'WHERE captured_at_ms IS NULL AND hlc_ms IS NOT NULL',
        );
      } catch (_) {
        // 旧库表结构异常时忽略，后续同步仍可运行
      }
    }
    logInfo('DatabaseService', 'v16 同步捕获时间 schema 迁移完成');
  }

  /// v16 → v17：批量 op 表（大批量导入压缩为单条 op）。
  static Future<void> migrateToV17(Database db) async {
    await SyncSchema.ensure(db);
    logInfo('DatabaseService', 'v17 批量 op schema 迁移完成');
  }

  /// v17 → v18：后端标识与快照来源水位。
  static Future<void> migrateToV18(Database db) async {
    await SyncSchema.ensure(db);
    logInfo('DatabaseService', 'v18 后端标识与恢复水位 schema 迁移完成');
  }

  /// 从已有 `sync_chunks` 反推每个来源设备的水位，避免升级后
  /// 已同步设备因为 `sync_state` 为空而长期阻塞云端 GC。
  static Future<void> _backfillSyncState(Database db) async {
    final rows = await db.query(
      'sync_chunks',
      columns: ['device_id', 'chunk_key', 'min_hlc'],
      where: 'min_hlc IS NOT NULL',
    );
    final latest = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final device = row['device_id'];
      final hlc = row['min_hlc'];
      if (device is! String || device.isEmpty || hlc is! String) continue;
      final current = latest[device];
      if (current == null || hlc.compareTo(current['min_hlc'] as String) > 0) {
        latest[device] = row;
      }
    }
    for (final entry in latest.entries) {
      await db.insert('sync_state', {
        'device_id': entry.key,
        'last_seq': 0,
        'last_hlc': entry.value['min_hlc'],
        'last_chunk_key': entry.value['chunk_key'],
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  /// 从 `chunks/{msHex}-{counterHex}-{sha}.jsonl` 解析 chunk 起始 HLC。
  static SyncHlc? _chunkStartHlc(String key) {
    final name = key.split('/').last;
    final parts = name.split('-');
    if (parts.length < 2) return null;
    final ms = int.tryParse(parts[0], radix: 16);
    final counter = int.tryParse(parts[1], radix: 16);
    if (ms == null || counter == null) return null;
    return SyncHlc(ms, counter);
  }

  /// 为表中 uuid 为空的行生成 UUID（按 rowid 更新，幂等）。
  static Future<void> _backfillUuid(Database db, String table) async {
    final rows = await db.rawQuery(
      'SELECT rowid AS rid FROM "$table" '
      'WHERE "uuid" IS NULL OR "uuid" = \'\'',
    );
    if (rows.isEmpty) return;
    for (final row in rows) {
      await db.update(
        table,
        {'uuid': const Uuid().v4()},
        where: 'rowid = ?',
        whereArgs: [row['rid']],
      );
    }
  }

  /// 从 word_books.uuid 回填 word_book_entries.book_uuid。
  static Future<void> _backfillBookUuid(Database db) async {
    final rows = await db.rawQuery(
      'SELECT rowid AS rid, book_id FROM word_book_entries '
      'WHERE "book_uuid" IS NULL OR "book_uuid" = \'\'',
    );
    for (final row in rows) {
      final bookId = row['book_id'];
      if (bookId == null) continue;
      final books = await db.query(
        'word_books',
        columns: ['uuid'],
        where: 'id = ?',
        whereArgs: [bookId],
        limit: 1,
      );
      if (books.isEmpty) continue;
      final uuid = books.first['uuid'] as String?;
      if (uuid == null || uuid.isEmpty) continue;
      await db.update(
        'word_book_entries',
        {'book_uuid': uuid},
        where: 'rowid = ?',
        whereArgs: [row['rid']],
      );
    }
  }

  /// 按 rowid 顺序为每个句式集的句子回填 `sort_index`。
  ///
  /// 只处理 `sort_index IS NULL` 的行，重复执行不会重排已有顺序。
  static Future<void> _backfillSentenceSortIndex(Database db) async {
    final sets = await db.rawQuery('SELECT DISTINCT set_id FROM sentences');
    for (final setRow in sets) {
      final setId = setRow['set_id'];
      if (setId is! String) continue;
      final maxRows = await db.rawQuery(
        'SELECT COALESCE(MAX(sort_index), 0) AS m FROM sentences '
        'WHERE set_id = ?',
        [setId],
      );
      final maxValue = (maxRows.first['m'] as num?)?.toDouble() ?? 0;
      final rows = await db.rawQuery(
        'SELECT rowid AS rid FROM sentences '
        'WHERE set_id = ? AND sort_index IS NULL ORDER BY rowid ASC',
        [setId],
      );
      var index = maxValue + 1;
      for (final row in rows) {
        await db.update(
          'sentences',
          {'sort_index': index},
          where: 'rowid = ?',
          whereArgs: [row['rid']],
        );
        index += 1;
      }
    }
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
