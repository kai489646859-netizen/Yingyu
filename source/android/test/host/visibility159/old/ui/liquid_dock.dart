import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'device_layout.dart';
import 'visual_effects.dart';

/// Compact, floating navigation. Only the selection listens to page pixels;
/// the glass material, hit targets and text remain outside that rebuild.
class LiquidDock extends StatelessWidget {
  const LiquidDock({
    super.key,
    required this.index,
    required this.onChanged,
    this.reducedMotion = false,
    this.progress,
    this.onSearch,
  });
  final int index;
  final ValueChanged<int> onChanged;
  final bool reducedMotion;
  final ValueListenable<double>? progress;
  final VoidCallback? onSearch;
  @override
  Widget build(BuildContext context) {
    final phone = phoneLayout(context);
    final reduce = reducedMotion || MediaQuery.disableAnimationsOf(context);
    final scheme = Theme.of(context).colorScheme;
    final height = phone ? 62.0 : 68.0;
    const labels = ['首页', '媒体库', '设置', '账户'];
    const icons = [
      CupertinoIcons.house_fill,
      CupertinoIcons.rectangle_stack_fill,
      CupertinoIcons.settings_solid,
      CupertinoIcons.person_fill,
    ];
    final navigation = AppGlassSurface(
      key: const Key('liquid-dock-material'),
      radius: 32,
      role: GlassRole.dock,
      child: SizedBox(
        key: const Key('liquid-dock-body'),
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: LayoutBuilder(
            builder: (context, bounds) {
              final width = bounds.maxWidth / 4;
              final indicator = const IgnorePointer(
                child: RepaintBoundary(
                  child: GlassControlSkin(
                    key: Key('navigation-glass-indicator'),
                    radius: 26,
                    selected: true,
                    child: SizedBox.expand(),
                  ),
                ),
              );
              return Stack(
                children: [
                  if (progress != null)
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: width,
                      child: ValueListenableBuilder<double>(
                        valueListenable: progress!,
                        child: indicator,
                        builder: (context, page, child) => Transform.translate(
                          offset: Offset(page.clamp(0, 3) * width, 0),
                          child: child,
                        ),
                      ),
                    ),
                  if (progress == null)
                    AnimatedPositioned(
                      left: index * width,
                      top: 0,
                      bottom: 0,
                      width: width,
                      duration: reduce
                          ? Duration.zero
                          : const Duration(milliseconds: 300),
                      curve: Curves.easeInOutCubic,
                      child: indicator,
                    ),
                  Row(
                    children: [
                      for (var i = 0; i < 4; i++)
                        Expanded(
                          child: Semantics(
                            selected: index == i,
                            button: true,
                            child: CupertinoButton(
                              key: ValueKey('navigation-tab-$i'),
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(44, 44),
                              onPressed: () => onChanged(i),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    icons[i],
                                    size: phone ? 22 : 24,
                                    color: index == i
                                        ? scheme.primary
                                        : scheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    labels[i],
                                    textScaler: TextScaler.noScaling,
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: index == i
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                      color: index == i
                                          ? scheme.primary
                                          : scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
    return Align(
      heightFactor: 1,
      alignment: Alignment.bottomCenter,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: phone ? 440 : 520),
        child: phone && onSearch != null
            ? Row(
                children: [
                  Expanded(child: navigation),
                  const SizedBox(width: 10),
                  AppGlassSurface(
                    radius: 31,
                    role: GlassRole.dock,
                    child: SizedBox(
                      width: 62,
                      height: 62,
                      child: CupertinoButton(
                        padding: EdgeInsets.zero,
                        onPressed: onSearch,
                        child: Icon(
                          CupertinoIcons.search,
                          color: scheme.onSurface,
                          semanticLabel: '搜索影片或演员',
                        ),
                      ),
                    ),
                  ),
                ],
              )
            : navigation,
      ),
    );
  }
}
