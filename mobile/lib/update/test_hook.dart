/// Test hook for the in-app update: point the github build at a local test release.
/// Pure constants; the HTTP client for the test server is in test_hook_client.dart.
///
/// Only for the phone test. It is switched on at build time with
///   `--dart-define=GLASSBED_UPDATE_TEST_BASE=https://PC-ADDRESS:8443/`
///   `--dart-define=GLASSBED_UPDATE_TEST_CA=BASE64-OF-THE-PEM-CERTIFICATE`
/// Release builds (mobile-build.yml) pass no defines: [testHook] is then the constant false and
/// the compiler drops everything that depends on it, including [testHookMarker].
const testBase = String.fromEnvironment('GLASSBED_UPDATE_TEST_BASE');
const testCa = String.fromEnvironment('GLASSBED_UPDATE_TEST_CA');
const testHook = testBase != '';

/// A text that exists in the app only when the hook is compiled in (checked in the APK).
const testHookMarker = 'glassbed-update-test-hook';

/// Host and port of the test release (only meaningful with [testHook]).
Uri get testBaseUri => Uri.parse(testBase);

bool isTestUrl(Uri url) =>
    testHook &&
    url.scheme == 'https' &&
    url.userInfo.isEmpty &&
    url.host == testBaseUri.host &&
    url.port == testBaseUri.port;
