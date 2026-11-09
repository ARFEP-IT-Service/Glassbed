import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';

/// Languages the app ships. The key is the language code, the value its own name.
const Map<String, String> supportedLanguages = {
  'de': 'Deutsch',
  'en': 'English',
  'tr': 'Türkçe',
};

const _prefKey = 'language';

/// Texts keyed by their English wording: `{"<english>": {"en": .., "de": .., "tr": ..}}`.
final Map<String, Map<String, String>> _texts = {};

/// The language chosen in the settings; null follows the system.
final ValueNotifier<String?> languageSetting = ValueNotifier<String?>(null);

/// Loads the shared texts (generated from the Windows app) and the mobile-only texts,
/// plus the stored language choice.
Future<void> loadI18n() async {
  for (final asset in const ['assets/i18n/shared.json', 'assets/i18n/mobile.json']) {
    try {
      final data = jsonDecode(await rootBundle.loadString(asset)) as Map<String, dynamic>;
      final texts = (data['texts'] as Map<String, dynamic>? ?? const {});
      texts.forEach((key, value) {
        if (value is Map) {
          _texts[key] = value.map((k, v) => MapEntry(k.toString(), v.toString()));
        }
      });
    } catch (e) {
      debugPrint('i18n: could not load $asset: $e');
    }
  }
  final prefs = await SharedPreferences.getInstance();
  final stored = prefs.getString(_prefKey);
  languageSetting.value = supportedLanguages.containsKey(stored) ? stored : null;
}

/// Stores the language choice (null = system) and notifies listeners.
Future<void> setLanguage(String? code) async {
  final prefs = await SharedPreferences.getInstance();
  if (code == null) {
    await prefs.remove(_prefKey);
  } else {
    await prefs.setString(_prefKey, code);
  }
  languageSetting.value = code;
}

/// The language in effect: the setting, else the system language if supported, else English.
String get currentLanguage {
  final chosen = languageSetting.value;
  if (chosen != null) return chosen;
  for (final locale in PlatformDispatcher.instance.locales) {
    if (supportedLanguages.containsKey(locale.languageCode)) return locale.languageCode;
  }
  return 'en';
}

/// Translates [key] (the English text) and fills `{name}` placeholders from [args].
/// Unknown keys or missing translations fall back to English, then to the key itself.
String tr(String key, [Map<String, Object?> args = const {}]) {
  final entry = _texts[key];
  var text = entry?[currentLanguage] ?? entry?['en'] ?? key;
  if (text.isEmpty) text = entry?['en'] ?? key;
  args.forEach((name, value) => text = text.replaceAll('{$name}', '$value'));
  return text;
}

/// Adds texts that ship in code instead of the asset files (used by optional features of
/// one build only). Texts from the asset files win, so a shared translation is never replaced.
void addTexts(Map<String, Map<String, String>> texts) {
  texts.forEach((key, value) => _texts.putIfAbsent(key, () => value));
}
