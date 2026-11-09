/// Choosing the newest Android release from GitHub's release list – pure logic, no I/O.
///
/// Windows and Android share one repository: Windows tags are vX.Y.Z, Android tags are
/// android-vX.Y.Z. Only the latter count here.
library;

import 'test_hook.dart';

const repo = 'ARFEP-IT-Service/Glassbed';
const releasesPage = 'https://github.com/$repo/releases';
const downloadPrefix =
    testHook ? '${testBase}download/' : 'https://github.com/$repo/releases/download/';

/// APKs a release offers, one per ABI. The first one is the fallback.
const supportedAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];

final _androidTag = RegExp(r'^android-v(\d+)\.(\d+)\.(\d+)$');
final _plainVersion = RegExp(r'^(\d+)\.(\d+)\.(\d+)$');

/// At most one automatic check per day.
const checkInterval = Duration(hours: 24);

/// "0.1.0" → [0, 1, 0]; anything else → null.
List<int>? parseVersion(String text) {
  final m = _plainVersion.firstMatch(text);
  if (m == null) return null;
  return [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
}

int _compare(List<int> a, List<int> b) {
  for (var i = 0; i < 3; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return 0;
}

/// True if [remote] is a higher version than [current].
bool isNewer(String remote, String current) {
  final r = parseVersion(remote), c = parseVersion(current);
  return r != null && c != null && _compare(r, c) > 0;
}

/// Whether an automatic check is due. A clock set back (last check "in the future")
/// also allows a new check, as does a missing or unreadable timestamp.
bool checkDue(String? lastCheck, DateTime now) {
  final last = lastCheck == null ? null : DateTime.tryParse(lastCheck);
  if (last == null) return true;
  final age = now.toUtc().difference(last.toUtc());
  return age.isNegative || age >= checkInterval;
}

/// A published Android release.
class AndroidRelease {
  const AndroidRelease({
    required this.version,
    required this.pageUrl,
    this.apkUrls = const {},
    this.shaUrls = const {},
  });

  final String version;

  /// The release page (always on github.com in this repository).
  final String pageUrl;

  /// Verified direct download links by ABI.
  final Map<String, String> apkUrls;

  /// Verified links to the checksum files (`<apk name>.sha256`) by ABI; only for ABIs that
  /// also have an APK.
  final Map<String, String> shaUrls;

  /// The ABI whose APK this device gets: [abi] if the release has it, else arm64-v8a, else null.
  String? abiFor(String? abi) => apkUrls.containsKey(abi)
      ? abi
      : (apkUrls.containsKey(supportedAbis.first) ? supportedAbis.first : null);

  /// The APK for [abi], else the arm64-v8a one, else null (then the release page is used).
  String? apkFor(String? abi) => apkUrls[abiFor(abi)];

  /// Whether the app can download and verify the APK for [abi] itself (APK and checksum).
  bool canInstallFor(String? abi) {
    final a = abiFor(abi);
    return a != null && shaUrls.containsKey(a);
  }

  /// What "Update" opens: the matching APK, or the release page.
  String updateUrl(String? abi) => apkFor(abi) ?? pageUrl;
}

/// Whether the banner should offer [release] (newer than [current] and not skipped).
bool shouldNotify(AndroidRelease? release, String current, String? skipped) =>
    release != null && isNewer(release.version, current) && release.version != skipped;

/// The newest published Android release in GitHub's release list, or null.
/// Drafts, pre-releases and any tag that is not exactly android-vX.Y.Z are ignored.
AndroidRelease? selectRelease(Object? releases) {
  if (releases is! List) return null;
  List<int>? bestVersion;
  Map? best;
  for (final item in releases) {
    if (item is! Map || item['draft'] != false || item['prerelease'] != false) continue;
    final tag = item['tag_name'];
    if (tag is! String) continue;
    final m = _androidTag.firstMatch(tag);
    if (m == null) continue;
    final version = [for (var i = 1; i <= 3; i++) int.parse(m.group(i)!)];
    if (bestVersion == null || _compare(version, bestVersion) > 0) {
      bestVersion = version;
      best = item;
    }
  }
  return best == null ? null : _parseRelease(best, bestVersion!.join('.'));
}

AndroidRelease _parseRelease(Map data, String version) {
  var page = data['html_url'];
  if (page is! String || !page.startsWith('$releasesPage/')) page = releasesPage;
  final urls = <String, String>{};
  final assets = data['assets'];
  for (final asset in assets is List ? assets : const []) {
    if (asset is! Map) continue;
    final name = asset['name'], url = asset['browser_download_url'];
    if (name is String && url is String) urls[name] = url;
  }
  // Only exactly the APK of this release in this repository – anything else: release page.
  final apks = <String, String>{}, shas = <String, String>{};
  for (final abi in supportedAbis) {
    final name = apkName(version, abi);
    final expected = apkAssetUrl(version, abi);
    if (urls[name] != expected) continue;
    apks[abi] = expected;
    if (urls['$name.sha256'] == '$expected.sha256') shas[abi] = '$expected.sha256';
  }
  return AndroidRelease(version: version, pageUrl: page, apkUrls: apks, shaUrls: shas);
}

/// File name of the APK for [abi] in release [version].
String apkName(String version, String abi) => 'Glassbed-android-$version-$abi.apk';

/// The only accepted download link of that APK.
String apkAssetUrl(String version, String abi) =>
    '${downloadPrefix}android-v$version/${apkName(version, abi)}';
