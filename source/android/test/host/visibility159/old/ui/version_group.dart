import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../core/accounts.dart';
import '../core/browse_cache.dart';
import '../core/emby.dart';
import '../core/models.dart';
import '../core/version_groups.dart';
import 'style.dart';
import 'surface.dart';

class VersionBadge extends StatelessWidget {
  const VersionBadge({super.key, required this.item});
  final MediaItem item;
  @override
  Widget build(BuildContext context) {
    final group = item;
    if (group is! VersionGroup) return const SizedBox.shrink();
    return Positioned(
      left: 4,
      // Series already use the upper-right corner for their episode count.
      // A separate row keeps both labels readable on narrow phone posters.
      top: group.series ? 38 : 6,
      child: IgnorePointer(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xD9232328),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            '${group.versions.length} 个版本',
            textScaler: TextScaler.noScaling,
            style: const TextStyle(color: Colors.white, fontSize: 11),
          ),
        ),
      ),
    );
  }
}

/// Resolve metadata only when the user opens the chooser. No media URL or
/// PlaybackInfo is requested, and late data cannot cross an account change.
class VersionChooser extends StatefulWidget {
  const VersionChooser({
    super.key,
    required this.group,
    required this.api,
    required this.browse,
  });
  final VersionGroup group;
  final EmbyClient api;
  final BrowseRepository browse;
  @override
  State<VersionChooser> createState() => _VersionChooserState();
}

class _VersionChooserState extends State<VersionChooser> {
  final details = <String, MediaItem>{};
  final failures = <String, String>{};
  bool get valid =>
      mounted &&
      widget.api.session != null &&
      accountKey(widget.api.session!) == widget.group.owner;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    // Serial and demand-bound: closing the chooser stops further detail reads.
    for (final item in widget.group.versions) {
      if (!valid) return;
      await read(item);
    }
  }

  Future<void> read(MediaItem item) async {
    if (!valid) return;
    setState(() => failures.remove(item.id));
    try {
      final cached = widget.browse.peek('detail:${item.id}')?.items.firstOrNull;
      final detail = await widget.browse.detail(
        item.id,
        force: cached != null && cached.data['_YingyuVideoMetadataV1'] != true,
      );
      if (detail.id != item.id) throw const AppFailure('服务器返回的版本编号不一致');
      if (valid) setState(() => details[item.id] = detail);
    } catch (e) {
      if (valid) setState(() => failures[item.id] = safeError(e));
    }
  }

  @override
  Widget build(BuildContext context) => SurfacePage(
    title: '选择版本',
    heightRatio: .65,
    child: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          widget.group.title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          '各版本的观看进度分别保存',
          style: TextStyle(fontSize: 13, color: secondaryColor(context)),
        ),
        for (var i = 0; i < widget.group.versions.length; i++)
          Builder(
            builder: (context) {
              final original = widget.group.versions[i];
              final item = details[original.id];
              final error = failures[original.id];
              final description = versionDescription(item ?? original);
              return SettingsRow(
                '${i + 1}. ${original.title}',
                subtitle: [
                  if (description.isNotEmpty) description,
                  if (item != null)
                    item.resume > Duration.zero
                        ? '已看 ${item.resume.inMinutes} 分钟'
                        : object(item.data['UserData'])['Played'] == true
                        ? '已看完'
                        : '未观看',
                  if (error != null) '$error · 点此重试',
                  if (item == null && error == null) '读取版本资料…',
                ].join('\n'),
                trailing: item == null && error == null
                    ? const CupertinoActivityIndicator()
                    : null,
                onTap: !valid
                    ? null
                    : error != null
                    ? () => read(original)
                    : item == null
                    ? null
                    : () => Navigator.pop(context, item),
              );
            },
          ),
      ],
    ),
  );
}
