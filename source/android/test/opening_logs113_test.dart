import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/opening_logs.dart';

void main() {
  testWidgets('slow opening stops protocol tracing after eight seconds', (
    tester,
  ) async {
    var requested = 'warn';
    var rule = 'all=warn';
    final policy = OpeningLogs(
      read: (_) async => rule,
      write: (_, value) async {
        rule = value;
      },
      request: (value) {
        requested = value;
        return 0;
      },
    );
    await policy.start();
    await tester.pump(const Duration(seconds: 7));
    expect(requested, 'terminal-default');
    await tester.pump(const Duration(seconds: 1));
    expect(requested, 'warn');
    expect(rule, 'all=warn');
    expect(policy.enabled, false);
    await policy.close();
  });
  test(
    'exit during pending native configuration restores the original policy',
    () async {
      final gate = Completer<void>();
      var rule = 'all=error';
      var requested = 'warn';
      final policy = OpeningLogs(
        read: (_) async => rule,
        write: (_, value) async {
          if (value == OpeningLogs.rules) await gate.future;
          rule = value;
        },
        request: (value) {
          requested = value;
          return 0;
        },
      );
      final starting = policy.start();
      await Future<void>.delayed(Duration.zero);
      final closing = policy.close();
      gate.complete();
      await Future.wait([starting, closing]);
      expect(rule, 'all=error');
      expect(requested, 'warn');
      expect(policy.enabled, false);
    },
  );
  test(
    'rejected scope and failed restore still retain warning subscription',
    () async {
      var requested = 'warn';
      final policy = OpeningLogs(
        read: (_) async => 'all=warn',
        write: (_, value) async {
          if (value == 'all=warn') throw StateError('restore rejected');
        },
        request: (value) {
          requested = value;
          return value == 'terminal-default' ? -1 : 0;
        },
      );
      await policy.start();
      expect(requested, 'warn');
      expect(policy.enabled, false);
      expect(policy.restored, false);
      await policy.close();
    },
  );
  test(
    'opening HTTP diagnostics do not deliver packet/frame trace traffic',
    () async {
      var requested = 'warn';
      var rule = 'all=warn';
      final policy = OpeningLogs(
        read: (_) async => rule,
        write: (_, value) async {
          rule = value;
        },
        request: (level) {
          requested = level;
          return 0;
        },
      );
      await policy.start();
      // The pinned mpv producer uses prefix thresholds for terminal-default;
      // a global trace subscription admits all topics regardless of msg-level.
      bool delivered(String topic, bool warning) {
        if (warning) return true;
        if (requested == 'trace') return true;
        if (requested != 'terminal-default') return false;
        var level = 'warn';
        for (final entry in rule.split(',')) {
          final parts = entry.split('=');
          if (parts.length != 2) continue;
          if ((parts[0] == 'all' ||
              topic == parts[0] ||
              topic.startsWith('${parts[0]}/'))) {
            level = parts[1];
          }
        }
        return level == 'trace';
      }

      final frameMessages = List.generate(
        10000,
        (_) => delivered('ffmpeg/video', false),
      ).where((v) => v).length;
      final packetMessages = List.generate(
        10000,
        (_) => delivered('demux/lavf', false),
      ).where((v) => v).length;
      expect(frameMessages + packetMessages, 0);
      expect(delivered('ffmpeg', false), true);
      expect(delivered('ffmpeg/video', true), true);
      await policy.close();
      expect(requested, 'warn');
      expect(rule, 'all=warn');
    },
  );
}
