import 'package:flutter/material.dart';

enum AppAccent {
  teal('青绿', Color(0xFF167569), Color(0xFF77D1C3)),
  blue('海蓝', Color(0xFF245F9C), Color(0xFF8CBDE8)),
  rose('玫红', Color(0xFFAF2D68), Color(0xFFF095BB)),
  purple('紫罗兰', Color(0xFF7649AA), Color(0xFFBFA4E5)),
  amber('琥珀', Color(0xFF8E5D1C), Color(0xFFE8C27D)),
  // Xiaomi EV paint-inspired UI colors, adapted for readable light/dark roles.
  blush('流金粉', Color(0xFF8A5752), Color(0xFFE0BAB2), Color(0xFFCBA9A2)),
  lilac('霞光紫', Color(0xFF725D99), Color(0xFFC9B9E3), Color(0xFFAFA0BC)),
  emerald('宝石绿', Color(0xFF367555), Color(0xFFA4CDB3), Color(0xFF537C68)),
  titanium('云雅灰', Color(0xFF59665F), Color(0xFFBBC5BE), Color(0xFF9CA39E)),
  bay('海湾蓝', Color(0xFF2E7184), Color(0xFF9CCCD6), Color(0xFF76ADBA)),
  pearl('珍珠白', Color(0xFF64665C), Color(0xFFE2E2D9), Color(0xFFE2E2D9));

  const AppAccent(this.label, this.light, this.dark, [this.reference]);
  // Keep retired IDs readable for old preferences and historical fixtures.
  // Retired preferences are migrated by AppStore; picker order is explicit.
  static const available = [lilac, bay, emerald, blush];
  final String label;
  final Color light, dark;
  final Color? reference;
  Color get swatch => reference ?? dark;
  Color color(Brightness brightness) =>
      brightness == Brightness.dark ? dark : light;
}

enum VisualStyle {
  traditional('传统风格'),
  liquidGlass('液体玻璃');

  const VisualStyle(this.label);
  final String label;
}

class VisualStyleTheme extends ThemeExtension<VisualStyleTheme> {
  const VisualStyleTheme(this.style);
  final VisualStyle style;
  @override
  VisualStyleTheme copyWith({VisualStyle? style}) =>
      VisualStyleTheme(style ?? this.style);
  @override
  VisualStyleTheme lerp(covariant VisualStyleTheme? other, double t) =>
      t < .5 ? this : other ?? this;
}

class AccentTheme extends ThemeExtension<AccentTheme> {
  const AccentTheme(this.choice);
  final AppAccent choice;
  @override
  AccentTheme copyWith({AppAccent? choice}) =>
      AccentTheme(choice ?? this.choice);
  @override
  AccentTheme lerp(covariant AccentTheme? other, double t) =>
      t < .5 ? this : other ?? this;
}
