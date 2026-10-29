import 'catalog.dart';
import 'catalog_filters.dart';
import 'models.dart';
import 'version_groups.dart';

/// Filtering and version grouping share the same worker for large catalogues.
/// All grouping still uses exact account/type/provider identities.
CatalogView projectCatalog(
  (List<MediaItem>, String, bool?, CatalogFilters?, Session) input,
) {
  final (source, query, played, filters, account) = input;
  final selected = filters == null
      ? selectCatalog((source, query, played))
      : selectFilteredCatalog((source, query, played, filters));
  return groupVersions(selected.items, account);
}
