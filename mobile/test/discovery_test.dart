import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/discovery.dart';

void main() {
  test('parseTxt', () {
    expect(parseTxt('rs=eSCL\nty=HP Color Laser MFP 178 179\nTxtVers=1'), {
      'rs': 'eSCL',
      'ty': 'HP Color Laser MFP 178 179',
      'txtvers': '1',
    });
  });

  test('services of one host merge into one device, sorted by name', () {
    final found = <String, DiscoveredEntry>{};
    addService(found,
        serviceType: '_ipp._tcp.local',
        instance: 'HP Color Laser MFP 178 179 (A1B2C3)',
        host: '192.168.178.33',
        port: 631,
        txt: {'rp': 'ipp/print', 'ty': 'HP Color Laser 178'});
    addService(found,
        serviceType: '_uscan._tcp.local',
        instance: 'HP Color Laser MFP 178 179 (A1B2C3)',
        host: '192.168.178.33',
        port: 8080,
        txt: {'rs': '/eSCL', 'ty': 'HP Color Laser MFP 178 179'});
    addService(found,
        serviceType: '_uscan._tcp.local',
        instance: 'Brother',
        host: '192.168.178.40',
        port: 80,
        txt: {'rs': 'eSCL', 'ty': 'Brother MFC'});
    // never a device outside the local network
    addService(found,
        serviceType: '_uscan._tcp.local',
        instance: 'Evil',
        host: '8.8.8.8',
        port: 80,
        txt: const {});

    final devices = devicesFrom(found);
    expect(devices.map((d) => d.name), ['Brother MFC', 'HP Color Laser MFP 178 179']);
    final hp = devices[1];
    expect(hp.esclBase.toString(), 'http://192.168.178.33:8080/eSCL/');
    expect(hp.ippUri.toString(), 'ipp://192.168.178.33:631/ipp/print');
    expect(devices[0].ippUri.toString(), 'ipp://192.168.178.40:631/ipp/print');
  });

  test('three printers: _uscan+_ipp, _ipp only, _ipps only', () {
    final found = <String, DiscoveredEntry>{};
    // Zebra: scanner and printer
    addService(found,
        serviceType: '_ipp._tcp.local',
        instance: 'Zebra MFP',
        host: '192.168.178.10',
        port: 631,
        txt: {'rp': 'ipp/print', 'ty': 'Zebra MFP'});
    addService(found,
        serviceType: '_uscan._tcp.local',
        instance: 'Zebra MFP',
        host: '192.168.178.10',
        port: 80,
        txt: {'rs': 'eSCL', 'ty': 'Zebra MFP'});
    // Canon: plain IPP only
    addService(found,
        serviceType: '_ipp._tcp.local',
        instance: 'Canon LBP',
        host: '192.168.178.11',
        port: 631,
        txt: {'rp': 'ipp/print', 'ty': 'Canon LBP'});
    // Apeos: only IPP over TLS, on another port and path
    addService(found,
        serviceType: '_ipps._tcp.local',
        instance: 'Apeos',
        host: '192.168.178.12',
        port: 443,
        txt: {'rp': '/ipp/printer/', 'ty': 'Apeos C2360'});
    // never a device outside the local network, whatever the service
    addService(found,
        serviceType: '_ipps._tcp.local',
        instance: 'Cloud',
        host: '203.0.113.9',
        port: 631,
        txt: const {});

    final devices = devicesFrom(found);
    expect(devices.map((d) => d.name), ['Apeos C2360', 'Canon LBP', 'Zebra MFP']);
    expect(devices.map((d) => d.scanner), [false, false, true]);
    expect(devices.map((d) => d.host), ['192.168.178.12', '192.168.178.11', '192.168.178.10']);
    // _ipps: printed with plain IPP on 631, the advertised path kept
    expect(devices[0].ippUri.toString(), 'ipp://192.168.178.12:631/ipp/printer');
    expect(devices[1].ippUri.toString(), 'ipp://192.168.178.11:631/ipp/print');
    expect(devices[2].esclBase.toString(), 'http://192.168.178.10/eSCL/');
  });

  test('a plain _ipp answer wins over _ipps, in any order', () {
    for (final ippsFirst in [true, false]) {
      final found = <String, DiscoveredEntry>{};
      void ipps() => addService(found,
          serviceType: '_ipps._tcp.local',
          instance: 'P',
          host: '192.168.1.7',
          port: 443,
          txt: {'rp': 'secure'});
      void ipp() => addService(found,
          serviceType: '_ipp._tcp.local',
          instance: 'P',
          host: '192.168.1.7',
          port: 8631,
          txt: {'rp': 'ipp/print'});
      if (ippsFirst) {
        ipps();
        ipp();
      } else {
        ipp();
        ipps();
      }
      expect(devicesFrom(found).single.ippUri.toString(), 'ipp://192.168.1.7:8631/ipp/print',
          reason: 'ippsFirst: $ippsFirst');
    }
  });
}
