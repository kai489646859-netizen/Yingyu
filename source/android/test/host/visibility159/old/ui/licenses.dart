import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../version.dart';
import 'style.dart';
import 'surface.dart';

class LicensesPage extends StatefulWidget {
  const LicensesPage({super.key});
  @override
  State<LicensesPage> createState() => _LicensesPageState();
}

class _LicensesPageState extends State<LicensesPage> {
  late final entries = LicenseRegistry.licenses.toList();
  @override
  Widget build(BuildContext context) => SurfacePage(
    title: '开源许可',
    child: FutureBuilder<List<LicenseEntry>>(
      future: entries,
      builder: (context, snapshot) {
        if (snapshot.hasError) return const MessagePanel('许可信息读取失败');
        if (!snapshot.hasData) return const MessagePanel('正在读取许可', busy: true);
        return ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Image.asset('assets/yingyu.png', width: 64, height: 64),
                  const SizedBox(height: 12),
                  const Text(
                    '映屿 $appVersion',
                    style: TextStyle(fontSize: 21, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'NipaPlay-Reload v1.11.9 Cupertino 外观参考（MIT）\n映屿按 GPL-3.0 交付',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: secondaryColor(context),
                    ),
                  ),
                ],
              ),
            ),
            for (final entry in snapshot.data!)
              SettingsRow(
                entry.packages.join(', '),
                onTap: () => showSurface<void>(
                  context,
                  (_) => SurfacePage(
                    title: entry.packages.join(', '),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(20),
                      child: SelectableText(
                        entry.paragraphs.map((p) => p.text).join('\n\n'),
                        style: const TextStyle(fontSize: 13, height: 1.5),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    ),
  );
}
