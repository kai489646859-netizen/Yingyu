import 'package:flutter/cupertino.dart';
import '../core/models.dart';
import '../core/video_labels.dart';
import 'style.dart';

/// Source-scoped display only. Never opens media or resolves another episode.
class ResourceTags extends StatelessWidget {
  const ResourceTags({super.key, required this.video, this.compact = false});
  final Json video;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final labels = resourceLabels(video);
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final label in labels.isEmpty ? ['格式未知'] : labels)
          Container(
            padding: EdgeInsets.symmetric(
              horizontal: 6,
              vertical: compact ? 2 : 3,
            ),
            decoration: BoxDecoration(
              color: accentColor(context).withValues(alpha: .10),
              border: Border.all(
                color: accentColor(context).withValues(alpha: .25),
                width: .5,
              ),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: compact ? 10 : 11,
                fontWeight: FontWeight.w500,
                color: accentColor(context),
              ),
            ),
          ),
      ],
    );
  }
}
