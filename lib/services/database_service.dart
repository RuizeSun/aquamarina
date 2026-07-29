import 'package:flutter/foundation.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class DatabaseService {
  static Database? _db;

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
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    await _initFfi();
    final dir = await getApplicationSupportDirectory();
    final dbPath = p.join(dir.path, 'aquamarina.db');

    return await openDatabase(
      dbPath,
      version: 3,
      onCreate: (db, version) async {
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
            completed INTEGER DEFAULT 0
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
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS daily_activity (
              date TEXT PRIMARY KEY,
              words_learned INTEGER DEFAULT 0,
              words_reviewed INTEGER DEFAULT 0,
              correct_count INTEGER DEFAULT 0,
              wrong_count INTEGER DEFAULT 0,
              completed INTEGER DEFAULT 0
            )
          ''');
        }
      },
    );
  }

  static Future<void> close() async {
    if (_db != null) {
      await _db!.close();
      _db = null;
    }
  }
}
