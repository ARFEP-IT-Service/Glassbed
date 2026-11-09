import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/update/download.dart';
import 'package:glassbed/update/installer.dart';
import 'package:glassbed/update/release.dart';
import 'package:glassbed/update/sha256.dart';
import 'package:glassbed/update/update_client.dart' show UpdateError;
import 'package:glassbed/update/update_controller.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _dl = 'https://github.com/ARFEP-IT-Service/Glassbed/releases/download';
const _cdn = 'https://release-assets.githubusercontent.com/github-production-release-asset/1/abc';

/// A release whose APKs and checksum files all have the exact asset URLs.
AndroidRelease withSha(String version, {bool sha = true}) => selectRelease([
      {
        'tag_name': 'android-v$version',
        'draft': false,
        'prerelease': false,
        'html_url': 'https://github.com/ARFEP-IT-Service/Glassbed/releases/tag/android-v$version',
        'assets': [
          for (final abi in supportedAbis) ...[
            {
              'name': apkName(version, abi),
              'browser_download_url': '$_dl/android-v$version/${apkName(version, abi)}',
            },
            if (sha)
              {
                'name': '${apkName(version, abi)}.sha256',
                'browser_download_url': '$_dl/android-v$version/${apkName(version, abi)}.sha256',
              },
          ],
        ],
      },
    ])!;

final apkBytes = Uint8List.fromList(List.generate(300 * 1024, (i) => (i * 31 + 7) & 0xff));
final apkHash = Sha256.hexOf(apkBytes);
const apk = 'Glassbed-android-0.9.0-arm64-v8a.apk';
const apkUrl = '$_dl/android-v0.9.0/$apk';

/// GitHub-like server: asset URLs redirect to the CDN, the CDN answers with the files.
MockClient github(
  List<http.BaseRequest> calls, {
  String? shaText,
  List<int>? body,
  Map<String, String> redirects = const {},
}) =>
    MockClient((request) async {
      calls.add(request);
      final url = request.url.toString();
      if (redirects.containsKey(url)) {
        return http.Response('', 302, headers: {'location': redirects[url]!});
      }
      if (url == apkUrl) return http.Response('', 302, headers: {'location': '$_cdn/apk?sig=1'});
      if (url == '$apkUrl.sha256') {
        return http.Response('', 302, headers: {'location': '$_cdn/sha?sig=1'});
      }
      if (url == '$_cdn/sha?sig=1') return http.Response(shaText ?? '$apkHash  $apk\n', 200);
      if (url == '$_cdn/apk?sig=1') return http.Response.bytes(body ?? apkBytes, 200);
      return http.Response('not found', 404);
    });

/// Records what would be handed to Android's installer.
class FakeInstaller implements ApkInstaller {
  FakeInstaller(this.dir, {this.results = const [InstallResult.started]});

  final Directory? dir;
  final List<InstallResult> results;
  final installed = <String>[];

  @override
  Future<Directory?> updatesDir() async => dir;

  @override
  Future<InstallResult> install(File apk) async {
    installed.add(apk.path);
    return results[(installed.length - 1).clamp(0, results.length - 1)];
  }
}

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('glassbed_update_test');
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  List<String> files() => dir.listSync().map((e) => e.uri.pathSegments.last).toList();

  Future<({File file, String sha256})> download(http.Client client,
          {CancelToken? cancel, int maxBytes = maxApkBytes, AndroidRelease? release}) =>
      downloadUpdate(client,
          release: release ?? withSha('0.9.0'),
          abi: 'arm64-v8a',
          dir: dir,
          cancel: cancel,
          maxBytes: maxBytes);

  group('sha256', () {
    test('standard test vectors', () {
      expect(Sha256.hexOf([]), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
      expect(Sha256.hexOf(utf8.encode('abc')),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(Sha256.hexOf(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
          '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
      expect(Sha256.hexOf(List.filled(1000000, 0x61)),
          'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0');
    });

    test('pieces of any size give the same hash', () {
      for (final size in [1, 3, 63, 64, 65, 1000, 4096]) {
        final sha = Sha256();
        for (var i = 0; i < apkBytes.length; i += size) {
          sha.add(apkBytes.sublist(i, (i + size).clamp(0, apkBytes.length)));
        }
        expect(sha.closeHex(), apkHash, reason: '$size');
      }
    });
  });

  group('.sha256 file', () {
    const h = 'ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef0123456789';
    test('sha256sum format, text or binary mode, CRLF', () {
      expect(parseSha256File('$h  $apk\n', apk), h.toLowerCase());
      expect(parseSha256File('$h *$apk', apk), h.toLowerCase());
      expect(parseSha256File('$h  $apk\r\n', apk), h.toLowerCase());
    });

    test('wrong name, short hash, several lines or junk: null', () {
      expect(parseSha256File('$h  other.apk', apk), isNull);
      expect(parseSha256File('${h.substring(1)}  $apk', apk), isNull);
      expect(parseSha256File('$h  $apk\n$h  $apk', apk), isNull);
      expect(parseSha256File(h, apk), isNull);
      expect(parseSha256File('<html>', apk), isNull);
      expect(parseSha256File('', apk), isNull);
    });
  });

  group('release', () {
    test('checksum links only with exactly the expected URL', () {
      final r = withSha('0.9.0');
      expect(r.shaUrls['arm64-v8a'], '$apkUrl.sha256');
      expect(r.canInstallFor('arm64-v8a'), isTrue);
      expect(r.canInstallFor('mips'), isTrue); // falls back to arm64-v8a
      expect(withSha('0.9.0', sha: false).canInstallFor('arm64-v8a'), isFalse);

      final odd = selectRelease([
        {
          'tag_name': 'android-v0.9.0',
          'draft': false,
          'prerelease': false,
          'assets': [
            {'name': apk, 'browser_download_url': apkUrl},
            {'name': '$apk.sha256', 'browser_download_url': 'https://evil.example/$apk.sha256'},
          ],
        },
      ])!;
      expect(odd.canInstallFor('arm64-v8a'), isFalse);
    });
  });

  group('download', () {
    test('correct checksum: the verified file, via the CDN redirect', () async {
      final calls = <http.BaseRequest>[];
      final r = await download(github(calls));
      expect(await r.file.readAsBytes(), apkBytes);
      expect(r.sha256, apkHash);
      expect(files(), [apk]);
      expect(calls.map((c) => c.url.toString()),
          ['$apkUrl.sha256', '$_cdn/sha?sig=1', apkUrl, '$_cdn/apk?sig=1']);
      for (final c in calls) {
        expect(c.followRedirects, isFalse);
        expect(c.method, 'GET');
      }
    });

    test('checksum mismatch: file deleted, error', () async {
      final bad = List<int>.of(apkBytes)..[1000] ^= 1;
      await expectLater(download(github([], body: bad)), throwsA(isA<ChecksumMismatch>()));
      expect(files(), isEmpty);
    });

    test('unreadable checksum file: nothing downloaded', () async {
      final calls = <http.BaseRequest>[];
      await expectLater(
          download(github(calls, shaText: '<html>oops</html>')), throwsA(isA<UpdateError>()));
      expect(calls.where((c) => c.url.toString().contains('/apk')), isEmpty);
      expect(files(), isEmpty);
    });

    test('redirect to a foreign host aborts without connecting there', () async {
      for (final target in [
        'https://evil.example/$apk',
        'https://github.com.evil.example/$apk',
        'https://evil.example@github.com/$apk',
        'https://github.com:8443/$apk',
      ]) {
        final calls = <http.BaseRequest>[];
        await expectLater(
            download(github(calls, redirects: {'$apkUrl.sha256': target})),
            throwsA(isA<UpdateError>()),
            reason: target);
        expect(calls.map((c) => c.url.host), everyElement('github.com'), reason: target);
        expect(files(), isEmpty);
      }
    });

    test('redirect to plain HTTP aborts', () async {
      final calls = <http.BaseRequest>[];
      await expectLater(
          download(github(calls, redirects: {apkUrl: 'http://release-assets.githubusercontent.com/x'})),
          throwsA(isA<UpdateError>()));
      expect(calls.where((c) => c.url.scheme == 'http'), isEmpty);
      expect(files(), isEmpty);
    });

    test('more than 5 redirects abort', () async {
      final calls = <http.BaseRequest>[];
      final client = MockClient((request) async {
        calls.add(request);
        return http.Response('', 302, headers: {'location': 'https://github.com/loop/${calls.length}'});
      });
      await expectLater(download(client), throwsA(isA<UpdateError>()));
      expect(calls, hasLength(1 + maxRedirects));
    });

    test('a release with a different link is refused without any request', () async {
      final calls = <http.BaseRequest>[];
      final forged = AndroidRelease(
        version: '0.9.0',
        pageUrl: releasesPage,
        apkUrls: {'arm64-v8a': 'https://objects.githubusercontent.com/$apk'},
        shaUrls: {'arm64-v8a': 'https://objects.githubusercontent.com/$apk.sha256'},
      );
      await expectLater(download(github(calls), release: forged), throwsA(isA<UpdateError>()));
      expect(calls, isEmpty);
    });

    test('size limit: announced or actual, file deleted', () async {
      // Announced by Content-Length.
      await expectLater(download(github([]), maxBytes: 1024), throwsA(isA<UpdateError>()));
      expect(files(), isEmpty);
      // Not announced: counted while receiving.
      final client = MockClient.streaming((request, _) async {
        final url = request.url.toString();
        if (url.endsWith('.sha256')) {
          return http.StreamedResponse(Stream.value(utf8.encode('$apkHash  $apk')), 200);
        }
        return http.StreamedResponse(
            Stream.fromIterable([for (var i = 0; i < 10; i++) List.filled(512, 1)]), 200);
      });
      await expectLater(download(client, maxBytes: 2048),
          throwsA(isA<UpdateError>().having((e) => e.message, 'message', contains('too large'))));
      expect(files(), isEmpty);
    });

    test('HTTP error: nothing left', () async {
      final client = MockClient((_) async => http.Response('', 404));
      await expectLater(download(client), throwsA(isA<UpdateError>()));
      expect(files(), isEmpty);
    });

    test('cancel deletes the partial file', () async {
      final body = StreamController<List<int>>();
      final firstChunk = Completer<void>();
      final client = MockClient.streaming((request, _) async {
        if (request.url.toString().endsWith('.sha256')) {
          return http.StreamedResponse(Stream.value(utf8.encode('$apkHash  $apk')), 200);
        }
        return http.StreamedResponse(body.stream, 200, contentLength: apkBytes.length);
      });
      final token = CancelToken();
      final running = downloadUpdate(client,
          release: withSha('0.9.0'),
          abi: 'arm64-v8a',
          dir: dir,
          cancel: token, onProgress: (got, _) {
        if (got > 0 && !firstChunk.isCompleted) firstChunk.complete();
      });
      body.add(apkBytes.sublist(0, 4096));
      await firstChunk.future;
      expect(files(), ['$apk.part']);
      token.cancel(); // the server keeps silent – cancelling must not wait for it
      await expectLater(running, throwsA(isA<DownloadCancelled>()));
      expect(files(), isEmpty);
      await body.close();
    });
  });

  group('controller', () {
    UpdateController make(http.Client client, ApkInstaller installer, {AndroidRelease? release}) =>
        UpdateController(
          newClient: () => client,
          deviceAbi: () async => 'arm64-v8a',
          installer: installer,
        )..release = release ?? withSha('0.9.0');

    test('verified APK goes to the installer; permission first, then reused', () async {
      final calls = <http.BaseRequest>[];
      final installer = FakeInstaller(dir,
          results: [InstallResult.needsPermission, InstallResult.started]);
      final c = make(github(calls), installer);
      expect(await c.downloadAndInstall(), UpdateOutcome.needsPermission);
      expect(c.outcome, UpdateOutcome.needsPermission);
      expect(c.busy, isFalse);
      expect(installer.installed.single, endsWith(apk));
      expect(calls, hasLength(4));

      // "Update" again after allowing: the verified file is checked again, not downloaded.
      expect(await c.downloadAndInstall(), UpdateOutcome.installStarted);
      expect(calls, hasLength(4));
      expect(installer.installed, hasLength(2));
    });

    test('checksum mismatch: nothing installed, no file', () async {
      final installer = FakeInstaller(dir);
      final bad = List<int>.of(apkBytes)..[0] ^= 0xff;
      final c = make(github([], body: bad), installer);
      expect(await c.downloadAndInstall(), UpdateOutcome.checksumMismatch);
      expect(installer.installed, isEmpty);
      expect(files(), isEmpty);
    });

    test('a changed file is not reused', () async {
      final installer = FakeInstaller(dir,
          results: [InstallResult.needsPermission, InstallResult.started]);
      final calls = <http.BaseRequest>[];
      final c = make(github(calls), installer);
      await c.downloadAndInstall();
      await File(installer.installed.single).writeAsBytes([1, 2, 3]);
      expect(await c.downloadAndInstall(), UpdateOutcome.installStarted);
      expect(calls, hasLength(8)); // downloaded again
      expect(await File(installer.installed.last).readAsBytes(), apkBytes);
    });

    test('no checksum file in the release or no installer: browser', () async {
      final calls = <http.BaseRequest>[];
      expect(await make(github(calls), FakeInstaller(dir), release: withSha('0.9.0', sha: false))
          .downloadAndInstall(), UpdateOutcome.browser);
      expect(await make(github(calls), FakeInstaller(null)).downloadAndInstall(),
          UpdateOutcome.browser);
      expect(calls, isEmpty);
    });

    test('failure is reported, cancel is quiet', () async {
      final installer = FakeInstaller(dir);
      final c = make(MockClient((_) async => http.Response('', 500)), installer);
      expect(await c.downloadAndInstall(), UpdateOutcome.failed);
      expect(c.error, contains('500'));

      final body = StreamController<List<int>>();
      final c2 = make(
          MockClient.streaming((request, _) async => request.url.toString().endsWith('.sha256')
              ? http.StreamedResponse(Stream.value(utf8.encode('$apkHash  $apk')), 200)
              : http.StreamedResponse(body.stream, 200)),
          installer);
      final running = c2.downloadAndInstall();
      body.add([1, 2, 3]);
      while (c2.received == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(c2.phase, DownloadPhase.downloading);
      c2.cancelDownload();
      expect(await running, UpdateOutcome.cancelled);
      expect(c2.outcome, isNull);
      expect(c2.busy, isFalse);
      expect(installer.installed, isEmpty);
      expect(files(), isEmpty);
      await body.close();
    });
  });
}
