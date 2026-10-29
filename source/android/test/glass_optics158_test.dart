import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:yingyu/core/appearance.dart';
import 'package:yingyu/ui/style.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final video in [false, true]) {
      testWidgets(
        'legacy material arguments cannot activate retired effects $brightness video=$video',
        (tester) async {
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(brightness, visualStyle: VisualStyle.liquidGlass),
              home: Scaffold(
                body: AppVisualBackdrop(
                  child: AppGlassSurface(
                    overVideo: video,
                    child: const GlassControlSkin(child: Text('普通清晰控件')),
                  ),
                ),
              ),
            ),
          );
          final context = tester.element(find.text('普通清晰控件'));
          expect(liquidGlassOf(context), false);
          expect(
            Theme.of(context).extension<VisualStyleTheme>()!.style,
            VisualStyle.traditional,
          );
          expect(Theme.of(context).scaffoldBackgroundColor.a, 1);
          expect(find.byType(AdaptiveGlass), findsNothing);
          expect(find.byType(BackdropFilter), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
