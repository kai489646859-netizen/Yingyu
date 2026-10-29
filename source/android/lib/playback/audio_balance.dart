import 'dart:async';
import 'dart:convert';
import '../core/models.dart';

enum AudioBalance {
  original('原始声音', '保留影片原有的声音强弱'),
  gentle('轻柔均衡', '适当缩小对白与大场面的音量差'),
  standard('标准均衡', '提高轻声对白，压低突出的响声'),
  night('夜间模式', '进一步缩小音量差，适合低音量观看');

  const AudioBalance(this.label, this.description);
  final String label, description;

  String get graph {
    final (threshold, ratio, makeup, release) = switch (this) {
      AudioBalance.original => ('1', '1', '1', '250'),
      AudioBalance.gentle => ('0.125', '2', '1.4', '300'),
      AudioBalance.standard => ('0.09', '3', '2', '350'),
      AudioBalance.night => ('0.063', '5', '2.4', '450'),
    };
    // Link all channels so compression does not move the surround image.
    // Lookahead limiter compensates its latency; no automatic output makeup.
    return 'acompressor=threshold=$threshold:ratio=$ratio:attack=8:'
        'release=$release:makeup=$makeup:knee=2.828:link=maximum:detection=rms,'
        'alimiter=limit=0.94:attack=5:release=80:level=false:latency=true';
  }
}

abstract class AudioBalanceBackend {
  AudioBalance get audioBalance;
  Future<AudioBalance> setAudioBalance(
    AudioBalance value, {
    required bool Function() allowed,
  });
}

const _label = '@yingyu_balance';
String audioBalanceEntry(AudioBalance value) =>
    '$_label:lavfi=graph=%${utf8.encode(value.graph).length}%${value.graph}';

/// Pinned MPV prints filter attributes with %BYTECOUNT% escaping. Preserve
/// unrelated entries byte for byte, including commas inside escaped values.
List<String> audioFilterEntries(String value) {
  if (value.isEmpty) return [];
  final bytes = utf8.encode(value);
  final result = <String>[];
  var start = 0, i = 0;
  while (i < bytes.length) {
    if (bytes[i] == 37) {
      final end = bytes.indexOf(37, i + 1);
      if (end < 0) throw const AppFailure('当前音频设置无法确认');
      final count = int.tryParse(utf8.decode(bytes.sublist(i + 1, end)));
      if (count == null || count < 0 || end + 1 + count > bytes.length) {
        throw const AppFailure('当前音频设置无法确认');
      }
      i = end + 1 + count;
      continue;
    }
    if (bytes[i] == 44) {
      result.add(utf8.decode(bytes.sublist(start, i)));
      start = i + 1;
    }
    i++;
  }
  result.add(utf8.decode(bytes.sublist(start)));
  if (result.any((entry) => entry.isEmpty)) {
    throw const AppFailure('当前音频设置无法确认');
  }
  return result;
}

class AudioBalanceControl {
  AudioBalance value = AudioBalance.original;
  Future<void> _tail = Future.value();

  Future<AudioBalance> set(
    AudioBalance next, {
    required Future<String> Function(String) read,
    required Future<void> Function(String, String) write,
    required bool Function() active,
    void Function(String)? event,
  }) {
    final job = _tail.then((_) => _set(next, read, write, active, event));
    _tail = job.then<void>((_) {}, onError: (Object _) {});
    return job;
  }

  Future<AudioBalance> _set(
    AudioBalance next,
    Future<String> Function(String) read,
    Future<void> Function(String, String) write,
    bool Function() active,
    void Function(String)? event,
  ) async {
    void check() {
      if (!active()) throw const AppFailure('播放会话已改变');
    }

    Future<String> get(String name) async {
      check();
      final result = await read(name);
      check();
      return result;
    }

    List<String> other(List<String> entries) =>
        entries.where((s) => !s.startsWith('$_label:')).toList();
    bool same(List<String> a, List<String> b) =>
        a.length == b.length &&
        List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
    bool matches(List<String> entries, AudioBalance mode) {
      final owned = entries.where((s) => s.startsWith('$_label:')).toList();
      return mode == AudioBalance.original
          ? owned.isEmpty
          : owned.length == 1 && owned.single == audioBalanceEntry(mode);
    }

    check();
    // The default path makes no native calls and never touches the audio chain.
    if (next == value) return value;
    event?.call('阶段=读取原设置');
    final before = audioFilterEntries(await get('af'));
    if (!matches(before, value)) {
      throw const AppFailure('音频滤镜已改变，请重新打开影片后调整');
    }
    if (next != AudioBalance.original) {
      event?.call('阶段=核对音频输出');
      final format = await get('audio-out-params/format');
      if (!const [
        'u8',
        's16',
        's32',
        's64',
        'float',
        'double',
        'u8p',
        's16p',
        's32p',
        's64p',
        'floatp',
        'doublep',
      ].contains(format)) {
        throw const AppFailure('当前音频尚未就绪或正在直通，暂不能均衡音量');
      }
    }
    try {
      // Retain every unrelated entry verbatim, especially scaletempo2. The
      // existing acknowledged async property setter has a bounded reply path.
      final desired = [
        ...other(before),
        if (next != AudioBalance.original) audioBalanceEntry(next),
      ];
      check();
      event?.call('阶段=应用滤镜；保留其他滤镜=${other(before).length}');
      await write('af', desired.join(','));
      check();
      event?.call('阶段=回读确认');
      final after = audioFilterEntries(await get('af'));
      if (!matches(after, next) || !same(other(before), other(after))) {
        throw const AppFailure('音量均衡未被确认');
      }
    } catch (_) {
      if (!active()) rethrow;
      event?.call('阶段=失败恢复');
      await write('af', before.join(','));
      if (!same(before, audioFilterEntries(await get('af')))) {
        throw const AppFailure('音量均衡失败，原音频设置未能恢复，请重新打开影片');
      }
      event?.call('阶段=已恢复原设置');
      rethrow;
    }
    value = next;
    return value;
  }
}
