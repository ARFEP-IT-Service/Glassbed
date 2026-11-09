import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../version.dart';
import 'release.dart';
import 'sha256.dart';
import 'test_hook.dart';
import 'update_client.dart' show UpdateError;

/// Downloading an update APK and its checksum from a GitHub release.
///
/// The first request goes to exactly the asset URL that release.dart accepted; GitHub then
/// redirects to its download servers. Redirects are followed by hand, only over HTTPS and only
/// to [downloadHosts]. The SHA-256 of the APK is computed while it arrives and compared with
/// the `.sha256` file of the same release; a file that does not match is deleted.

/// Hosts a download (and its redirects) may go to.
const downloadHosts = {
  'github.com',
  'release-assets.githubusercontent.com',
  'objects.githubusercontent.com',
};

const maxRedirects = 5;

/// Upper limit for an APK.
const maxApkBytes = 200 * 1024 * 1024;

/// Upper limit for a `.sha256` file (one line).
const maxShaBytes = 4096;

const connectTimeout = Duration(seconds: 15);

/// No data for this long while downloading: the download fails.
const stallTimeout = Duration(seconds: 30);

/// The user cancelled the download.
class DownloadCancelled implements Exception {
  const DownloadCancelled();

  @override
  String toString() => 'Download cancelled';
}

/// The APK does not match its `.sha256` file; it was deleted.
class ChecksumMismatch extends UpdateError {
  const ChecksumMismatch() : super('Checksum mismatch');
}

/// Lets the UI stop a running download at once.
class CancelToken {
  bool _cancelled = false;
  final _listeners = <void Function()>[];

  bool get cancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in List.of(_listeners)) {
      l();
    }
    _listeners.clear();
  }

  void _onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void _remove(void Function() listener) => _listeners.remove(listener);

  void _check() {
    if (_cancelled) throw const DownloadCancelled();
  }
}

/// Refuses everything but HTTPS to one of [downloadHosts] (no user info, default port).
void checkDownloadUrl(Uri url) {
  if (isTestUrl(url)) return;
  final ok = url.scheme == 'https' &&
      downloadHosts.contains(url.host.toLowerCase()) &&
      url.userInfo.isEmpty &&
      (!url.hasPort || url.port == 443);
  if (!ok) throw UpdateError('Refusing to download from ${url.scheme}://${url.host}');
}

/// The hash in a `sha256sum` line for [fileName] (`<hash>  <name>` or `<hash> *<name>`),
/// lowercase; null if the text is not exactly that.
String? parseSha256File(String text, String fileName) {
  final lines = const LineSplitter().convert(text.trim());
  if (lines.length != 1) return null;
  final m = RegExp(r'^([0-9a-fA-F]{64}) [ *](.+)$').firstMatch(lines.single.trim());
  if (m == null || m.group(2) != fileName) return null;
  return m.group(1)!.toLowerCase();
}

/// Downloads the APK of [release] for [abi] into [dir], checks it against the release's
/// `.sha256` file and returns it with its hash. On any failure (also [DownloadCancelled]) no file is left.
/// [onProgress] gets received bytes and the total (null if the server does not say);
/// [onVerifying] is called once the APK is complete, before the comparison.
Future<({File file, String sha256})> downloadUpdate(
  http.Client client, {
  required AndroidRelease release,
  required String abi,
  required Directory dir,
  CancelToken? cancel,
  void Function(int received, int? total)? onProgress,
  void Function()? onVerifying,
  int maxBytes = maxApkBytes,
}) async {
  final token = cancel ?? CancelToken();
  final name = apkName(release.version, abi);
  final apkUrl = apkAssetUrl(release.version, abi);
  // The links must be exactly the ones release.dart accepted from GitHub's release list.
  if (release.apkUrls[abi] != apkUrl || release.shaUrls[abi] != '$apkUrl.sha256') {
    throw const UpdateError('No verifiable download for this device');
  }
  final part = File('${dir.path}/$name.part');
  final target = File('${dir.path}/$name');
  try {
    await dir.create(recursive: true);
    await _deleteIfExists(target);

    final shaBytes = <int>[];
    await _get(client, Uri.parse('$apkUrl.sha256'), token, maxShaBytes, (chunk) {
      shaBytes.addAll(chunk);
    });
    final expected = parseSha256File(utf8.decode(shaBytes, allowMalformed: true), name);
    if (expected == null) throw const UpdateError('Unreadable checksum file');

    final sha = Sha256();
    final sink = part.openWrite();
    try {
      var received = 0;
      await _get(client, Uri.parse(apkUrl), token, maxBytes, (chunk) {
        sink.add(chunk);
        sha.add(chunk);
        received += chunk.length;
      }, onProgress: onProgress);
      if (received == 0) throw const UpdateError('Empty download');
    } finally {
      await sink.close();
    }
    token._check();
    onVerifying?.call();
    if (sha.closeHex() != expected) throw const ChecksumMismatch();
    token._check();
    return (file: await part.rename(target.path), sha256: expected);
  } catch (_) {
    await _deleteIfExists(part);
    await _deleteIfExists(target);
    if (token.cancelled) throw const DownloadCancelled();
    rethrow;
  }
}

/// The SHA-256 of a file on disk, lowercase hex.
Future<String> sha256OfFile(File file) async {
  final sha = Sha256();
  await for (final chunk in file.openRead()) {
    sha.add(chunk);
  }
  return sha.closeHex();
}

Future<void> _deleteIfExists(File f) async {
  try {
    if (await f.exists()) await f.delete();
  } on FileSystemException {
    // Cache files: the next start cleans up.
  }
}

/// GETs [first], following up to [maxRedirects] redirects to allowed hosts, and passes the
/// body to [onChunk]. More than [limit] bytes is an error.
Future<void> _get(
  http.Client client,
  Uri first,
  CancelToken token,
  int limit,
  void Function(List<int> chunk) onChunk, {
  void Function(int received, int? total)? onProgress,
}) async {
  var url = first;
  for (var hop = 0;; hop++) {
    checkDownloadUrl(url);
    token._check();
    final request = http.Request('GET', url)
      ..followRedirects = false
      ..headers['User-Agent'] = 'Glassbed-Android/$appVersion'
      ..headers['Accept'] = 'application/octet-stream';
    final http.StreamedResponse response;
    try {
      response = await _cancellable(client.send(request).timeout(connectTimeout), token);
    } on DownloadCancelled {
      rethrow;
    } on TimeoutException {
      throw UpdateError('${url.host} did not answer in time');
    } catch (_) {
      throw UpdateError('Cannot reach ${url.host}');
    }
    final status = response.statusCode;
    if (const {301, 302, 303, 307, 308}.contains(status)) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      final location = response.headers['location'];
      if (location == null || location.isEmpty) throw UpdateError('HTTP $status without target');
      if (hop >= maxRedirects) throw const UpdateError('Too many redirects');
      url = url.resolve(location);
      continue;
    }
    if (status != 200) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      throw UpdateError('HTTP $status from ${url.host}');
    }
    final total = response.contentLength;
    if (total != null && total > limit) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      throw const UpdateError('Download too large');
    }
    var received = 0;
    onProgress?.call(0, total);
    try {
      await for (final chunk in _cancellableStream(response.stream, token).timeout(stallTimeout)) {
        received += chunk.length;
        if (received > limit) throw const UpdateError('Download too large');
        onChunk(chunk);
        onProgress?.call(received, total);
      }
    } on UpdateError {
      rethrow;
    } on DownloadCancelled {
      rethrow;
    } on TimeoutException {
      throw UpdateError('${url.host} stopped sending');
    } catch (_) {
      if (token.cancelled) throw const DownloadCancelled();
      throw UpdateError('Download from ${url.host} broke off');
    }
    token._check();
    return;
  }
}

/// [future], but completed with [DownloadCancelled] as soon as [token] is cancelled.
Future<T> _cancellable<T>(Future<T> future, CancelToken token) {
  final done = Completer<T>();
  void onCancel() {
    if (!done.isCompleted) done.completeError(const DownloadCancelled());
  }

  token._onCancel(onCancel);
  future.then((value) {
    token._remove(onCancel);
    if (!done.isCompleted) {
      done.complete(value);
    } else if (value is http.StreamedResponse) {
      unawaited(value.stream.drain<void>().catchError((_) {}));
    }
  }, onError: (Object e, StackTrace s) {
    token._remove(onCancel);
    if (!done.isCompleted) done.completeError(e, s);
  });
  return done.future;
}

/// [source], but ends with [DownloadCancelled] as soon as [token] is cancelled.
Stream<List<int>> _cancellableStream(Stream<List<int>> source, CancelToken token) {
  late final StreamController<List<int>> out;
  StreamSubscription<List<int>>? sub;
  void onCancel() {
    sub?.cancel();
    if (!out.isClosed) {
      out.addError(const DownloadCancelled());
      out.close();
    }
  }

  out = StreamController<List<int>>(
    onListen: () {
      sub = source.listen(out.add, onError: out.addError, onDone: () {
        token._remove(onCancel);
        out.close();
      });
      token._onCancel(onCancel);
    },
    onPause: () => sub?.pause(),
    onResume: () => sub?.resume(),
    onCancel: () {
      token._remove(onCancel);
      return sub?.cancel();
    },
  );
  return out.stream;
}
