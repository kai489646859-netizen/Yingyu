import 'recovery101_old_output.dart';
class RealOutputFixture {
  final output = NativeHdrOutput();
  final options = <String, String>{
    'gpu-context': 'android',
    'target-prim': 'bt.709',
    'target-trc': 'bt.1886',
    'target-peak': 'auto',
    'tone-mapping': 'bt.2390',
    'dither': 'fruit',
    'dither-depth': '8',
    'panscan': '0',
    'vid': 'auto',
  };
  final writes = <(String, String)>[];
  bool selected = true, loseVideo = true, refuseVideo = false;
  bool hdrAvailable = false, noRestoredFrame = false, rejected = false;
  String requestedVo = 'gpu', actualVo = 'gpu', wid = '900';
  Future<String> read(String key) async {
    if (key == 'options/vo') return requestedVo;
    if (key == 'options/wid') return wid;
    if (key == 'vid') return selected ? '1' : 'no';
    if (key == 'current-vo') return actualVo;
    if (key == 'vo-configured') return actualVo == 'gpu' ? 'yes' : 'no';
    if (key == 'video-frame-info/interlaced') {
      return actualVo == 'gpu' && !(rejected && noRestoredFrame) ? 'no' : '';
    }
    return options[key.replaceFirst('options/', '')] ?? '';
  }

  Future<void> write(String key, String value) async {
    writes.add((key, value));
    if (key == 'vo') {
      requestedVo = value;
      if (value == 'gpu' &&
          options['gpu-context']!.startsWith('android-hdr') &&
          !hdrAvailable) {
        rejected = true;
        if (loseVideo) selected = false;
        actualVo = '';
      } else {
        actualVo = selected ? value : '';
      }
    } else if (key == 'wid') {
      wid = value;
    } else if (key == 'vid') {
      if (!refuseVideo) {
        selected = value == '1' || value == 'auto';
        actualVo = selected ? requestedVo : '';
      }
    } else if (options.containsKey(key)) {
      options[key] = value;
    }
  }

  Future<bool> apply({int token = 7, int texture = 900}) => output.apply(
    surface: token,
    width: 3840,
    height: 2512,
    transfer: 'pq',
    fill: false,
    textureSurface: texture,
    textureWidth: 3840,
    textureHeight: 2512,
    originalOutput: 'gpu',
    read: read,
    write: write,
  );
}

