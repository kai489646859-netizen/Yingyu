import 'package:flutter/cupertino.dart';
import 'style.dart';
import 'swipe_pages.dart';

/// Compact horizontal choices, matching the supplied search reference.
/// Colors belong to these controls, never to the surrounding media text.
class FilterChoice {
  const FilterChoice(this.id, this.label);
  final String id, label;
}

class FilterChips extends StatelessWidget {
  const FilterChips({
    super.key,
    required this.name,
    required this.choices,
    required this.selected,
    required this.onSelected,
  });
  final String name, selected;
  final List<FilterChoice> choices;
  final ValueChanged<String> onSelected;
  @override
  Widget build(BuildContext context) => HorizontalPageSwipeBoundary(
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: contentInset(context)),
      child: Row(
        children: [
          for (final choice in choices)
            Padding(
              padding: const EdgeInsets.only(right: 6, bottom: 3, top: 3),
              child: Semantics(
                selected: choice.id == selected,
                button: true,
                child: CupertinoButton(
                  key: ValueKey('$name-${choice.id}'),
                  minimumSize: const Size(40, 40),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  borderRadius: BorderRadius.circular(22),
                  color: choice.id == selected ? accentColor(context) : null,
                  onPressed: () => onSelected(choice.id),
                  child: Text(
                    choice.label,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.25,
                      fontWeight: choice.id == selected
                          ? FontWeight.w600
                          : FontWeight.w400,
                      color: choice.id == selected
                          ? CupertinoTheme.of(context).brightness ==
                                    Brightness.dark
                                ? const Color(0xFF000000)
                                : const Color(0xFFFFFFFF)
                          : labelColor(context),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
