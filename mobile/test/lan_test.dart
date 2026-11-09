import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/device.dart';
import 'package:glassbed/core/lan.dart';

void main() {
  group('isLocalHost', () {
    const table = {
      '192.168.178.33': true,
      '10.0.0.1': true,
      '172.16.0.1': true,
      '172.31.255.254': true,
      '172.32.0.1': false,
      '169.254.1.1': true,
      '8.8.8.8': false,
      '1.1.1.1': false,
      '127.0.0.1': false,
      'printer.local': true,
      'HP-Laser.local.': true,
      '.local': false,
      'example.com': false,
      'local': false,
      'printer.local.example.com': false,
      'fe80::1': true,
      '[fe80::1]': true,
      'fe80::1%wlan0': true,
      'fd12:3456::1': true,
      '2001:db8::1': false,
      '::ffff:192.168.1.5': true,
      '::ffff:8.8.8.8': false,
      '': false,
    };
    for (final MapEntry(key: host, value: expected) in table.entries) {
      test('"$host" -> $expected', () => expect(isLocalHost(host), expected));
    }
  });

  test('checkLocal throws NotLocalNetwork with the host', () {
    expect(
      () => checkLocal(Uri.parse('http://example.com/eSCL/')),
      throwsA(isA<NotLocalNetwork>().having((e) => e.host, 'host', 'example.com')),
    );
    checkLocal(Uri.parse('http://192.168.1.2/eSCL/'));
  });

  group('Device', () {
    test('fromHost builds the default endpoints', () {
      final d = Device.fromHost(' 192.168.178.33 ');
      expect(d.name, '192.168.178.33');
      expect(d.host, '192.168.178.33');
      expect(d.esclBase.toString(), 'http://192.168.178.33/eSCL/');
      expect(d.ippUri.toString(), 'ipp://192.168.178.33:631/ipp/print');
      expect(d.webPage.toString(), 'http://192.168.178.33/');
    });

    test('fromHost accepts a name, URL or IPv6 literal', () {
      expect(Device.fromHost('printer.local', name: 'HP').name, 'HP');
      expect(Device.fromHost('http://192.168.1.9/abc').host, '192.168.1.9');
      expect(Device.fromHost('192.168.1.9:8080').host, '192.168.1.9');
      final v6 = Device.fromHost('fe80::1');
      expect(v6.esclBase.host, 'fe80::1');
      expect(v6.webPage.toString(), 'http://[fe80::1]/');
    });
  });
}
