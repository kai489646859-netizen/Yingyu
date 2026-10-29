import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/stream_buffering.dart';

void main() {
  test(
    'ordinary ahead follows restored speed and seeks without a long resume gate',
    () async {
      final actual = <String, String>{};
      final buffer = StreamBuffering(
        write: (k, v) async => actual[k] = v,
        onRestoreFailure: () => fail('rollback'),
      );
      await buffer.configure(1, fast: true);
      expect(actual['cache-pause-wait'], '1.00');
      expect(actual['cache-secs'], '10');
      await buffer.configure(1, fast: false);
      expect(actual['cache-secs'], '60');
      await buffer.configure(2, fast: false);
      expect(actual['cache-secs'], '120');
      await buffer.configure(3, fast: false);
      expect(actual['cache-secs'], '180');
      await buffer.configure(2, fast: false);
      expect(actual['cache-secs'], '120');
      expect(actual['cache-pause-wait'], '8.00');
      await buffer.configure(2, fast: true);
      expect(actual['cache-secs'], '10');
      expect(actual['cache-pause-wait'], '1.00');
      await buffer.configure(2, fast: false);
      expect(actual['cache-secs'], '120');
      await buffer.configure(1, fast: false);
      expect(actual['cache-secs'], '60');
      expect(actual['cache-pause-wait'], '1.00');
    },
  );
}
