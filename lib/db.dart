import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'utils.dart';

String newSalt() {
  final r = Random.secure();
  return base64Url.encode(List<int>.generate(12, (_) => r.nextInt(256)));
}

String hashPw(String salt, String pw) =>
    sha256.convert(utf8.encode('$salt:$pw')).toString();

class DB {
  static Database? _db;
  static Future<Database> get db async => _db ??= await _init();

  static const int version = 4;

  /// مسار ملف قاعدة البيانات
  static Future<String> dbPath() async =>
      p.join(await getDatabasesPath(), 'real_estate.db');

  /// دمج أي بيانات معلّقة في الملف الرئيسي قبل النسخ
  static Future<void> checkpoint() async {
    try {
      await (await db).rawQuery('PRAGMA wal_checkpoint(FULL)');
    } catch (_) {}
  }

  /// إغلاق القاعدة (يُستخدم قبل استعادة نسخة احتياطية)
  static Future<void> close() async {
    final d = _db;
    _db = null;
    if (d != null) await d.close();
  }

  // ---------------- إنشاء الجداول ----------------
  static Future<void> _createProperties(Database db) async {
    await db.execute('''
      CREATE TABLE properties (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT, address TEXT, location TEXT,
        tenant_name TEXT, tenant_phone TEXT, alt_phone TEXT,
        rent_amount REAL, deposit_amount REAL,
        electricity REAL, water REAL, gas REAL,
        other_note TEXT, other_amount REAL DEFAULT 0,
        balance REAL DEFAULT 0, receipt_counter INTEGER DEFAULT 0,
        status TEXT, id_card_path TEXT, contract_path TEXT,
        due_date TEXT, lat REAL, lng REAL
      )
    ''');
  }

  static Future<void> _createPayments(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS payments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        property_id INTEGER, property_name TEXT,
        tenant_name TEXT, tenant_phone TEXT,
        kind TEXT, receipt_no INTEGER,
        amount REAL, due_total REAL, prev_balance REAL, new_balance REAL,
        rent REAL, electricity REAL, water REAL, gas REAL,
        other_note TEXT, other_amount REAL,
        paid_at TEXT, period_due TEXT, note TEXT
      )
    ''');
  }

  static Future<void> _createAux(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS attachments (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        property_id INTEGER, kind TEXT, path TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE, display_name TEXT, role TEXT,
        pass_hash TEXT, salt TEXT, must_change INTEGER DEFAULT 1,
        sq1_id INTEGER, sq1_hash TEXT, sq2_id INTEGER, sq2_hash TEXT, sq_salt TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings (k TEXT PRIMARY KEY, v TEXT)
    ''');
  }

  /// حساب رئيسي وبديل تلقائياً عند أول تشغيل
  static Future<void> _seedUsers(Database db) async {
    final s1 = newSalt();
    final s2 = newSalt();
    await db.insert('users', {
      'username': 'admin',
      'display_name': 'الحساب الرئيسي',
      'role': 'main',
      'salt': s1,
      'pass_hash': hashPw(s1, '1234'),
      'must_change': 1,
    });
    await db.insert('users', {
      'username': 'backup',
      'display_name': 'الحساب البديل',
      'role': 'alt',
      'salt': s2,
      'pass_hash': hashPw(s2, '5678'),
      'must_change': 1,
    });
  }

  static Future<Database> _init() async {
    final path = await dbPath();
    return openDatabase(
      path,
      version: version,
      onCreate: (db, v) async {
        await _createProperties(db);
        await _createPayments(db);
        await _createAux(db);
        await _seedUsers(db);
      },
      onUpgrade: _upgrade,
    );
  }

  // ---------------- الترحيل (Migration) ----------------
  static Future<void> _upgrade(Database db, int oldV, int newV) async {
    if (oldV < 2) {
      await db.execute('ALTER TABLE properties ADD COLUMN due_date TEXT');
      await _createPayments(db);
    } else if (oldV < 3) {
      for (final c in [
        'kind TEXT',
        'receipt_no INTEGER',
        'due_total REAL',
        'prev_balance REAL',
        'new_balance REAL',
        'other_note TEXT',
        'other_amount REAL',
        'note TEXT',
      ]) {
        await db.execute('ALTER TABLE payments ADD COLUMN $c');
      }
    }
    if (oldV < 3) {
      for (final c in [
        'location TEXT',
        'alt_phone TEXT',
        'other_note TEXT',
        'other_amount REAL DEFAULT 0',
        'balance REAL DEFAULT 0',
        'receipt_counter INTEGER DEFAULT 0',
      ]) {
        await db.execute('ALTER TABLE properties ADD COLUMN $c');
      }
      await _createAux(db);

      // نقل الصور القديمة (صورة واحدة لكل مستند) إلى جدول المرفقات
      final props = await db.query('properties');
      for (final pr in props) {
        for (final e in {
          'id': pr['id_card_path'],
          'contract': pr['contract_path']
        }.entries) {
          final v = (e.value ?? '').toString();
          if (v.isNotEmpty) {
            await db.insert('attachments',
                {'property_id': pr['id'], 'kind': e.key, 'path': v});
          }
        }
      }

      // ترقيم الإيصالات القديمة بنظام (رقم العقار × 100000 + تسلسل)
      final pays = await db.query('payments', orderBy: 'id ASC');
      final counters = <int, int>{};
      for (final pm in pays) {
        final pid = (pm['property_id'] as int?) ?? 0;
        final seq = (counters[pid] ?? 0) + 1;
        counters[pid] = seq;
        await db.update(
          'payments',
          {
            'receipt_no': pid * 100000 + seq,
            'kind': 'full',
            'due_total': pm['amount'],
            'prev_balance': 0.0,
            'new_balance': 0.0,
            'other_amount': 0.0,
          },
          where: 'id = ?',
          whereArgs: [pm['id']],
        );
      }
      for (final e in counters.entries) {
        await db.update('properties', {'receipt_counter': e.value},
            where: 'id = ?', whereArgs: [e.key]);
      }
      await _seedUsers(db);
    }
    if (oldV < 4) {
      // إحداثيات الموقع على الخريطة + أسئلة الأمان لاستعادة كلمة المرور
      await _addColumn(db, 'properties', 'lat', 'REAL');
      await _addColumn(db, 'properties', 'lng', 'REAL');
      await _addColumn(db, 'users', 'sq1_id', 'INTEGER');
      await _addColumn(db, 'users', 'sq1_hash', 'TEXT');
      await _addColumn(db, 'users', 'sq2_id', 'INTEGER');
      await _addColumn(db, 'users', 'sq2_hash', 'TEXT');
      await _addColumn(db, 'users', 'sq_salt', 'TEXT');
    }
  }

  /// يضيف عموداً فقط إن لم يكن موجوداً (آمن عند تكرار الترحيل)
  static Future<void> _addColumn(
      Database db, String table, String col, String def) async {
    final info = await db.rawQuery('PRAGMA table_info($table)');
    if (info.any((r) => r['name'] == col)) return;
    await db.execute('ALTER TABLE $table ADD COLUMN $col $def');
  }

  // ---------------- العقارات ----------------
  static Future<List<Map<String, dynamic>>> all() async =>
      (await db).query('properties', orderBy: 'id DESC');

  static Future<Map<String, dynamic>?> property(int id) async {
    final r = await (await db)
        .query('properties', where: 'id = ?', whereArgs: [id]);
    return r.isEmpty ? null : Map<String, dynamic>.from(r.first);
  }

  static Future<int> insert(Map<String, dynamic> d) async =>
      (await db).insert('properties', d);

  static Future<int> update(int id, Map<String, dynamic> d) async =>
      (await db).update('properties', d, where: 'id = ?', whereArgs: [id]);

  static Future<void> delete(int id) async {
    final d = await db;
    await d.delete('attachments', where: 'property_id = ?', whereArgs: [id]);
    await d.delete('properties', where: 'id = ?', whereArgs: [id]);
  }

  /// رقم إيصال متسلسل لكل عقار: عقار 1 => 100001, 100002 ... وعقار 2 => 200001
  static Future<int> nextReceiptNo(int pid) async {
    final d = await db;
    return d.transaction((txn) async {
      final r = await txn.query('properties',
          columns: ['receipt_counter'], where: 'id = ?', whereArgs: [pid]);
      final cur = r.isEmpty ? 0 : ((r.first['receipt_counter'] as int?) ?? 0);
      final c = cur + 1;
      await txn.update('properties', {'receipt_counter': c},
          where: 'id = ?', whereArgs: [pid]);
      return pid * 100000 + c;
    });
  }

  // ---------------- المدفوعات ----------------
  static Future<List<Map<String, dynamic>>> payments() async =>
      (await db).query('payments', orderBy: 'id DESC');

  static Future<List<Map<String, dynamic>>> paymentsOf(int pid) async =>
      (await db).query('payments',
          where: 'property_id = ?', whereArgs: [pid], orderBy: 'id DESC');

  static Future<int> insertPayment(Map<String, dynamic> d) async =>
      (await db).insert('payments', d);

  static Future<int> updatePayment(int id, Map<String, dynamic> d) async =>
      (await db).update('payments', d, where: 'id = ?', whereArgs: [id]);

  static Future<int> deletePayment(int id) async =>
      (await db).delete('payments', where: 'id = ?', whereArgs: [id]);

  // ---------------- المرفقات ----------------
  static Future<List<String>> attachments(int pid, String kind) async {
    final r = await (await db).query('attachments',
        where: 'property_id = ? AND kind = ?',
        whereArgs: [pid, kind],
        orderBy: 'id ASC');
    return r.map((e) => (e['path'] ?? '').toString()).toList();
  }

  static Future<Map<int, Map<String, List<String>>>> attachmentMap() async {
    final r = await (await db).query('attachments', orderBy: 'id ASC');
    final m = <int, Map<String, List<String>>>{};
    for (final e in r) {
      final pid = e['property_id'] as int;
      final k = (e['kind'] ?? '').toString();
      m.putIfAbsent(pid, () => {'id': [], 'contract': []});
      m[pid]!.putIfAbsent(k, () => []);
      m[pid]![k]!.add((e['path'] ?? '').toString());
    }
    return m;
  }

  static Future<void> replaceAttachments(
      int pid, String kind, List<String> paths) async {
    final d = await db;
    final b = d.batch();
    b.delete('attachments',
        where: 'property_id = ? AND kind = ?', whereArgs: [pid, kind]);
    for (final x in paths) {
      b.insert('attachments', {'property_id': pid, 'kind': kind, 'path': x});
    }
    await b.commit(noResult: true);
  }

  // ---------------- المستخدمون ----------------
  static Future<List<Map<String, dynamic>>> users() async {
    final r = await (await db).query('users', orderBy: 'id ASC');
    return r.map((e) => Map<String, dynamic>.from(e)).toList();
  }

  static Future<Map<String, dynamic>?> userByName(String name) async {
    final r = await (await db)
        .query('users', where: 'username = ?', whereArgs: [name]);
    return r.isEmpty ? null : Map<String, dynamic>.from(r.first);
  }

  static Future<int> updateUser(int id, Map<String, dynamic> d) async =>
      (await db).update('users', d, where: 'id = ?', whereArgs: [id]);

  // ---------------- الإعدادات ----------------
  static Future<String?> getSetting(String k) async {
    final r = await (await db).query('settings', where: 'k = ?', whereArgs: [k]);
    return r.isEmpty ? null : r.first['v']?.toString();
  }

  static Future<void> setSetting(String k, String v) async {
    await (await db).insert('settings', {'k': k, 'v': v},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

Future<void> loadAppSettings() async {
  soonDays = int.tryParse(await DB.getSetting('soon_days') ?? '') ?? 3;
  companyName = await DB.getSetting('company_name') ?? '';
}
