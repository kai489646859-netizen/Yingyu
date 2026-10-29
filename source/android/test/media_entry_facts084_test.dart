import 'package:flutter_test/flutter_test.dart';
import 'package:yingyu/core/emby.dart';
import 'core_test.dart' show syntheticSession;

void main() {
  final account = syntheticSession('https://synthetic-host.invalid/emby');
  String facts(String address) => mediaEntryCheckFacts(
    address,
    account: account,
    sourceId: 'PRIVATE_SOURCE',
    playSessionId: 'PRIVATE_PLAY_SESSION',
  );

  test('entry diagnostics compare identities without emitting their values', () {
    final address =
        'https://PRIVATE_HOST.invalid/emby/Videos/PRIVATE_ITEM/stream.mkv'
        '?Static=true&MediaSourceId=PRIVATE_SOURCE&PlaySessionId=PRIVATE_PLAY_SESSION'
        '&DeviceId=${account.deviceId}&api_key=PRIVATE_TOKEN';
    final result = facts(address);
    expect(result, '形态=stream/mkv；Static=true；媒体源=一致；播放会话=一致；设备=一致');
    expect(result, isNot(contains('PRIVATE')));
    expect(result, isNot(contains(account.deviceId)));
  });

  test('duplicate identities and conflicting Static values remain visible', () {
    final result = facts(
      'https://synthetic.invalid/Videos/id/original'
      '?sTaTiC=true&Static=false&MediaSourceId=PRIVATE_SOURCE&mediasourceid=OTHER'
      '&PlaySessionId=OLD&DeviceId=${account.deviceId}&X-Emby-Device-Id=OTHER',
    );
    expect(result, '形态=original/无扩展；Static=非true或冲突；媒体源=不一致；播放会话=不一致；设备=不一致');
    expect(result, isNot(contains('OTHER')));
  });

  test('signed and custom addresses keep fixed missing labels', () {
    expect(
      facts('https://PRIVATE.invalid/PRIVATE_FILENAME?signature=PRIVATE_VALUE'),
      '形态=自定义/无扩展；Static=缺失；媒体源=缺失；播放会话=缺失；设备=缺失',
    );
    expect(
      facts('https://synthetic.invalid/Videos/id/stream.PRIVATEEXT'),
      startsWith('形态=stream/自定义扩展；'),
    );
    expect(
        facts('https://synthetic.invalid/stream?MediaSourceId=%FF'),
      '参数格式无法核对',
    );
  });
}
