import '../core/emby.dart';
import '../core/models.dart';
import '../core/background_work.dart';

typedef _MetadataResult = ({MediaItem? item, Object? error, StackTrace? stack});

/// One fresh detail request for an already accepted playback intent. This does
/// not prepare a playback URL, probe a source, open media or retain a cache.
class OpeningMetadata {
  OpeningMetadata.begin(this.api, this.id) : account = api.session {
    acceptIntent();
    _result = _fetch();
  }

  OpeningMetadata.prepare(this.api, this.id) : account = api.session {
    _optional = true;
    _result = _preparation.run(_fetch);
  }
  bool _optional = false;
  final _preparation = BackgroundWork();
  final EmbyClient api;
  final String id;
  final Session? account;
  final _clock = Stopwatch();
  final _age = Stopwatch();
  late Future<_MetadataResult> _result;
  bool _cancelled = false, _taken = false;
  bool refreshed = false;
  int requestMilliseconds = 0;
  int get elapsedMilliseconds => _clock.elapsedMilliseconds;
  int get readyAgeMilliseconds => _age.elapsedMilliseconds;
  bool get prepared => _prepared;
  bool _prepared = false;
  void acceptIntent() {
    if (!_clock.isRunning) _clock.start();
  }

  Future<_MetadataResult> _fetch() async {
    final watch = Stopwatch()..start();
    try {
      if (account == null || api.session != account) {
        throw const AppFailure('账户已切换，请重新打开影片');
      }
      return (
        item: await (_optional
            ? api.prepareEpisodeMetadata(id)
            : api.detail(id)),
        error: null,
        stack: null,
      );
    } catch (error, stack) {
      // The device/old episode can still be pending. Keep an unused failure
      // handled, and deliver it through the normal opening error path later.
      return (item: null, error: error, stack: stack);
    } finally {
      requestMilliseconds = watch.elapsedMilliseconds;
      _age
        ..reset()
        ..start();
    }
  }

  Future<MediaItem> take(EmbyClient owner, String target) async {
    void check() {
      if (_cancelled ||
          owner != api ||
          target != id ||
          api.session != account) {
        throw const AppFailure('播放资料请求已失效，请重新打开影片');
      }
    }

    check();
    if (_taken) throw const AppFailure('播放资料请求已经使用，请重新打开影片');
    _taken = true;
    acceptIntent();
    var result = await _result;
    check();
    // Preparation starts in the final five media seconds. Allow a bounded
    // thirty wall seconds for low playback rates, EOF/countdown and old-session
    // cleanup. Ordinary accepted opens keep their five-second freshness rule.
    // Newly arrived slow responses are fresh, regardless of HTTP duration.
    final optional = _optional;
    _prepared = optional;
    _optional = false;
    if ((optional && result.error != null) ||
        (result.error == null &&
            _age.elapsed > Duration(seconds: optional ? 30 : 5))) {
      refreshed = true;
      result = await _fetch();
      check();
    }
    if (result.error != null) {
      Error.throwWithStackTrace(result.error!, result.stack!);
    }
    final item = result.item!;
    if (item.id != id) throw const AppFailure('播放资料与所选资源不一致');
    return item;
  }

  void cancel() {
    _cancelled = true;
    _preparation.pause(this, true);
  }
}
