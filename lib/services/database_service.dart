import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'log_service.dart';

class DatabaseService {
  static Database? _db;

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
      version: 6,
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

        await db.execute('''
          CREATE TABLE IF NOT EXISTS wrong_sentences (
            id TEXT PRIMARY KEY,
            sentence_id TEXT NOT NULL,
            set_id TEXT NOT NULL,
            english TEXT NOT NULL,
            chinese TEXT NOT NULL,
            score INTEGER NOT NULL,
            user_answer TEXT NOT NULL,
            mode INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE IF NOT EXISTS practiced_sentence_ids (
            set_id TEXT NOT NULL,
            sentence_id TEXT NOT NULL,
            PRIMARY KEY (set_id, sentence_id)
          )
        ''');

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
          'CREATE INDEX IF NOT EXISTS idx_wrong_words_scheduled ON wrong_words(scheduled_date)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_sentences_set_id ON sentences(set_id)',
        );
        await db.execute(
          'CREATE INDEX IF NOT EXISTS idx_wrong_sentences_set_id ON wrong_sentences(set_id)',
        );

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
      },
    );
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
