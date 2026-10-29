import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/disc_startup.dart';

void main() {
  const key = 'skip_estimate_duration_from_pts';
  for (final previous in [
    '',
    'seg_max_retry=5,strict=experimental,allowed_extensions=ALL,protocol_whitelist=file,http,https,tcp,tls',
  ]) {
    test(
      'disc setup preserves the existing option map: ${previous.isEmpty ? "empty" : "media_kit defaults"}',
      () async {
        var value = previous;
        final commands = <List<String>>[];
        final setup = DiscStartupSetup();
        Future<String> prepare(bool disc) => setup.prepare(
          hasPlaylistTimeline: disc,
          read: (_) async => value,
          command: (args) async {
            commands.add(args);
            value = value.isEmpty ? args.last : '$value,${args.last}';
          },
        );
        await prepare(false);
        expect(commands, isEmpty);
        await prepare(true);
        await prepare(true);
        expect(commands, [
          ['change-list', 'demuxer-lavf-o', 'append', '$key=1'],
        ]);
        expect(value, previous.isEmpty ? '$key=1' : '$previous,$key=1');
      },
    );
  }

  test('an explicit duration setting is never overwritten', () async {
    final commands = <List<String>>[];
    await DiscStartupSetup().prepare(
      hasPlaylistTimeline: true,
      read: (_) async => 'custom=value,$key=0',
      command: (args) async => commands.add(args),
    );
    expect(commands, isEmpty);
  });

  test(
    'a silently rejected append is detected and only its own key is removed',
    () async {
      final commands = <List<String>>[];
      final message = await DiscStartupSetup().prepare(
        hasPlaylistTimeline: true,
        read: (_) async => 'custom=kept',
        command: (args) async => commands.add(args),
      );
      expect(message, contains('未启用'));
      expect(commands.last, ['change-list', 'demuxer-lavf-o', 'remove', key]);
    },
  );

  test(
    'failed append restores existing options without serializing their values again',
    () async {
      var value = 'custom=[has,commas]';
      final message = await DiscStartupSetup().prepare(
        hasPlaylistTimeline: true,
        read: (_) async => value,
        command: (args) async {
          if (args[2] == 'append') {
            value += ',$key=1';
            throw StateError('synthetic command failure');
          }
          value = 'custom=[has,commas]';
        },
      );
      expect(message, contains('未启用'));
      expect(value, 'custom=[has,commas]');
    },
  );

  test(
    'an unverified rollback is an error instead of a claimed fallback',
    () async {
      var value = 'custom=kept';
      await expectLater(
        DiscStartupSetup().prepare(
          hasPlaylistTimeline: true,
          read: (_) async => value,
          command: (args) async {
            if (args[2] == 'append') value = 'unexpected=$key';
          },
        ),
        throwsStateError,
      );
    },
  );
}
