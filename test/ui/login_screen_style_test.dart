import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/login_screen_style.dart';

void main() {
  test(
    'LoginScreenStyle is a const constructor accepting all-optional fields',
    () {
      const style = LoginScreenStyle();
      expect(style.titleStyle, isNull);
      expect(style.iconSize, isNull);
      expect(style.padding, isNull);
    },
  );

  test('LoginScreenStyle round-trips supplied values', () {
    const style = LoginScreenStyle(
      iconSize: 48,
      iconColor: Colors.red,
      titleStyle: TextStyle(fontSize: 24),
      padding: EdgeInsets.all(16),
      orDividerTextStyle: TextStyle(color: Colors.grey),
      errorBackgroundColor: Colors.amber,
    );
    expect(style.iconSize, 48);
    expect(style.iconColor, Colors.red);
    expect(style.titleStyle!.fontSize, 24);
    expect(style.padding, const EdgeInsets.all(16));
    expect(style.errorBackgroundColor, Colors.amber);
  });
}
