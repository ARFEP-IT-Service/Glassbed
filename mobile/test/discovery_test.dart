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
}
