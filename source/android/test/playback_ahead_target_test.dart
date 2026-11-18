import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/stream_buffering.dart';

void main() {
  test(
    'all speeds use one steady packet window while seeking still uses a small window',
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
      expect(actual['cache-secs'], '3600000');
      await buffer.configure(2, fast: false);
      expect(actual['cache-secs'], '3600000');
      await buffer.configure(3, fast: false);
      expect(actual['cache-secs'], '3600000');
      await buffer.configure(2, fast: false);
      expect(actual['cache-secs'], '3600000');
      expect(actual['cache-pause-wait'], '8.00');
      await buffer.configure(2, fast: true);
      expect(actual['cache-secs'], '10');
      expect(actual['cache-pause-wait'], '1.00');
      await buffer.configure(2, fast: false);
      expect(actual['cache-secs'], '3600000');
      await buffer.configure(1, fast: false);
      expect(actual['cache-secs'], '3600000');
      expect(actual['cache-pause-wait'], '1.00');
    },
  );
}
