import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_title_filter.dart';
import 'package:yingyu/playback/disc_transport.dart';

DiscTitle title(int id, int seconds, {bool main = false}) => DiscTitle({
  'playlist': id,
  'main': main,
  'duration': seconds * 90000,
  'clips': [
    {'id': id.toString().padLeft(5, '0'), 'in': 0, 'out': seconds * 90000},
  ],
});

void main() {
  test('folds short extras while retaining feature and exact boundary', () {
    final input = [title(5, 8246, main: true), title(2, 180), title(3, 179)];
    final listing = discTitleListing(input);
    expect(listing.titles.map((t) => t.playlist), [5, 2]);
    expect(listing.hiddenCount, 1);
    expect(input.map((t) => t.playlist), [5, 2, 3]);
  });

  test('keeps selected short title and short VideoLAN main feature', () {
    final input = [title(1, 1200), title(2, 30, main: true), title(3, 2)];
    final listing = discTitleListing(input, selectedPlaylist: 3);
    expect(listing.titles, input);
    expect(listing.hiddenCount, 0);
  });

  test('all short titles remain selectable without a guessed main feature', () {
    final input = [title(1, 179), title(2, 60), title(3, 1)];
    expect(discTitleListing(input).titles, input);
  });

  test('show all restores exact order and objects without reparsing', () {
    final input = [title(5, 8246), title(2, 60), title(3, 1)];
    final listing = discTitleListing(input, showAll: true);
    expect(listing.titles, input);
    expect(identical(listing.titles[1], input[1]), isTrue);
    expect(listing.hiddenCount, 0);
  });

  test('episodes and alternative cuts do not depend on main duration ratio', () {
    final input = [title(1, 12000, main: true), title(2, 240), title(3, 300)];
    expect(discTitleListing(input).titles, input);
  });

  test('empty list remains empty', () {
    final listing = discTitleListing([]);
    expect(listing.titles, isEmpty);
    expect(listing.hiddenCount, 0);
  });
}
