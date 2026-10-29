import 'disc_transport.dart';

/// Presentation only: retain every title for explicit selection and saved
/// choices. Short standalone films and episode-only discs stay fully visible.
class DiscTitleListing {
  const DiscTitleListing(this.titles, this.hiddenCount);
  final List<DiscTitle> titles;
  final int hiddenCount;
}

DiscTitleListing discTitleListing(
  List<DiscTitle> titles, {
  int? selectedPlaylist,
  bool showAll = false,
}) {
  const shortTicks = 180 * 90000;
  if (showAll || !titles.any((title) => title.duration >= shortTicks)) {
    return DiscTitleListing(List.unmodifiable(titles), 0);
  }
  final visible = titles
      .where(
        (title) =>
            title.duration >= shortTicks ||
            title.mainFeature ||
            title.playlist == selectedPlaylist,
      )
      .toList(growable: false);
  return DiscTitleListing(
    List.unmodifiable(visible),
    titles.length - visible.length,
  );
}
