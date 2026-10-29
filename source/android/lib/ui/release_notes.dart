import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'expansion_chevron.dart';
import 'package:flutter/services.dart';
import '../core/release_notes.dart';
import '../version.dart';
import 'style.dart';
import 'surface.dart';

class ReleaseNotesPage extends StatefulWidget {
  const ReleaseNotesPage({super.key});
  @override
  State<ReleaseNotesPage> createState() => _ReleaseNotesPageState();
}

class _ReleaseNotesPageState extends State<ReleaseNotesPage> {
  bool copied = false;
  final expandedVersions = <String>{appVersion};
  String? error;
  @override
  Widget build(BuildContext context) => SurfacePage(
    title: '更新说明',
    heightRatio: .9,
    child: ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset('assets/yingyu.png', width: 48, height: 48),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '映屿',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
                  ),
                  Text('当前版本 $appVersion', style: TextStyle(fontSize: 13)),
                ],
              ),
            ),
            TextButton.icon(
              key: const Key('copy-app-version'),
              onPressed: () async {
                try {
                  await Clipboard.setData(
                    const ClipboardData(text: '映屿安卓播放器 $appVersion'),
                  );
                  if (mounted) {
                    setState(() {
                      copied = true;
                      error = null;
                    });
                  }
                } catch (_) {
                  if (mounted) setState(() => error = '复制失败，请重试');
                }
              },
              icon: const Icon(CupertinoIcons.doc_on_doc, size: 16),
              label: Text(copied ? '已复制' : '复制版本'),
            ),
          ],
        ),
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const SizedBox(height: 20),
        for (final note in displayedReleaseNotes)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Material(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              clipBehavior: Clip.antiAlias,
              child: ExpansionTile(
                key: PageStorageKey('release-${note.version}'),
                initiallyExpanded: expandedVersions.contains(note.version),
                onExpansionChanged: (expanded) => setState(() {
                  expanded
                      ? expandedVersions.add(note.version)
                      : expandedVersions.remove(note.version);
                }),
                trailing: ExpansionChevron(
                  expanded: expandedVersions.contains(note.version),
                  size: 16,
                ),
                shape: const Border(),
                collapsedShape: const Border(),
                title: Text(
                  '${note.version}${note.version == appVersion ? ' · 当前版本' : ''}',
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                subtitle: Text(
                  note.title,
                  style: TextStyle(
                    fontSize: 13,
                    color: secondaryColor(context),
                  ),
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  for (final change in note.changes)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('•  '),
                          Expanded(
                            child: Text(
                              change,
                              style: const TextStyle(fontSize: 14, height: 1.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
