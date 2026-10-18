import 'package:aquamarina/services/cloud_sync_merge_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'sync_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database local;
  late Database remote;

  setUp(() async {
    local = await openSyncTestDb();
    remote = await openSyncTestDb();
  });

  tearDown(() async {
    await local.close();
    await remote.close();
  });

  test('合并保留双方、较新字段胜出、计数器取最大值', () async {
    await local.insert('word_notes', {
      'word': 'apple',
      'note': '本机较新',
      'is_favorited': 1,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-10-10T00:00:00Z',
    });
    await local.insert('word_notes', {
      'word': 'cherry',
      'note': '仅本机有',
      'is_favorited': 0,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-10-01T00:00:00Z',
    });
    await remote.insert('word_notes', {
      'word': 'apple',
      'note': '云端较旧',
      'is_favorited': 0,
      'created_at': '2026-01-01T00:00:00Z',
      'updated_at': '2026-10-01T00:00:00Z',
    });
    await remote.insert('word_notes', {
      'word': 'banana',
      'note': '仅云端有',
      'is_favorited': 1,
      'created_at': '2026-02-01T00:00:00Z',
      'updated_at': '2026-10-02T00:00:00Z',
    });

    await local.insert('user_word_records', {
      'word': 'apple',
      'stage': 1,
      'is_weak': 0,
      'is_mastered': 0,
      'next_review_date': '2026-10-10',
      'last_reviewed_at': '2026-10-10T00:00:00Z',
      'review_count': 5,
      'created_at': '2026-01-01T00:00:00Z',
    });
    await remote.insert('user_word_records', {
      'word': 'apple',
      'stage': 3,
      'is_weak': 0,
      'is_mastered': 1,
      'next_review_date': '2026-10-12',
      'last_reviewed_at': '2026-10-12T00:00:00Z',
      'review_count': 8,
      'created_at': '2026-01-01T00:00:00Z',
    });

    await local.insert('daily_activity', {
      'date': '2026-10-18',
      'words_learned': 6,
      'words_reviewed': 7,
      'correct_count': 5,
      'wrong_count': 2,
      'completed': 0,
      'daily_goal': 10,
    });
    await remote.insert('daily_activity', {
      'date': '2026-10-18',
      'words_learned': 10,
      'words_reviewed': 5,
      'correct_count': 8,
      'wrong_count': 3,
      'completed': 1,
      'daily_goal': 20,
    });

    await remote.insert('word_books', {
      'uuid': 'book-remote',
      'title': '云端词书',
      'description': null,
      'cover_path': null,
      'cover_color': null,
      'author': null,
      'word_count': 1,
      'is_builtin': 0,
      'created_at': '2026-03-01T00:00:00Z',
      'updated_at': '2026-03-01T00:00:00Z',
    });
    final remoteBook = await remote.query(
      'word_books',
      columns: ['id'],
      where: 'uuid = ?',
      whereArgs: ['book-remote'],
    );
    await remote.insert('word_book_entries', {
      'book_id': remoteBook.first['id'],
      'book_uuid': 'book-remote',
      'word': 'banana',
      'added_at': '2026-03-01T00:00:00Z',
    });

    final result = await CloudSyncMergeService.mergeDatabases(
      remote: remote,
      localDb: local,
    );
    expect(result.inserted, greaterThan(0));

    final appleNote = await local.query(
      'word_notes',
      where: 'word = ?',
      whereArgs: ['apple'],
    );
    expect(appleNote.single['note'], '本机较新');

    final bananaNote = await local.query(
      'word_notes',
      where: 'word = ?',
      whereArgs: ['banana'],
    );
    expect(bananaNote.single['note'], '仅云端有');

    final cherryNote = await local.query(
      'word_notes',
      where: 'word = ?',
      whereArgs: ['cherry'],
    );
    expect(cherryNote.single['note'], '仅本机有');

    final record = await local.query(
      'user_word_records',
      where: 'word = ?',
      whereArgs: ['apple'],
    );
    expect(record.single['stage'], 3);
    expect(record.single['review_count'], 8);
    expect(record.single['last_reviewed_at'], '2026-10-12T00:00:00Z');

    final activity = await local.query(
      'daily_activity',
      where: 'date = ?',
      whereArgs: ['2026-10-18'],
    );
    expect(activity.single['words_learned'], 10);
    expect(activity.single['words_reviewed'], 7);
    expect(activity.single['correct_count'], 8);
    expect(activity.single['wrong_count'], 3);
    // 非计数字段没有 LWW 列时保留本机值。
    expect(activity.single['completed'], 0);

    final book = await local.query(
      'word_books',
      where: 'uuid = ?',
      whereArgs: ['book-remote'],
    );
    expect(book, hasLength(1));
    expect(book.single['title'], '云端词书');

    final entries = await local.query(
      'word_book_entries',
      where: 'book_uuid = ? AND word = ?',
      whereArgs: ['book-remote', 'banana'],
    );
    expect(entries, hasLength(1));
    expect(entries.single['book_id'], book.single['id']);

    final conflicts = await local.query('sync_conflicts');
    expect(conflicts, isNotEmpty);
  });
}
