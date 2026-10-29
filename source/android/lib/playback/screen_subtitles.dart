import 'subtitle_size.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart' show VideoParams;
import 'package:media_kit_video/media_kit_video.dart';

/// Use display dimensions when the decoder omits its optional aspect field.
/// Rotation belongs to the visible geometry, not the encoded pixel width.
double? subtitlePictureAspect(VideoParams params) {
  double? aspect;
  if ((params.dw ?? 0) > 0 && (params.dh ?? 0) > 0) {
    aspect = params.dw! / params.dh!;
  } else {
    aspect = params.aspect;
  }
  if (aspect == null || !aspect.isFinite || aspect <= 0) return null;
  return params.rotate == 90 || params.rotate == 270 ? 1 / aspect : aspect;
}

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
}) => StreamBuilder<VideoParams>(
  stream: controller.player.stream.videoParams,
  initialData: controller.player.state.videoParams,
  builder: (context, parameters) => LayoutBuilder(
    builder: (context, size) {
      final responsiveStyle = configuration.style.copyWith(
        fontSize: subtitleFontSize(
          Size(size.maxWidth, size.maxHeight),
          SubtitleSizeScope.of(context),
        ),
      );
      final aspect = pictureAspect ?? subtitlePictureAspect(parameters.data!);
      double? top;
      if (belowPicture &&
          !fill &&
          aspect != null &&
          aspect.isFinite &&
          aspect > 0 &&
          size.hasBoundedWidth &&
          size.hasBoundedHeight) {
        final pictureHeight = (size.maxWidth / aspect).clamp(
          0.0,
          size.maxHeight,
        );
        if (pictureHeight < size.maxHeight - 1) {
          top = (size.maxHeight + pictureHeight) / 2 + size.maxHeight * .01;
        }
      }
      final placement = SubtitleViewConfiguration(
        visible: configuration.visible,
        alignment: configuration.alignment,
        style: responsiveStyle,
        textAlign: configuration.textAlign,
        textScaler: const TextScaler.linear(1),
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
                trackIndex: 1,
                configuration: SubtitleViewConfiguration(
                  visible: true,
                  alignment: Alignment.topCenter,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 40,
                  ),
                  style: responsiveStyle,
                  textScaler: const TextScaler.linear(1),
                ),
              ),
            ),
          if (configuration.visible)
            IgnorePointer(
              child: SubtitleView(
                controller: controller,
                configuration: placement,
                trackIndex: 0,
              ),
            ),
        ],
      );
    },
  ),
);
