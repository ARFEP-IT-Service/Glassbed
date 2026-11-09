import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/ui/home/printer_card.dart';

void main() {
  const light = Color(0xFF8B939C);

  test('black toner gets an outline on the dark theme', () {
    expect(tonerOutline(const Color(0xFF000000), Brightness.dark, light), light);
  });

  test('coloured toners and the light theme get no outline', () {
    for (final c in const [Color(0xFF00FFFF), Color(0xFFFF00FF), Color(0xFFFFFF00)]) {
      expect(tonerOutline(c, Brightness.dark, light), isNull);
    }
    expect(tonerOutline(const Color(0xFF000000), Brightness.light, light), isNull);
  });
}
