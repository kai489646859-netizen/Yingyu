import 'models.dart';

/// Fixed episode-number bands. Sparse catalogues never widen a band, and a
/// large highest number does not allocate empty bands or synthetic episodes.
class EpisodeBands {
  EpisodeBands(this.items) {
    for (var i = 0; i < items.length; i++) {
      final band = (number(i) - 1) ~/ 50;
      if (number(i) > maximum) maximum = number(i);
      indices.putIfAbsent(band, () => []).add(i);
    }
    keys.addAll(indices.keys.toList()..sort());
    for (var i = 0; i < keys.length; i++) { positions[keys[i]] = i; }
  }
  final List<MediaItem> items;
  final indices = <int, List<int>>{};
  final keys = <int>[];
  final positions = <int, int>{};
  int maximum = 0;
  int get count => keys.length;
  int number(int i) {
    final n = integer(items[i].data['IndexNumber']);
    return n > 0 ? n : i + 1;
  }

  int bandOf(int i) => positions[(number(i) - 1) ~/ 50]!;
  static String label(int band) => '${band * 50 + 1}–${(band + 1) * 50}';
  String labelAt(int index) {
    final band = keys[index];
    final end = (band + 1) * 50;
    return '${band * 50 + 1}–${end > maximum ? maximum : end}';
  }
  List<int> inBand(int band) => band >= 0 && band < count ? indices[keys[band]]! : const [];
}
