import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/update/release.dart';
import 'package:glassbed/update/update_client.dart';
import 'package:glassbed/update/update_controller.dart';
import 'package:glassbed/version.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _dl = 'https://github.com/ARFEP-IT-Service/Glassbed/releases/download';

String apkName(String version, String abi) => 'Glassbed-android-$version-$abi.apk';

/// One entry of GitHub's release list. Android tags get all three APKs by default.
Map<String, Object?> release(
  String tag, {
  bool draft = false,
  bool prerelease = false,
  List<Map<String, Object?>>? assets,
  String? htmlUrl,
}) {
  final version = tag.replaceFirst(RegExp(r'^(android-)?v'), '');
  return {
    'tag_name': tag,
    'draft': draft,
    'prerelease': prerelease,
    'html_url': htmlUrl ?? 'https://github.com/ARFEP-IT-Service/Glassbed/releases/tag/$tag',
    'assets': assets ??
        [
          for (final abi in supportedAbis)
            {
              'name': apkName(version, abi),
              'browser_download_url': '$_dl/$tag/${apkName(version, abi)}',
            },
        ],
  };
}

Map<String, Object?> asset(String name, String url) => {'name': name, 'browser_download_url': url};

/// A client that answers every request with [body] and records the requests.
MockClient recording(List<http.BaseRequest> calls, Object? body, {int status = 200}) =>
    MockClient((request) async {
      calls.add(request);
      return http.Response(jsonEncode(body), status);
    });

void main() {
  group('select', () {
    test('newest Android release, Windows tags ignored even if newer and first', () {
      final r = selectRelease([
        release('v0.3.1'),
        release('android-v0.1.1'),
        release('v0.3.0'),
        release('android-v0.1.0'),
      ]);
      expect(r?.version, '0.1.1');
    });

    test('only Windows releases: nothing', () {
      expect(selectRelease([release('v0.3.1'), release('v9.0.0')]), isNull);
    });

    test('drafts and pre-releases are ignored', () {
      final r = selectRelease([
        release('android-v0.9.0', draft: true),
        release('android-v0.8.0', prerelease: true),
        release('android-v0.9.0'),
      ]);
      expect(r?.version, '0.9.0');
    });

    test('a missing draft/prerelease flag does not count as published', () {
      final item = release('android-v0.5.0')..remove('draft');
      expect(selectRelease([item]), isNull);
    });

    test('tag must match android-vX.Y.Z exactly', () {
      for (final tag in [
        'android-v0.2',
        'android-v0.9.0-rc1',
        'Android-v0.9.0',
        'android-0.9.0',
        'android-v0.9.0 ',
        ' android-v0.9.0',
        'android-v0.9.0\n',
        'xandroid-v0.9.0',
        'android-v0.2.x',
      ]) {
        expect(selectRelease([release(tag)]), isNull, reason: tag);
      }
    });

    test('highest version wins, numerically', () {
      final r = selectRelease([
        release('android-v0.9.0'),
        release('android-v0.10.0'),
        release('android-v0.2.5'),
      ]);
      expect(r?.version, '0.10.0');
    });

    test('anything but a list: nothing', () {
      expect(selectRelease({'tag_name': 'android-v1.0.0'}), isNull);
      expect(selectRelease(null), isNull);
      expect(selectRelease(['x', 1, null]), isNull);
    });

    test('versions compare numerically', () {
      expect(isNewer('0.1.1', '0.1.0'), isTrue);
      expect(isNewer('0.10.0', '0.9.9'), isTrue);
      expect(isNewer('0.1.0', '0.1.0'), isFalse);
      expect(isNewer('0.0.9', '0.1.0'), isFalse);
      expect(isNewer('v0.9.0', '0.1.0'), isFalse);
    });
  });

  group('download link', () {
    test('exact asset URLs are accepted per ABI', () {
      final r = selectRelease([release('android-v0.9.0')])!;
      expect(r.apkUrls.keys, unorderedEquals(supportedAbis));
      expect(r.updateUrl('armeabi-v7a'), '$_dl/android-v0.9.0/Glassbed-android-0.9.0-armeabi-v7a.apk');
      expect(r.updateUrl('x86_64'), '$_dl/android-v0.9.0/Glassbed-android-0.9.0-x86_64.apk');
      expect(r.updateUrl('arm64-v8a'), '$_dl/android-v0.9.0/Glassbed-android-0.9.0-arm64-v8a.apk');
    });

    test('unknown ABI falls back to arm64-v8a, then to the release page', () {
      final r = selectRelease([release('android-v0.9.0')])!;
      expect(r.updateUrl('mips'), endsWith('arm64-v8a.apk'));
      expect(r.updateUrl(null), endsWith('arm64-v8a.apk'));
      final onlyV7 = selectRelease([
        release('android-v0.9.0', assets: [
          asset(apkName('0.9.0', 'armeabi-v7a'), '$_dl/android-v0.9.0/${apkName('0.9.0', 'armeabi-v7a')}'),
        ]),
      ])!;
      expect(onlyV7.updateUrl('x86_64'), onlyV7.pageUrl);
      expect(onlyV7.updateUrl('armeabi-v7a'), endsWith('armeabi-v7a.apk'));
    });

    test('tricks never give a direct link', () {
      const name = 'Glassbed-android-0.9.0-arm64-v8a.apk';
      for (final url in [
        'https://github.com/someone/Glassbed/releases/download/android-v0.9.0/$name',
        'https://evil.example/ARFEP-IT-Service/Glassbed/releases/download/android-v0.9.0/$name',
        'http://github.com/ARFEP-IT-Service/Glassbed/releases/download/android-v0.9.0/$name',
        'https://github.com.evil.example/ARFEP-IT-Service/Glassbed/releases/download/android-v0.9.0/$name',
        '$_dl/android-v0.1.9/$name',                       // other release
        '$_dl/android-v0.9.0/../android-v0.9.0/$name',     // path tricks
        '$_dl/android-v0.9.0/$name?x=1',
        '$_dl/android-v0.9.0/Glassbed-android-0.9.0-arm64-v8a.apk.exe',
      ]) {
        final r = selectRelease([
          release('android-v0.9.0', assets: [asset(name, url)]),
        ])!;
        expect(r.apkUrls, isEmpty, reason: url);
        expect(r.updateUrl('arm64-v8a'), r.pageUrl, reason: url);
      }
    });

    test('wrong asset name is not used', () {
      final r = selectRelease([
        release('android-v0.9.0', assets: [
          asset('glassbed.apk', '$_dl/android-v0.9.0/glassbed.apk'),
          asset('Glassbed-android-0.1.0-arm64-v8a.apk', '$_dl/android-v0.9.0/Glassbed-android-0.1.0-arm64-v8a.apk'),
        ]),
      ])!;
      expect(r.apkUrls, isEmpty);
    });

    test('release page must be in this repository', () {
      for (final html in [
        'https://evil.example/ARFEP-IT-Service/Glassbed/releases/tag/android-v0.9.0',
        'https://github.com/ARFEP-IT-Service/Glassbed/releasesX',
        'http://github.com/ARFEP-IT-Service/Glassbed/releases/tag/android-v0.9.0',
      ]) {
        final r = selectRelease([release('android-v0.9.0', htmlUrl: html)])!;
        expect(r.pageUrl, releasesPage, reason: html);
      }
      final ok = selectRelease([release('android-v0.9.0')])!;
      expect(ok.pageUrl, '$releasesPage/tag/android-v0.9.0');
    });
  });

  group('24 h rule', () {
    final now = DateTime.utc(2026, 11, 9, 12);
    test('due without or with an unreadable timestamp', () {
      expect(checkDue(null, now), isTrue);
      expect(checkDue('yesterday', now), isTrue);
    });
    test('not due within a day, due after', () {
      expect(checkDue(now.subtract(const Duration(hours: 23, minutes: 59)).toIso8601String(), now), isFalse);
      expect(checkDue(now.subtract(const Duration(hours: 24)).toIso8601String(), now), isTrue);
    });
    test('a clock set back allows a new check', () {
      expect(checkDue(now.add(const Duration(hours: 1)).toIso8601String(), now), isTrue);
    });
  });

  group('client', () {
    test('one GET to the API with the expected headers, no redirects', () async {
      final calls = <http.BaseRequest>[];
      final r = await fetchLatest(recording(calls, [release('android-v0.9.0')]));
      expect(r?.version, '0.9.0');
      expect(calls, hasLength(1));
      final req = calls.single;
      expect(req.method, 'GET');
      expect(req.url.toString(), 'https://api.github.com/repos/ARFEP-IT-Service/Glassbed/releases?per_page=50');
      expect(req.headers['User-Agent'], 'Glassbed-Android/$appVersion');
      expect(req.headers['Accept'], 'application/vnd.github+json');
      expect(req.followRedirects, isFalse);
    });

    test('a redirect is an error, not followed', () async {
      final calls = <http.BaseRequest>[];
      final client = MockClient((request) async {
        calls.add(request);
        return http.Response('', 302, headers: {'location': 'https://evil.example/releases'});
      });
      await expectLater(fetchLatest(client), throwsA(isA<UpdateError>()));
      expect(calls, hasLength(1));
    });

    test('refuses other hosts and plain HTTP without connecting', () async {
      final calls = <http.BaseRequest>[];
      final client = recording(calls, []);
      for (final url in [
        'https://github.com/ARFEP-IT-Service/Glassbed/releases',
        'http://api.github.com/repos/ARFEP-IT-Service/Glassbed/releases',
        'https://api.github.com.evil.example/repos',
        'https://evil.example/api.github.com',
      ]) {
        await expectLater(fetchLatest(client, url: Uri.parse(url)), throwsA(isA<UpdateError>()),
            reason: url);
      }
      expect(calls, isEmpty);
    });

    test('HTTP errors and odd answers become UpdateError', () async {
      await expectLater(fetchLatest(recording([], {'message': 'x'}, status: 403)),
          throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('403'))));
      await expectLater(fetchLatest(recording([], {'not': 'a list'})), throwsA(isA<UpdateError>()));
      await expectLater(
          fetchLatest(MockClient((_) async => http.Response('<html>', 200))), throwsA(isA<UpdateError>()));
      await expectLater(
          fetchLatest(MockClient((_) async => throw http.ClientException('offline'))),
          throwsA(isA<UpdateError>()));
    });
  });

  group('controller', () {
    late List<http.BaseRequest> calls;
    var now = DateTime.utc(2026, 11, 9, 12);
    Object? body;

    UpdateController make({String? abi = 'arm64-v8a'}) => UpdateController(
          newClient: () => MockClient((request) async {
            calls.add(request);
            return http.Response(jsonEncode(body), 200);
          }),
          deviceAbi: () async => abi,
          clock: () => now,
        );

    setUp(() {
      calls = [];
      now = DateTime.utc(2026, 11, 9, 12);
      body = [release('android-v0.9.0'), release('v0.3.1')];
    });

    test('nothing is requested while the check is off (default)', () async {
      SharedPreferences.setMockInitialValues({});
      final c = make();
      await c.checkIfDue();
      expect(await c.check(), isNull);
      expect(c.needsQuestion, isTrue);
      expect(calls, isEmpty);
    });

    test('daily check: once, then not again within 24 h', () async {
      SharedPreferences.setMockInitialValues({keyAsked: true, keyEnabled: true});
      final c = make();
      await c.checkIfDue();
      expect(calls, hasLength(1));
      expect(c.showBanner, isTrue);
      expect(c.release?.version, '0.9.0');

      now = now.add(const Duration(hours: 5));
      final again = make();
      await again.checkIfDue();
      expect(calls, hasLength(1));

      now = now.add(const Duration(hours: 20));
      await make().checkIfDue();
      expect(calls, hasLength(2));
    });

    test('a failed silent check still counts and stays silent', () async {
      SharedPreferences.setMockInitialValues({keyAsked: true, keyEnabled: true});
      final c = UpdateController(
        newClient: () => MockClient((request) async {
          calls.add(request);
          return http.Response('', 500);
        }),
        clock: () => now,
      );
      await c.checkIfDue();
      expect(calls, hasLength(1));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(keyLastCheck), isNotNull);
      await expectLater(c.check(), throwsA(isA<UpdateError>()));
    });

    test('up to date: no banner', () async {
      SharedPreferences.setMockInitialValues({keyAsked: true, keyEnabled: true});
      body = [release('android-v$appVersion'), release('v0.3.1')];
      final c = make();
      expect(await c.check(), isNull);
      expect(c.showBanner, isFalse);
    });

    test('skip hides this version for good, a newer one is offered again', () async {
      SharedPreferences.setMockInitialValues({keyAsked: true, keyEnabled: true});
      final c = make();
      await c.check(silent: true);
      expect(c.showBanner, isTrue);
      await c.skip();
      expect(c.showBanner, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(keySkipped), '0.9.0');

      final next = make();
      await next.check(silent: true);
      expect(next.showBanner, isFalse);

      // "Check now" still shows the skipped version.
      expect((await next.check())?.version, '0.9.0');
      expect(next.showBanner, isTrue);

      body = [release('android-v0.2.1')];
      final later = make();
      await later.check(silent: true);
      expect(later.showBanner, isTrue);
      expect(later.release?.version, '0.2.1');
    });

    test('later hides until the next check', () async {
      SharedPreferences.setMockInitialValues({keyAsked: true, keyEnabled: true});
      final c = make();
      await c.check(silent: true);
      c.later();
      expect(c.showBanner, isFalse);
      await c.check(silent: true);
      expect(c.showBanner, isTrue);
    });

    test('update URL follows the device ABI', () async {
      SharedPreferences.setMockInitialValues({keyAsked: true, keyEnabled: true});
      final c = make(abi: 'x86_64');
      await c.check(silent: true);
      expect(await c.updateUrl(), '$_dl/android-v0.9.0/Glassbed-android-0.9.0-x86_64.apk');
      final noApk = make();
      body = [release('android-v0.9.0', assets: [])];
      await noApk.check(silent: true);
      expect(await noApk.updateUrl(), '$releasesPage/tag/android-v0.9.0');
    });

    test('the question is stored as asked and off at once', () async {
      SharedPreferences.setMockInitialValues({});
      final c = make();
      await c.load();
      await c.markAsked();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(keyAsked), isTrue);
      expect(prefs.getBool(keyEnabled), isFalse);
      expect(make().needsQuestion, isTrue); // not loaded yet
      final reloaded = make();
      await reloaded.load();
      expect(reloaded.needsQuestion, isFalse);
      expect(calls, isEmpty);
    });
  });
}
