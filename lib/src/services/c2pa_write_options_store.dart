import 'package:shared_preferences/shared_preferences.dart';

import 'c2pa_test_sign_service.dart';

abstract interface class C2paWriteOptionsStore {
  Future<C2paWriteOptions> load();

  Future<void> save(C2paWriteOptions options);
}

class SharedPreferencesC2paWriteOptionsStore implements C2paWriteOptionsStore {
  SharedPreferencesC2paWriteOptionsStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const _modeKey = 'c2pa_write_test.mode';
  static const _createNewFileKey = 'c2pa_write_test.create_new_file';

  final SharedPreferencesAsync _preferences;

  @override
  Future<C2paWriteOptions> load() async {
    final modeName = await _preferences.getString(_modeKey);
    final mode = C2paWriteMode.values
        .where((candidate) => candidate.name == modeName)
        .firstOrNull;
    return C2paWriteOptions(
      mode: mode ?? C2paWriteMode.add,
      createNewFile: await _preferences.getBool(_createNewFileKey) ?? true,
    );
  }

  @override
  Future<void> save(C2paWriteOptions options) async {
    await Future.wait(<Future<void>>[
      _preferences.setString(_modeKey, options.mode.name),
      _preferences.setBool(_createNewFileKey, options.createNewFile),
    ]);
  }
}
