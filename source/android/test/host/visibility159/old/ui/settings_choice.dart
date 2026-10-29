import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'style.dart';
import 'anchored_menu.dart';
import 'poster_press.dart';

/// The arrow lines up with its title, regardless of the description's height.
class SettingsMenuRow extends StatelessWidget {
  const SettingsMenuRow({
    super.key,
    required this.title,
    this.subtitle,
    this.icon,
    required this.trigger,
    this.onTap,
  });
  final String title;
  final String? subtitle;
  final IconData? icon;
  final Widget trigger;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => PosterPressFeedback(
    active: onTap != null,
    child: CupertinoButton(
      pressedOpacity: 1,
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: phoneValue(context, 14, 20),
          vertical: 8,
        ),
        child: phoneLayout(context)
            ? Row(
                children: [
                  if (icon != null) ...[
                    SettingsIcon(icon!),
                    const SizedBox(width: 10),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 15,
                            color: labelColor(context),
                          ),
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            subtitle!,
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.35,
                              color: secondaryColor(context),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  trigger,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (icon != null) ...[
                        SettingsIcon(icon!),
                        SizedBox(width: phoneValue(context, 10, 14)),
                      ],
                      Expanded(
                        child: Text(
                          title,
                          style: TextStyle(
                            fontSize: phoneValue(context, 15, 16),
                            color: labelColor(context),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      trigger,
                    ],
                  ),
                  if (subtitle != null)
                    Padding(
                      padding: EdgeInsets.only(
                        left: icon == null ? 0 : phoneValue(context, 36, 42),
                        right: phoneValue(context, 12, 56),
                        bottom: phoneValue(context, 4, 6),
                      ),
                      child: Text(
                        subtitle!,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.35,
                          color: secondaryColor(context),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    ),
  );
}

/// The whole row opens choices, still anchored to the unchanged arrow button.
class SettingsChoice<T> extends StatelessWidget {
  const SettingsChoice({
    super.key,
    required this.id,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.choices,
    required this.onChanged,
    this.icon,
    this.enabled = true,
    this.choiceIcon,
    this.reducedMotion = false,
  });
  final String id, title, subtitle;
  final T value;
  final Map<T, String> choices;
  final ValueChanged<T> onChanged;
  final IconData? icon;
  final bool enabled, reducedMotion;
  final Widget Function(T)? choiceIcon;
  @override
  Widget build(BuildContext context) {
    final controller = AnchoredMenuController();
    return SettingsMenuRow(
      title: title,
      key: ValueKey(id),
      subtitle: subtitle,
      icon: icon,
      onTap: enabled ? controller.open : null,
      trigger: AnchoredMenuButton<T>(
        controller: controller,
        interactive: false,
        id: '$id-arrow',
        label: '$title，展开选项',
        expandedIcon: CupertinoIcons.chevron_down,
        iconSize: 18,
        enabled: enabled,
        reducedMotion: reducedMotion,
        color: accentColor(context),
        menuWidth: compactMenuWidth(
          context,
          choices.values,
          extra: choiceIcon == null ? 32 : 60,
          fontSize: phoneValue(context, 15, 16),
        ),
        onSelected: (selected) {
          if (selected != value) onChanged(selected);
        },
        items: (context) => [
          for (final choice in choices.entries)
            PopupMenuItem<T>(
              key: ValueKey('$id-choice-${choice.key}'),
              value: choice.key,
              height: phoneValue(context, 48, 50),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Semantics(
                selected: value == choice.key,
                child: Row(
                  children: [
                    if (choiceIcon != null) ...[
                      choiceIcon!(choice.key),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        choice.value,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: phoneValue(context, 15, 16),
                          fontFamily: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.fontFamily,
                          fontWeight: FontWeight.w400,
                          height: 1.3,
                          color: value == choice.key
                              ? accentColor(context)
                              : labelColor(context),
                        ),
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
}

/// Single actions open their existing page/confirmation directly, without a submenu.
class SettingsAction extends StatelessWidget {
  const SettingsAction({
    super.key,
    required this.id,
    required this.title,
    required this.actionLabel,
    required this.onAction,
    this.subtitle,
    this.icon,
    this.enabled = true,
    this.reducedMotion = false,
  });
  final String id, title, actionLabel;
  final String? subtitle;
  final IconData? icon;
  final VoidCallback onAction;
  final bool enabled, reducedMotion;
  @override
  Widget build(BuildContext context) => SettingsMenuRow(
    key: ValueKey(id),
    title: title,
    subtitle: subtitle,
    icon: icon,
    onTap: enabled ? onAction : null,
    trigger: Semantics(
      label: '$title，$actionLabel',
      button: false,
      child: SizedBox(
        width: 44,
        height: 44,
        child: Center(
          key: ValueKey('$id-arrow'),
          child: Icon(
            CupertinoIcons.chevron_forward,
            size: 18,
            color: enabled ? accentColor(context) : secondaryColor(context),
          ),
        ),
      ),
    ),
  );
}
