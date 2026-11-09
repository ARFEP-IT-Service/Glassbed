import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../version.dart';
import 'release.dart';

/// The one request of the update check: GitHub's release list of this repository.
final apiUrl = Uri.parse('https://api.github.com/repos/$repo/releases?per_page=50');

/// The update check talks to the GitHub API only.
const allowedHosts = {'api.github.com'};

const requestTimeout = Duration(seconds: 10);
const _maxBytes = 4 * 1024 * 1024;

/// Anything that stops a check; the message is shown only after "Check now".
class UpdateError implements Exception {
  const UpdateError(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Refuses everything but HTTPS to an allowed host.
void checkUrl(Uri url) {
  if (url.scheme != 'https' || !allowedHosts.contains(url.host.toLowerCase())) {
    throw UpdateError('Refusing to connect to ${url.scheme}://${url.host}');
  }
}

/// Asks GitHub for the release list (one HTTPS GET, no redirects) and returns the newest
/// Android release, or null if there is none.
Future<AndroidRelease?> fetchLatest(http.Client client, {Uri? url}) async {
  final target = url ?? apiUrl;
  checkUrl(target);
  final request = http.Request('GET', target)
    // A redirect could lead anywhere – it is treated as an error instead of being followed.
    ..followRedirects = false
    ..headers['User-Agent'] = 'Glassbed-Android/$appVersion'
    ..headers['Accept'] = 'application/vnd.github+json';
  final List<int> body;
  try {
    final response = await client.send(request).timeout(requestTimeout);
    if (response.statusCode != 200) {
      unawaited(response.stream.drain<void>().catchError((_) {}));
      throw UpdateError('HTTP ${response.statusCode} from ${target.host}');
    }
    body = await _read(response.stream).timeout(requestTimeout);
  } on UpdateError {
    rethrow;
  } on TimeoutException {
    throw UpdateError('${target.host} did not answer in time');
  } catch (_) {
    throw UpdateError('Cannot reach ${target.host}');
  }
  final Object? data;
  try {
    data = jsonDecode(utf8.decode(body));
  } on FormatException {
    throw const UpdateError('Unexpected answer from GitHub');
  }
  if (data is! List) throw const UpdateError('Unexpected answer from GitHub');
  return selectRelease(data);
}

Future<List<int>> _read(Stream<List<int>> stream) async {
  final out = <int>[];
  await for (final chunk in stream) {
    out.addAll(chunk);
    if (out.length > _maxBytes) throw const UpdateError('Unexpected answer from GitHub');
  }
  return out;
}
