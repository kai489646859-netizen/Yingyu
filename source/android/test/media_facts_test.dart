import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/playback/media_facts.dart';

void main() {
  const properties = {
    'vid': '1',
    'aid': '2',
    'seeking': 'no',
    'video-format': 'h264',
    'video-bitrate': '25000000',
    'video-params/w': '1920',
    'video-params/h': '1080',
    'audio-codec-name': 'truehd',
    'audio-bitrate': '3456789',
    'audio-params/channels': '5.1(side)',
    'audio-out-params/channels': 'stereo',
  };
  test(
    'reads actual video/audio packet bitrates without multiplying by speed',
    () {
      final reads = <String>[];
      final facts = readPlaybackMediaFacts(
        read: (key) {
          reads.add(key);
          return properties[key] ?? '';
        },
        active: () => true,
      );
      expect(mediaBitrate(facts['video-bitrate']), '25.00 Mbps');
      expect(mediaBitrate(facts['audio-bitrate']), '3.46 Mbps');
      expect(facts['audio-params/channels'], '5.1(side)');
      expect(facts['audio-out-params/channels'], 'stereo');
      expect(reads, isNot(contains('speed')));
      expect(reads, isNot(contains('file-size')));
    },
  );
  test('missing or unsafe properties remain unknown', () {
    final facts = readPlaybackMediaFacts(
      read: (key) {
        if (key == 'video-codec') {
          return 'https://private.invalid/file?token=secret';
        }
        if (key == 'audio-bitrate') throw StateError('unsupported');
        return properties[key] ?? '';
      },
      active: () => true,
    );
    expect(facts['video-codec'], isNull);
    expect(facts['audio-bitrate'], isNull);
    for (final value in [null, '', 'NaN', 'Infinity', '-1', '0']) {
      expect(mediaBitrate(value), '未提供');
    }
  });
  test('reads current-track Dolby evidence with the same guarded sample', () {
    final facts = readPlaybackMediaFacts(
      read: (key) =>
          {
            ...properties,
            'current-tracks/video/dolby-vision-profile': '8',
            'current-tracks/video/dolby-vision-level': '6',
            'video-params/colormatrix': 'dolbyvision',
          }[key] ??
          '',
      active: () => true,
    );
    expect(facts['current-tracks/video/dolby-vision-profile'], '8');
    expect(facts['current-tracks/video/dolby-vision-level'], '6');
    expect(facts['video-params/colormatrix'], 'dolbyvision');
  });
  test('a video switch cannot publish the previous track Dolby profile', () {
    var reads = 0;
    final facts = readPlaybackMediaFacts(
      read: (key) {
        if (key == 'vid') return ++reads == 1 ? '1' : '2';
        if (key == 'current-tracks/video/dolby-vision-profile') return '8';
        return properties[key] ?? '';
      },
      active: () => true,
    );
    expect(facts.values, isEmpty);
  });
  test(
    'audio switch during a sample never publishes the old track bitrate',
    () {
      var aidReads = 0;
      final facts = readPlaybackMediaFacts(
        read: (key) {
          if (key == 'aid') return ++aidReads == 1 ? '2' : '3';
          return properties[key] ?? '';
        },
        active: () => true,
      );
      expect(facts.values, isEmpty);
    },
  );
  test('seek or missing seek status does not publish mixed-position facts', () {
    for (final seeking in ['yes', '']) {
      final facts = readPlaybackMediaFacts(
        read: (key) => key == 'seeking' ? seeking : properties[key] ?? '',
        active: () => true,
      );
      expect(facts.values, isEmpty);
    }
  });
  test(
    'invalidated property ownership cannot publish another media or closed player',
    () {
      var active = true;
      final facts = readPlaybackMediaFacts(
        read: (key) {
          if (key == 'video-bitrate') active = false;
          return properties[key] ?? '';
        },
        active: () => active,
      );
      expect(facts.values, isEmpty);
    },
  );
}
