import 'package:flutter/widgets.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// The playback screen owns text subtitle layout. Video letterboxing and the
/// optional native HDR view cannot shrink the subtitle viewport.
Widget screenSubtitledVideo({
  required Widget picture,
  required VideoController controller,
  required SubtitleViewConfiguration configuration,
  double? pictureAspect,
  bool belowPicture = false,
  bool fill = false,
  ValueChanged<double>? onDefaultPosition,
}) => LayoutBuilder(
  builder: (context, size) {
    final aspect = pictureAspect;
    double? top;
    if (belowPicture &&
        !fill &&
        aspect != null &&
        aspect.isFinite &&
        aspect > 0 &&
        size.hasBoundedWidth &&
        size.hasBoundedHeight) {
      final pictureHeight = (size.maxWidth / aspect).clamp(0.0, size.maxHeight);
      if (pictureHeight < size.maxHeight - 1) {
        top = (size.maxHeight + pictureHeight) / 2 + size.maxHeight * .01;
      }
    }
    final placement = SubtitleViewConfiguration(
      visible: configuration.visible,
      alignment: configuration.alignment,
      style: configuration.style,
      textAlign: configuration.textAlign,
      textScaler: configuration.textScaler,
      padding: configuration.padding,
      bottomRegionTop: top,
      onDefaultPosition: belowPicture ? onDefaultPosition : null,
    );
    return Stack(
      fit: StackFit.expand,
      children: [
        picture,
        if (configuration.visible)
          IgnorePointer(
            child: SubtitleView(
              controller: controller,
              configuration: placement,
            ),
          ),
      ],
    );
  },
);
