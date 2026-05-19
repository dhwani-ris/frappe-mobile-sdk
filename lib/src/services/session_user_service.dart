import 'dart:async';
import 'dart:convert';

import 'package:sqflite/sqflite.dart';

import '../models/session_user.dart';

/// Owns the in-memory [SessionUser], persists it to
/// `sdk_meta.session_user_json`, and publishes changes via a broadcast
/// `Stream<SessionUser?>`. Spec §6.6 + §7.5 (atomic logout wipe).
///
/// Lifecycle:
/// - `set(u)` after a successful login → in-memory + persisted + emitted.
/// - `restoreFromDb()` on app start → re-hydrates the in-memory copy
///   from the persisted JSON without emitting until `set` is called or
///   the consumer subscribes.
/// - `clear()` on logout → wipes persisted JSON, emits null. The
///   surrounding [AtomicWipe] handles file-level deletion.
///
/// Stream is broadcast so multiple widgets can subscribe; `dispose()`
/// closes the controller.
class SessionUserService {
  final Database _db;
  SessionUser? _current;
  final StreamController<SessionUser?> _controller =
      StreamController<SessionUser?>.broadcast();

  SessionUserService(this._db);

  SessionUser? get current => _current;
  Stream<SessionUser?> get stream => _controller.stream;

  Future<void> set(SessionUser u) async {
    _current = u;
    await _db.update(
      'sdk_meta',
      <String, Object?>{'session_user_json': jsonEncode(u.toJson())},
      where: 'id = 1',
    );
    _controller.add(u);
  }

  Future<void> clear() async {
    _current = null;
    await _db.update(
      'sdk_meta',
      <String, Object?>{'session_user_json': null},
      where: 'id = 1',
    );
    _controller.add(null);
  }

  Future<void> restoreFromDb() async {
    final rows = await _db.query('sdk_meta', limit: 1);
    if (rows.isEmpty) return;
    final raw = rows.first['session_user_json'] as String?;
    if (raw == null || raw.isEmpty) return;
    _current =
        SessionUser.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> dispose() => _controller.close();
}
