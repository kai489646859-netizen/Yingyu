import 'package:flutter/cupertino.dart';
import '../core/emby.dart';
import '../core/interface_preferences.dart';
import '../core/models.dart';
import 'poster.dart';
import 'library_layout.dart';
import 'style.dart';

MediaItem personImage(Json person) => MediaItem({
  ...person,
  'Type': 'Person',
  'ImageTags': {
    ...object(person['ImageTags']),
    'Primary':
        object(person['ImageTags'])['Primary'] ??
        person['PrimaryImageTag'] ??
        '',
  },
});

class PeopleRail extends StatelessWidget {
  const PeopleRail({
    super.key,
    required this.api,
    required this.people,
    required this.onItem,
    this.title = '演职员',
  });
  final EmbyClient api;
  final List<Json> people;
  final Future<void> Function(MediaItem) onItem;
  final String title;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        title,
        style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 12),
      SizedBox(
        height: 176 * MediaQuery.textScalerOf(context).scale(14) / 14,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: people.length,
          separatorBuilder: (_, _) => const SizedBox(width: 12),
          itemBuilder: (context, index) {
            final p = people[index];
            final image = personImage(p);
            final name = '${p['Name'] ?? ''}';
            return SizedBox(
              key: ValueKey('person:${image.id}:$name'),
              width: 88,
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                pressedOpacity: 1,
                onPressed: name.isEmpty
                    ? null
                    : () => Navigator.push(
                        context,
                        CupertinoPageRoute<void>(
                          builder: (_) =>
                              PeoplePage(api: api, person: p, onItem: onItem),
                        ),
                      ),
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      clipBehavior: Clip.antiAliasWithSaveLayer,
                      child: SizedBox(
                        width: 88,
                        height: 92,
                        child: Poster(
                          kind: PosterKind.actor,
                          url: image.id.isEmpty || image.imageTag.isEmpty
                              ? null
                              : api.imageUrl(image),
                        ),
                      ),
                    ),
                    const SizedBox(height: 7),
                    Text(
                      name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: labelColor(context),
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      '${p['Role'] ?? (p['Type'] == 'Person' ? '演员' : p['Type']) ?? ''}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: secondaryColor(context),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ],
  );
}

class PeoplePage extends StatefulWidget {
  const PeoplePage({
    super.key,
    required this.api,
    required this.onItem,
    this.person,
  });
  final EmbyClient api;
  final Json? person;
  final Future<void> Function(MediaItem) onItem;
  @override
  State<PeoplePage> createState() => _PeoplePageState();
}

class _PeoplePageState extends State<PeoplePage> {
  final text = TextEditingController();
  late final account = widget.api.session;
  final people = <MediaItem>[], films = <MediaItem>[];
  bool busy = false, more = false;
  int revision = 0, offset = 0;
  String? error;
  Json? selected;
  @override
  void initState() {
    super.initState();
    selected = widget.person;
    if (selected != null) loadFilms();
  }

  bool current(int r) =>
      mounted && r == revision && widget.api.session == account;
  Future<void> search() async {
    if (widget.api.session != account) return;
    final term = text.text.trim();
    final r = ++revision;
    setState(() {
      selected = null;
      people.clear();
      films.clear();
      offset = 0;
      error = null;
      more = false;
      busy = term.isNotEmpty;
    });
    if (term.isEmpty) {
      return;
    }
    try {
      final page = await widget.api.people(term);
      if (current(r)) {
        setState(() {
          people.addAll(page.items);
          more = page.items.length < page.total;
          offset = page.items.length;
        });
      }
    } catch (e) {
      if (current(r)) setState(() => error = safeError(e));
    } finally {
      if (current(r)) setState(() => busy = false);
    }
  }

  Future<void> morePeople() async {
    if (busy || !more) return;
    final r = revision;
    setState(() => busy = true);
    try {
      final page = await widget.api.people(text.text.trim(), start: offset);
      if (current(r)) {
        setState(() {
          people.addAll(page.items);
          offset += page.items.length;
          more = page.items.isNotEmpty && offset < page.total;
        });
      }
    } catch (e) {
      if (current(r)) setState(() => error = safeError(e));
    } finally {
      if (current(r)) setState(() => busy = false);
    }
  }

  Future<void> loadFilms({bool reset = true}) async {
    final person = selected;
    if (widget.api.session != account || person == null || (!reset && busy)) {
      return;
    }
    final r = reset ? ++revision : revision;
    setState(() {
      busy = true;
      error = null;
      if (reset) {
        films.clear();
        offset = 0;
      }
    });
    try {
      final page = await widget.api.personItems(
        id: person['Id']?.toString(),
        name: person['Name']?.toString(),
        start: offset,
      );
      if (current(r)) {
        setState(() {
          final ids = films.map((e) => e.id).toSet();
          films.addAll(page.items.where((e) => ids.add(e.id)));
          offset += page.items.length;
          more = page.items.isNotEmpty && offset < page.total;
        });
      }
    } catch (e) {
      if (current(r)) setState(() => error = safeError(e));
    } finally {
      if (current(r)) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    revision++;
    text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CupertinoPageScaffold(
    navigationBar: CupertinoNavigationBar(
      middle: Text(selected == null ? '搜索演员' : '${selected!['Name']}的影片'),
    ),
    child: SafeArea(
      child: Column(
        children: [
          if (widget.person == null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: CupertinoSearchTextField(
                controller: text,
                placeholder: '输入演员名字，搜索 Emby',
                onSubmitted: (_) => search(),
                onSuffixTap: () {
                  text.clear();
                  search();
                },
              ),
            ),
          if (busy) const CupertinoActivityIndicator(),
          if (error != null)
            Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
          Expanded(
            child: selected == null
                ? ListView(
                    children: [
                      for (final p in people)
                        CupertinoListTile(
                          title: Text(p.title),
                          trailing: const CupertinoListTileChevron(),
                          onTap: () {
                            selected = p.data;
                            loadFilms();
                          },
                        ),
                      if (!busy && people.isEmpty)
                        const Center(child: Text('输入演员名字并搜索；结果以当前 Emby 为准')),
                      if (more)
                        CupertinoButton(
                          onPressed: busy ? null : morePeople,
                          child: const Text('加载更多演员'),
                        ),
                    ],
                  )
                : LayoutBuilder(
                    builder: (context, size) {
                      final m = LibraryGridMetrics(
                        size.maxWidth,
                        MediaQuery.textScalerOf(context).scale(14) / 14,
                        LibraryDisplay.posters,
                        phone: phoneLayout(context),
                      );
                      return CustomScrollView(
                        slivers: [
                          SliverPadding(
                            padding: EdgeInsets.all(m.inset),
                            sliver: SliverGrid(
                              gridDelegate:
                                  SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: m.columns,
                                    mainAxisExtent: m.rowHeight,
                                    crossAxisSpacing: m.spacing,
                                    mainAxisSpacing: 16,
                                  ),
                              delegate: SliverChildBuilderDelegate(
                                (context, i) => LibraryPosterCard(
                                  item: films[i],
                                  api: widget.api,
                                  active: widget.api.session == account,
                                  onTap: () {
                                    if (widget.api.session == account) {
                                      widget.onItem(films[i]);
                                    }
                                  },
                                ),
                                childCount: films.length,
                              ),
                            ),
                          ),
                          if (!busy && films.isEmpty)
                            const SliverToBoxAdapter(
                              child: Center(child: Text('Emby 未返回该演员的影片')),
                            ),
                          if (more)
                            SliverToBoxAdapter(
                              child: CupertinoButton(
                                onPressed: busy
                                    ? null
                                    : () => loadFilms(reset: false),
                                child: const Text('加载更多'),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}
