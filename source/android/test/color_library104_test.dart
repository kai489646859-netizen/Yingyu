import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/core/unplayed_groups.dart';
import 'package:yingyu/playback/media_notice.dart';
import 'package:yingyu/playback/playback_adjustments.dart';
import 'package:yingyu/playback/shadow_enhancement.dart';

void main() {
  MediaItem episode(String id, String series, int number) => MediaItem({
    'Id': id,
    'Type': 'Episode',
    'SeriesId': series,
    'SeriesName': '同名剧集',
    'Name': '第 $number 集',
    'IndexNumber': number,
    'ParentIndexNumber': 1,
    'SeriesPrimaryImageTag': 'synthetic',
    'UserData': {'Played': true},
  });
  test(
    'played list groups by real series ID without altering any episode flags',
    () {
      final rows = [
        episode('e1', 's1', 1),
        episode('e2', 's1', 2),
        episode('e3', 's2', 1),
        episode('e4', '', 1),
        episode('e5', '', 2),
        MediaItem({'Id': 'm1', 'Type': 'Movie', 'Name': '同名电影'}),
        MediaItem({'Id': 'm2', 'Type': 'Movie', 'Name': '同名电影'}),
      ];
      final grouped = groupPlayed(rows);
      expect(grouped.map((e) => e.id), ['s1', 's2', 'e4', 'e5', 'm1', 'm2']);
      expect(grouped.first.title, '同名剧集');
      expect(grouped.first.data['Type'], 'Series');
      expect(
        object(grouped.first.data['UserData'])['Played'],
        isNull,
        reason: 'Some played episodes must not mark a complete show played.',
      );
      expect(grouped.first.data['Overview'], contains('2 集'));
      expect(
        rows.take(5).every((e) => object(e.data['UserData'])['Played'] == true),
        true,
      );
      expect(groupPlayed([rows[0], rows[1], rows[0]]).length, 1);
    },
  );
  test(
    'an explicit parent replaces the played display projection without duplicate cards',
    () {
      final parent = MediaItem({'Id': 's1', 'Type': 'Series', 'Name': '真实剧名'});
      final grouped = groupPlayed([
        episode('a', 's1', 1),
        parent,
        episode('b', 's1', 2),
      ]);
      expect(grouped.length, 1);
      expect(identical(grouped.single, parent), true);
    },
  );
  for (final gamma in ['bt.1886', 'gamma2.2', 'srgb']) {
    test(
      'actual $gamma SDR has an output notice independent of source branding',
      () {
        final label = mediaNotice(
          bluray: true,
          streams: const [],
          decoded: {'video-params/gamma': gamma},
        );
        expect(label, 'SDR · 标准动态范围 · 蓝光原盘');
        expect(label, isNot(contains('HDR10')));
      },
    );
  }
  for (final gamma in ['pq', 'hlg']) {
    test(
      'native $gamma and SDR fallback are distinguished without claiming native Dolby',
      () {
        final decoded = {
          'video-params/gamma': gamma,
          'dolby-vision-profile': '7',
        };
        expect(
          mediaNotice(
            bluray: false,
            streams: const [],
            decoded: decoded,
            nativeHdr: true,
          ),
          gamma == 'pq' ? 'HDR10 · 高动态范围' : 'HLG · 高动态范围',
        );
        final fallback = mediaNotice(
          bluray: false,
          streams: const [],
          decoded: decoded,
          nativeHdr: false,
        );
        expect(fallback, contains('SDR'));
        expect(fallback, isNot(contains('FEL')));
      },
    );
  }
  test(
    'shadow output policy follows actual target transfer and pinned renderer defaults',
    () {
      expect(shadowOutputTransfer('gpu', 'pq', 'bt.1886'), ShadowTransfer.pq);
      expect(shadowOutputTransfer('gpu', 'hlg', 'pq'), ShadowTransfer.hlg);
      expect(
        shadowOutputTransfer('gpu', 'auto', 'bt.1886'),
        ShadowTransfer.bt1886,
      );
      expect(shadowOutputTransfer('gpu', 'auto', 'pq'), ShadowTransfer.gamma22);
      expect(
        shadowOutputTransfer('gpu-next', 'auto', 'pq'),
        ShadowTransfer.bt1886,
      );
      expect(
        shadowOutputTransfer('gpu-next', 'srgb', 'pq'),
        ShadowTransfer.srgb,
      );
      expect(
        () => shadowOutputTransfer('null', 'auto', 'pq'),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => shadowOutputTransfer('gpu', 'auto', 'unknown'),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  test(
    'actual generated output shaders are exported for native GLSL and curve checks',
    () {
      final folder = Directory('build/start104/shaders')
        ..createSync(recursive: true);
      for (final transfer in ShadowTransfer.values) {
        for (final strength in [.25, .5, .75]) {
          final content = shadowShader(transfer, strength);
          expect(content, startsWith('//!HOOK OUTPUT\n'));
          expect(content, contains('return original;'));
          expect(content, contains('original.a'));
          File(
            '${folder.path}/${transfer.name}-${(strength * 100).round()}.hook',
          ).writeAsStringSync(content);
        }
      }
    },
  );
  test(
    'disabled shadow enhancement performs no property IO or file work',
    () async {
      final c = ShadowEnhancement();
      expect(
        await c.set(
          0,
          read: (_) async => throw StateError('Unexpected read'),
          write: (_, _) async => throw StateError('Unexpected write'),
          store: (_) async => throw StateError('Unexpected file'),
          active: () => true,
        ),
        0,
      );
    },
  );
  test(
    'shadow strength transactions preserve gamma, HDR, audio, subtitles and all original settings',
    () async {
      final c = ShadowEnhancement();
      final values = {
        'glsl-shaders': '',
        'current-vo': 'gpu',
        'options/target-trc': 'pq',
        'video-out-params/gamma': 'pq',
        'gamma': '0',
        'sid': '1',
        'aid': '2',
        'pause': 'no',
        'target-prim': 'bt.2020',
      };
      final original = Map.of(values);
      final writes = <String>[];
      Future<double> set(double v) => c.set(
        v,
        read: (k) async => values[k]!,
        write: (k, v) async {
          writes.add(k);
          values[k] = v;
        },
        store: (s) async => '/private/${s.hashCode}.hook',
        active: () => true,
      );
      expect(await set(.25), .25);
      expect(values['glsl-shaders'], isNotEmpty);
      expect(await set(.75), .75);
      expect(await set(0), 0);
      expect(values, original);
      expect(writes, everyElement('glsl-shaders'));
    },
  );
  test(
    'a rejected shadow write rolls back and retains the confirmed previous strength',
    () async {
      final c = ShadowEnhancement();
      var property = '';
      var refuse = false;
      var writes = 0;
      Future<double> set(double v) => c.set(
        v,
        read: (k) async => switch (k) {
          'glsl-shaders' => property,
          'current-vo' => 'gpu',
          'options/target-trc' => 'bt.1886',
          _ => 'bt.1886',
        },
        write: (k, v) async {
          writes++;
          if (refuse) {
            refuse = false;
            property = 'rejected';
          } else {
            property = v;
          }
        },
        store: (s) async => '/private/${s.hashCode}.hook',
        active: () => true,
      );
      await set(.25);
      final before = property;
      refuse = true;
      await expectLater(set(.75), throwsA(isA<AppFailure>()));
      expect(c.value, .25);
      expect(property, before);
      expect(writes, 3);
    },
  );
  test(
    'unconfirmed output, file failure, or a retired owner cannot install a shader',
    () async {
      for (final mode in ['unknown', 'file', 'retired', 'existing']) {
        final c = ShadowEnhancement();
        var active = true;
        var writes = 0;
        await expectLater(
          c.set(
            .5,
            read: (k) async => switch (k) {
              'glsl-shaders' => mode == 'existing' ? '/keep/original.hook' : '',
              'current-vo' => 'gpu',
              'options/target-trc' => mode == 'unknown' ? 'unknown' : 'bt.1886',
              _ => 'bt.1886',
            },
            write: (_, _) async {
              writes++;
            },
            store: (_) async {
              if (mode == 'file') throw const FileSystemException('synthetic');
              if (mode == 'retired') active = false;
              return '/private/shadow.hook';
            },
            active: () => active,
          ),
          throwsA(isA<Exception>()),
        );
        expect(writes, 0);
        expect(c.value, 0);
      }
    },
  );
  test(
    'atomic subtitle layout changes one property and preserves every unrelated option',
    () async {
      final values = {
        'yingyu-subtitle-layout': '-3',
        'sid': '1',
        'sub-visibility': 'yes',
        'sub-pos': '100',
        'gamma': '0',
        'target-trc': 'pq',
      };
      final writes = <String>[];
      Future<void> set(double? position) => writeMpvSubtitleLayout(
        scope: SubtitlePositionScope.discEmbedded,
        position: position,
        read: (k) async => values[k]!,
        write: (k, v) async {
          writes.add(k);
          values[k] = v;
        },
        active: () => true,
      );
      await set(35);
      expect(double.parse(values['yingyu-subtitle-layout']!), 65);
      await set(35);
      expect(writes.length, 1);
      await set(null);
      expect(double.parse(values['yingyu-subtitle-layout']!), -1);
      expect(writes, everyElement('yingyu-subtitle-layout'));
      expect(values['sid'], '1');
      expect(values['sub-visibility'], 'yes');
      expect(values['target-trc'], 'pq');
    },
  );
}
