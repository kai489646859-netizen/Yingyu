import 'catalog.dart';
import 'models.dart';

enum CatalogKind { all, series, movie, favorite }

class CatalogFilters {
  const CatalogFilters({this.kind = CatalogKind.all, this.year, this.decade});
  final CatalogKind kind;
  final int? year, decade;

  bool accepts(MediaItem item) {
    final user = object(item.data['UserData']);
    if (switch (kind) {
      CatalogKind.all => false,
      CatalogKind.series => item.type != 'Series',
      CatalogKind.movie => item.type != 'Movie',
      CatalogKind.favorite => user['IsFavorite'] != true,
    }) {
      return false;
    }
    final released = releaseYear(item);
    if (year != null && released != year) return false;
    if (decade != null &&
        (released == null || released < decade! || released >= decade! + 10)) {
      return false;
    }
    return true;
  }
}

int? releaseYear(MediaItem item) {
  final value = int.tryParse('${item.data['ProductionYear'] ?? ''}');
  if (value != null && value > 0 && value <= 9999) return value;
  return DateTime.tryParse('${item.data['PremiereDate'] ?? ''}')?.year;
}

CatalogView selectFilteredCatalog(
  (List<MediaItem>, String, bool?, CatalogFilters) input,
) {
  final (source, query, played, filters) = input;
  // UserData must explicitly confirm a watched-state filter. Missing metadata
  // is unknown, not automatically unwatched. Apply before version grouping.
  final selected = source
      .where(
        (item) =>
            filters.accepts(item) &&
            (played == null ||
                object(item.data['UserData'])['Played'] == played),
      )
      .toList();
  return selectCatalog((selected, query, null));
}
