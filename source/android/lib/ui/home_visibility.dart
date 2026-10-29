import 'package:flutter/widgets.dart';
import '../core/home_order.dart';
import '../core/models.dart';
import 'style.dart';

class HomeVisibilityScope extends InheritedNotifier<HomeOrder> {
  const HomeVisibilityScope({
    super.key,
    required HomeOrder order,
    required super.child,
  }) : super(notifier: order);

  static HomeOrder? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<HomeVisibilityScope>()
      ?.notifier;

  static List<MediaItem> visible(
    BuildContext context,
    Session account,
    List<MediaItem> items,
  ) => of(context)?.visible(account, items) ?? items;
}

class VisibilityStatus extends StatelessWidget {
  const VisibilityStatus({super.key, required this.account});
  final Session account;
  @override
  Widget build(BuildContext context) {
    final policy = HomeVisibilityScope.of(context);
    if (policy == null || policy.ready(account)) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Text(
        policy.visibilityError(account) ?? '正在核对分区可见范围',
        style: TextStyle(color: secondaryColor(context), fontSize: 13),
      ),
    );
  }
}
