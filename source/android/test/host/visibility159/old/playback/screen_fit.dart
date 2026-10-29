/// Per-player fit on an already selected screen-sized output canvas. Only
/// panscan changes; no decoding, seek, source or subtitle selection is touched.
class ScreenFit {
  ScreenFit({required this.read, required this.write, required this.active});
  final Future<String> Function(String) read;
  final Future<void> Function(String, String) write;
  final bool Function() active;
  Future<void> _tail = Future.value();
  Future<void> set(bool fill) {
    final result = _tail.then((_) async {
      if (!active()) return;
      final before = await read('panscan');
      if (!active()) return;
      try {
        await write('panscan', fill ? '1' : '0');
        if (!active()) return;
        if (double.tryParse(await read('panscan')) != (fill ? 1 : 0)) {
          throw StateError('画面适配未确认');
        }
      } catch (_) {
        if (active()) {
          await write('panscan', before);
          if (await read('panscan') != before) {
            throw StateError('画面适配恢复失败');
          }
        }
        rethrow;
      }
    });
    _tail = result.catchError((Object _) {});
    return result;
  }

  Future<void> close() => _tail;
}
