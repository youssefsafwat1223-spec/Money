import 'package:supabase_flutter/supabase_flutter.dart';

import 'session_store.dart';

/// §6.6: the pre-ASR SDK session, persisted by supabase_flutter's
/// `SharedPreferencesLocalStorage` under `sb-<first host label>-auth-token`.
/// Read only while legacy cleanup is pending; never written.
class SharedPrefsLegacySessionSource implements LegacySessionSource {
  SharedPrefsLegacySessionSource(String key)
      : _storage = SharedPreferencesLocalStorage(persistSessionKey: key);

  final SharedPreferencesLocalStorage _storage;
  Future<void>? _init;

  Future<void> _ready() => _init ??= _storage.initialize();

  @override
  Future<String?> readValue() async {
    await _ready();
    return _storage.accessToken();
  }

  @override
  Future<bool> removeVerified() async {
    await _ready();
    await _storage.removePersistedSession();
    return !await _storage.hasAccessToken();
  }
}
