import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/update/update_texts.dart';
import 'package:glassbed/version.dart';

final _import = RegExp(r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''', multiLine: true);

/// lib/ files reachable from [entry] through relative and package:glassbed/ imports.
Set<String> reachable(String entry) {
  final seen = <String>{};
  final todo = [File(entry).absolute.path];
  final lib = Directory('lib').absolute.path;
  while (todo.isNotEmpty) {
    final path = File(todo.removeLast()).absolute.uri.normalizePath().toFilePath();
    if (!seen.add(path)) continue;
    for (final m in _import.allMatches(File(path).readAsStringSync())) {
      final target = m.group(1)!;
      if (target.startsWith('dart:')) continue;
      if (target.startsWith('package:')) {
        if (!target.startsWith('package:glassbed/')) continue;
        todo.add('$lib/${target.substring('package:glassbed/'.length)}');
      } else {
        todo.add(File(path).parent.uri.resolve(target).toFilePath());
      }
    }
  }
  return seen;
}

String rel(String path) => path.replaceAll('\\', '/').split('/lib/').last;

void main() {
  test('play entry point (main.dart) contains no update code', () {
    final files = reachable('lib/main.dart');
    // Sanity: the walker really follows the app.
    expect(files.map(rel), containsAll(['main.dart', 'app.dart', 'ui/home/home_screen.dart',
        'ui/settings_screen.dart', 'app_extras.dart', 'core/export.dart']));
    for (final f in files) {
      expect(rel(f).startsWith('update/'), isFalse, reason: f);
      // The pdf package's own project URL is blanked out of generated PDFs (core/export.dart);
      // that library reference is the only github.com mention allowed here.
      final text = File(f).readAsStringSync().replaceAll('https://github.com/DavBfr/dart_pdf', '');
      expect(text.contains('github.com'), isFalse, reason: f);
      expect(text.contains('ARFEP-IT-Service/Glassbed'), isFalse, reason: f);
      expect(text.contains(installHint), isFalse, reason: f);
      expect(text.contains('Skip this version'), isFalse, reason: f);
    }
  });

  test('github entry point includes the update notice', () {
    final files = reachable('lib/main_github.dart').map(rel);
    expect(files, containsAll(['update/update_ui.dart', 'update/update_client.dart', 'app.dart']));
  });

  test('only main_github.dart imports lib/update/ (outside lib/update/)', () {
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final r = rel(f.absolute.path);
      if (!r.endsWith('.dart') || r.startsWith('update/') || r == 'main_github.dart') continue;
      final imports = _import.allMatches(f.readAsStringSync()).map((m) => m.group(1)!);
      expect(imports.where((i) => i.contains('update/')), isEmpty, reason: r);
    }
  });

  test('update texts stay out of the asset files', () {
    for (final asset in ['assets/i18n/mobile.json', 'assets/i18n/shared.json']) {
      final text = File(asset).readAsStringSync();
      expect(text.contains(installHint), isFalse, reason: asset);
      expect(text.contains('github.com'), isFalse, reason: asset);
    }
  });

  test('appVersion equals pubspec.yaml without the build number', () {
    final m = RegExp(r'^version:\s*([0-9.]+)(\+\d+)?\s*$', multiLine: true)
        .firstMatch(File('pubspec.yaml').readAsStringSync());
    expect(m, isNotNull);
    expect(appVersion, m!.group(1));
  });

  test('update texts copied from shared/i18n.json are identical to the master', () {
    final master = File('../shared/i18n.json');
    final texts = (jsonDecode(master.readAsStringSync()) as Map)['texts'] as Map;
    for (final e in sharedUpdateTexts.entries) {
      expect(texts[e.key], isNotNull, reason: e.key);
      expect(Map<String, String>.from(texts[e.key] as Map), e.value, reason: e.key);
    }
  });

  test('mobile-only update texts: en/de/tr with the same placeholders', () {
    final hole = RegExp(r'\{(\w+)\}');
    for (final e in updateTexts.entries) {
      expect(e.value.keys, unorderedEquals(['en', 'de', 'tr']), reason: e.key);
      expect(e.value['en'], e.key);
      final want = hole.allMatches(e.key).map((m) => m.group(1)).toSet();
      for (final v in e.value.values) {
        expect(v.trim(), isNotEmpty, reason: e.key);
        expect(hole.allMatches(v).map((m) => m.group(1)).toSet(), want, reason: e.key);
      }
    }
  });
}
