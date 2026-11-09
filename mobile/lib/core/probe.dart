import 'device.dart';
import 'escl.dart';
import 'ipp.dart';

/// What connecting to a device found out: its scanner (eSCL) and its printer (IPP).
class Probe {
  const Probe({this.caps, this.info, this.scanError});

  /// Scanner capabilities; null if eSCL did not answer or the answer was not usable.
  final ScannerCaps? caps;

  /// Printer state; null if IPP did not answer.
  final PrinterInfo? info;

  /// Why the capabilities could not be read.
  final Object? scanError;

  /// The device answered at all (scanner or printer).
  bool get online => caps != null || info != null;

  /// true: it scans. false: the printer answers but the scanner does not, so the device
  /// only prints. null: offline, nothing known (never "no scanner" for a device that is off).
  bool? get scanner => caps != null ? true : (info != null ? false : null);
}

/// Reads the scanner capabilities and the printer state at the same time.
/// [printerInfo] replaces the IPP request in tests.
Future<Probe> probeDevice(
  Device device,
  EsclClient escl, {
  Future<PrinterInfo> Function(Uri ippUri)? printerInfo,
}) async {
  Object? error;
  // Capabilities without a glass or a feeder (e.g. a web page that happens to be XML)
  // are no scanner either.
  final capsFuture = escl.capabilities().then<ScannerCaps?>((c) {
    if (c.sources.isNotEmpty) return c;
    error = const ScannerError('No scan source in ScannerCapabilities');
    return null;
  }, onError: (Object e) {
    error = e;
    return null;
  });
  final infoFuture = (printerInfo?.call(device.ippUri) ??
          getPrinterInfo(device.ippUri, timeout: const Duration(seconds: 6)))
      .then<PrinterInfo?>((i) => i, onError: (Object _) => null);
  final caps = await capsFuture;
  final info = await infoFuture;
  return Probe(caps: caps, info: info, scanError: error);
}
