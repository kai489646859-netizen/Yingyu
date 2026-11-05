import 'package:flutter/material.dart';

/// The Windows toolbar vector uses a 30×27 canvas and a 28×26 Viewbox.
class DanmakuToolbarIcon extends StatelessWidget {
  const DanmakuToolbarIcon({
    super.key,
    this.featured = false,
    this.selected = false,
  });
  final bool featured, selected;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: const Size(28, 26),
    painter: _DanmakuIconPainter(featured, selected),
  );
}

final _outline = Path()
  ..moveTo(12, 23)
  ..lineTo(4, 23)
  ..quadraticBezierTo(1.5, 23, 1.5, 20.5)
  ..lineTo(1.5, 4)
  ..quadraticBezierTo(1.5, 1.5, 4, 1.5)
  ..lineTo(24, 1.5)
  ..quadraticBezierTo(26.5, 1.5, 26.5, 4)
  ..lineTo(26.5, 15);
final _settings = Path()
  ..moveTo(22, 18)
  ..lineTo(27, 18)
  ..lineTo(29.4, 22)
  ..lineTo(27, 26)
  ..lineTo(22, 26)
  ..lineTo(19.6, 22)
  ..close();

class _DanmakuIconPainter extends CustomPainter {
  const _DanmakuIconPainter(this.featured, this.selected);
  final bool featured, selected;
  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 30;
    canvas.save();
    canvas.translate(0, (size.height - 27 * scale) / 2);
    canvas.scale(scale);
    final stroke = Paint()
      ..color = Colors.white
      ..strokeWidth = 2.35
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = Colors.white;
    canvas.drawPath(_outline, stroke);
    canvas.drawPath(featured ? _featuredGlyph : _settingsGlyph, fill);
    if (featured) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          const Rect.fromLTWH(16, 19, 14, 8),
          const Radius.circular(4),
        ),
        Paint()
          ..color = selected
              ? const Color(0xffff651a)
              : const Color(0xff68686b),
      );
      canvas.drawCircle(Offset(selected ? 26 : 20, 23), 3, fill);
    } else {
      canvas.drawPath(_settings, stroke);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DanmakuIconPainter oldDelegate) =>
      featured != oldDelegate.featured || selected != oldDelegate.selected;
}

// The two glyphs are the Windows toolbar's bold labels rendered as vector
// outlines, so Android's font fallback cannot change their appearance.
final _settingsGlyph = Path()
  ..moveTo(16.727, 11.471)
  ..lineTo(16.727, 12.660)
  ..lineTo(18.107, 12.660)
  ..lineTo(18.107, 11.471)
  ..lineTo(16.727, 11.471)
  ..close()
  ..moveTo(13.582, 11.471)
  ..lineTo(13.582, 12.660)
  ..lineTo(14.949, 12.660)
  ..lineTo(14.949, 11.471)
  ..lineTo(13.582, 11.471)
  ..close()
  ..moveTo(16.727, 8.955)
  ..lineTo(16.727, 10.131)
  ..lineTo(18.107, 10.131)
  ..lineTo(18.107, 8.955)
  ..lineTo(16.727, 8.955)
  ..close()
  ..moveTo(13.582, 8.955)
  ..lineTo(13.582, 10.131)
  ..lineTo(14.949, 10.131)
  ..lineTo(14.949, 8.955)
  ..lineTo(13.582, 8.955)
  ..close()
  ..moveTo(6.787, 6.221)
  ..lineTo(11.053, 6.221)
  ..lineTo(11.053, 10.979)
  ..lineTo(8.783, 10.979)
  ..lineTo(8.605, 12.565)
  ..lineTo(11.012, 12.565)
  ..lineTo(10.971, 14.492)
  ..cubicTo(10.925, 16.361, 10.876, 17.392, 10.824, 17.586)
  ..cubicTo(10.771, 17.779, 10.646, 18.019, 10.448, 18.303)
  ..cubicTo(10.250, 18.588, 9.870, 18.763, 9.310, 18.826)
  ..cubicTo(8.749, 18.890, 8.027, 18.922, 7.143, 18.922)
  ..cubicTo(7.088, 18.384, 6.979, 17.774, 6.814, 17.090)
  ..cubicTo(7.361, 17.127, 7.876, 17.145, 8.359, 17.145)
  ..cubicTo(8.615, 17.145, 8.813, 17.087, 8.954, 16.970)
  ..cubicTo(9.095, 16.854, 9.179, 16.677, 9.204, 16.437)
  ..cubicTo(9.229, 16.198, 9.262, 15.408, 9.303, 14.069)
  ..lineTo(6.828, 14.069)
  ..lineTo(7.197, 9.475)
  ..lineTo(9.398, 9.475)
  ..lineTo(9.398, 7.739)
  ..lineTo(6.787, 7.739)
  ..lineTo(6.787, 6.221)
  ..close()
  ..moveTo(17.779, 5.483)
  ..lineTo(19.406, 6.262)
  ..cubicTo(19.092, 6.681, 18.764, 7.096, 18.422, 7.506)
  ..lineTo(19.803, 7.506)
  ..lineTo(19.803, 14.110)
  ..lineTo(16.727, 14.110)
  ..lineTo(16.727, 15.135)
  ..lineTo(20.322, 15.135)
  ..lineTo(20.322, 16.912)
  ..lineTo(16.727, 16.912)
  ..lineTo(16.727, 19.059)
  ..lineTo(14.949, 19.059)
  ..lineTo(14.949, 16.912)
  ..lineTo(11.586, 16.912)
  ..lineTo(11.586, 15.135)
  ..lineTo(14.949, 15.135)
  ..lineTo(14.949, 14.110)
  ..lineTo(11.887, 14.110)
  ..lineTo(11.887, 7.506)
  ..lineTo(13.527, 7.506)
  ..cubicTo(13.236, 7.060, 12.958, 6.677, 12.693, 6.358)
  ..lineTo(14.088, 5.496)
  ..cubicTo(14.553, 5.989, 14.990, 6.517, 15.400, 7.082)
  ..lineTo(14.703, 7.506)
  ..lineTo(16.433, 7.506)
  ..cubicTo(16.934, 6.809, 17.383, 6.134, 17.779, 5.483)
  ..close();
final _featuredGlyph = Path()
  ..moveTo(14.170, 14.985)
  ..lineTo(14.170, 15.641)
  ..lineTo(18.012, 15.641)
  ..lineTo(18.012, 14.985)
  ..lineTo(14.170, 14.985)
  ..close()
  ..moveTo(14.170, 13.194)
  ..lineTo(14.170, 13.850)
  ..lineTo(18.012, 13.850)
  ..lineTo(18.012, 13.194)
  ..lineTo(14.170, 13.194)
  ..close()
  ..moveTo(12.502, 11.908)
  ..lineTo(19.680, 11.908)
  ..lineTo(19.680, 17.063)
  ..cubicTo(19.680, 17.687, 19.550, 18.157, 19.290, 18.471)
  ..cubicTo(19.030, 18.785, 18.660, 18.946, 18.179, 18.953)
  ..cubicTo(17.698, 18.960, 16.950, 18.963, 15.934, 18.963)
  ..cubicTo(15.852, 18.544, 15.733, 18.074, 15.578, 17.555)
  ..cubicTo(16.531, 17.610, 17.141, 17.637, 17.410, 17.637)
  ..cubicTo(17.811, 17.637, 18.012, 17.409, 18.012, 16.953)
  ..lineTo(18.012, 16.776)
  ..lineTo(14.170, 16.776)
  ..lineTo(14.170, 19.004)
  ..lineTo(12.502, 19.004)
  ..lineTo(12.502, 11.908)
  ..close()
  ..moveTo(10.957, 6.672)
  ..lineTo(12.064, 7.014)
  ..cubicTo(11.800, 7.916, 11.504, 8.832, 11.176, 9.762)
  ..lineTo(10.164, 9.393)
  ..lineTo(10.957, 6.672)
  ..close()
  ..moveTo(7.703, 6.672)
  ..cubicTo(7.977, 7.693, 8.209, 8.604, 8.400, 9.407)
  ..lineTo(7.320, 9.748)
  ..cubicTo(7.129, 8.855, 6.901, 7.939, 6.637, 7.000)
  ..lineTo(7.703, 6.672)
  ..close()
  ..moveTo(8.482, 5.647)
  ..lineTo(10.096, 5.647)
  ..lineTo(10.096, 10.446)
  ..lineTo(11.613, 10.446)
  ..lineTo(11.613, 11.895)
  ..lineTo(10.096, 11.895)
  ..lineTo(10.096, 13.344)
  ..lineTo(10.656, 12.811)
  ..cubicTo(11.240, 13.367, 11.777, 13.909, 12.270, 14.438)
  ..lineTo(11.176, 15.504)
  ..cubicTo(10.911, 15.171, 10.551, 14.755, 10.096, 14.253)
  ..lineTo(10.096, 19.032)
  ..lineTo(8.482, 19.032)
  ..lineTo(8.482, 14.834)
  ..cubicTo(8.063, 15.819, 7.612, 16.666, 7.129, 17.377)
  ..cubicTo(6.974, 16.803, 6.783, 16.124, 6.555, 15.340)
  ..cubicTo(7.206, 14.479, 7.822, 13.330, 8.400, 11.895)
  ..lineTo(6.787, 11.895)
  ..lineTo(6.787, 10.446)
  ..lineTo(8.482, 10.446)
  ..lineTo(8.482, 5.647)
  ..close()
  ..moveTo(15.141, 5.565)
  ..lineTo(16.918, 5.565)
  ..lineTo(16.918, 6.658)
  ..lineTo(20.076, 6.658)
  ..lineTo(20.076, 7.834)
  ..lineTo(16.918, 7.834)
  ..lineTo(16.918, 8.436)
  ..lineTo(19.775, 8.436)
  ..lineTo(19.775, 9.612)
  ..lineTo(16.918, 9.612)
  ..lineTo(16.918, 10.213)
  ..lineTo(20.295, 10.213)
  ..lineTo(20.295, 11.389)
  ..lineTo(11.887, 11.389)
  ..lineTo(11.887, 10.213)
  ..lineTo(15.141, 10.213)
  ..lineTo(15.141, 9.612)
  ..lineTo(12.434, 9.612)
  ..lineTo(12.434, 8.436)
  ..lineTo(15.141, 8.436)
  ..lineTo(15.141, 7.834)
  ..lineTo(12.160, 7.834)
  ..lineTo(12.160, 6.658)
  ..lineTo(15.141, 6.658)
  ..lineTo(15.141, 5.565)
  ..close();
