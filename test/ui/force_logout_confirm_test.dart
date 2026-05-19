import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/ui/dialogs/force_logout_confirm.dart';

void main() {
  testWidgets('Logout button disabled until LOGOUT typed', (tester) async {
    var proceeded = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              final ok = await showForceLogoutConfirm(
                ctx,
                perDoctypeCounts: const {'X': 3},
              );
              if (ok) proceeded = true;
            },
            child: const Text('x'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('x'));
    await tester.pumpAndSettle();

    final btn = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Logout & Wipe'),
    );
    expect(btn.onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'LOGOUT');
    await tester.pump();
    final btn2 = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Logout & Wipe'),
    );
    expect(btn2.onPressed, isNotNull);
    await tester.tap(find.widgetWithText(ElevatedButton, 'Logout & Wipe'));
    await tester.pumpAndSettle();
    expect(proceeded, isTrue);
  });

  testWidgets('Cancel returns false', (tester) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              result = await showForceLogoutConfirm(
                ctx,
                perDoctypeCounts: const {'X': 1},
              );
            },
            child: const Text('x'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('x'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });

  testWidgets('lower-case "logout" does NOT enable the button',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => ElevatedButton(
            onPressed: () async {
              await showForceLogoutConfirm(
                ctx,
                perDoctypeCounts: const {'X': 1},
              );
            },
            child: const Text('x'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('x'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'logout');
    await tester.pump();
    final btn = tester.widget<ElevatedButton>(
      find.widgetWithText(ElevatedButton, 'Logout & Wipe'),
    );
    expect(btn.onPressed, isNull);
  });
}
