import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'test_hook.dart';

/// HTTP client that trusts only the test server's certificate.
http.Client testClient() {
  final context = SecurityContext(withTrustedRoots: false)
    ..setTrustedCertificatesBytes(base64.decode(testCa));
  final client = HttpClient(context: context)..userAgent = testHookMarker;
  return IOClient(client);
}
