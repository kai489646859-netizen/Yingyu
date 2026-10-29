import 'package:media_kit/media_kit.dart' show VideoParams;
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/media_notice.dart';
import 'package:yingyu/playback/backend.dart' show MediaNoticeBackend;
class NoticeState {VideoParams videoParams=const VideoParams();}
class NoticePlayer {final state=NoticeState();}
class NoticeHdr {bool established=false,autoDolby=false;bool get dolbyEstablished=>established&&autoDolby;String get dolbyHdrLabel=>'杜比映射 HDR10';}
class NoticeProjection implements MediaNoticeBackend {
 final player=NoticePlayer();final _hdr=NoticeHdr();
 bool _noticeReady=true,_noticeBluray=false,_dolbyMapping=false;
 List<Json> _noticeStreams=[];Map<String,String> _noticeDecoded={};
 void snapshot({bool ready=true,bool bluray=false,bool mapped=false,bool hdr=false,List<Json> streams=const [],Map<String,String> decoded=const {}}){_noticeReady=ready;_noticeBluray=bluray;_dolbyMapping=mapped;_hdr.established=hdr;_hdr.autoDolby=hdr&&mapped;_noticeStreams=streams;_noticeDecoded=decoded;}
  @override
  String get sourceNotice => !_noticeReady
      ? ''
      : mediaNotice(
          bluray: _noticeBluray,
          streams: _noticeStreams,
          decoded: _noticeDecoded,
          nativeHdr: _hdr.established,
          dolbyMapped: _dolbyMapping,
        );
}
