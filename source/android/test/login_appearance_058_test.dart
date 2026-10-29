import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/ui/login.dart';
import 'package:yingyu/ui/style.dart';
import 'offline_capture.dart';
import 'scroll_affordance_test.dart' show fonts;

void main() {
  for (final size in [const Size(360, 800), const Size(1280, 800)]) {
    for (final brightness in Brightness.values) {
      testWidgets(
        'segmented login surrounding layout and eye state $size $brightness',
        (tester) async {
          tester.view.physicalSize = size;
          tester.view.display.size = size;
          addTearDown(tester.view.display.resetSize);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await fonts();
          final capture = GlobalKey();
          var calls = 0;
          await tester.pumpWidget(
            RepaintBoundary(
              key: capture,
              child: MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: appTheme(brightness),
                home: LoginPage(
                  login: (address, user, password) async {
                    calls++;
                    expect(
                      address,
                      'https://library.example.invalid:8920/proxy/emby',
                    );
                    expect(user, 'synthetic-user');
                    expect(password, 'a 密码 &?#');
                  },
                  initialServer:
                      'https://library.example.invalid:8920/proxy/emby',
                  initialUsername: 'synthetic-user',
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('连接你的媒体库'), findsOneWidget);
          for (final id in [
            'server-name',
            'account-server',
            'server-port',
            'server-path',
            'account-username',
            'account-password',
          ]) {
            expect(find.byKey(Key(id)), findsOneWidget);
          }
          await captureOffline(
            tester,
            capture,
            'login-surround-${size.width.toInt()}-${brightness.name}',
          );
          final password = find.byKey(const Key('account-password'));
          await tester.ensureVisible(password);
          await tester.enterText(password, 'a 密码 &?#');
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
          final eye = find.byKey(const Key('login-password-visibility'));
          await tester.ensureVisible(eye);
          expect(tester.widget<TextField>(password).obscureText, isTrue);
          expect(
            find.descendant(
              of: eye,
              matching: find.byIcon(CupertinoIcons.eye_slash),
            ),
            findsOneWidget,
          );
          await tester.tap(eye);
          await tester.pump();
          expect(tester.widget<TextField>(password).obscureText, isFalse);
          expect(
            find.descendant(of: eye, matching: find.byIcon(CupertinoIcons.eye)),
            findsOneWidget,
          );
          await tester.tap(eye);
          await tester.pump();
          expect(tester.widget<TextField>(password).obscureText, isTrue);
          expect(calls, 0);
          final submit = find.byKey(const Key('account-login-submit'));
          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await tester.pumpAndSettle();
          expect(calls, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
