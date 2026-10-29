import 'package:flutter/widgets.dart';

/// Use the complete display, never a sheet, keyboard or split-screen window.
/// Unknown dimensions conservatively retain the existing tablet presentation.
bool phoneDisplay(Size physicalSize, double pixelRatio) {
  if (!pixelRatio.isFinite ||
      pixelRatio <= 0 ||
      !physicalSize.width.isFinite ||
      !physicalSize.height.isFinite ||
      physicalSize.shortestSide <= 0) {
    return false;
  }
  return physicalSize.shortestSide / pixelRatio < 600;
}

bool phoneLayout(BuildContext context) {
  // Subscribe to metrics changes without classifying by the window bounds.
  MediaQuery.sizeOf(context);
  final display = View.maybeOf(context)?.display;
  return display != null &&
      phoneDisplay(display.size, display.devicePixelRatio);
}

double phoneValue(BuildContext context, double phone, double tablet) =>
    phoneLayout(context) ? phone : tablet;

double shelfPosterWidth(BuildContext context) => phoneLayout(context)
    ? ((MediaQuery.sizeOf(context).width - 56) / 3.3).clamp(76.0, 144.0)
    : 120;

double mediaListPosterHeight(BuildContext context) =>
    phoneValue(context, 112, 140);

double resumeArtworkWidth(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  return phoneLayout(context)
      ? ((size.width - 32) * .70).clamp(176.0, 280.0)
      : ((size.width - 64) / (size.width > size.height ? 4.4 : 3.0)).clamp(
          220.0,
          320.0,
        );
}
