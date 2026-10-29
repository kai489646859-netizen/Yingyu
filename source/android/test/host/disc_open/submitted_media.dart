// Generated exact Media expression from backend.dart; no backend constructor runs.
// ignore_for_file: non_constant_identifier_names, unnecessary_non_null_assertion, no_leading_underscores_for_local_identifiers
import 'package:media_kit/media_kit.dart';
import 'package:yingyu/core/models.dart';
import 'package:yingyu/playback/disc_transport.dart';
Media submittedMedia(String address, DiscTransport? _disc, PlaybackRoute route, Duration start) =>
Media(
            address,
            httpHeaders: _disc == null ? route.headers : const {},
            start: start,
            extras: _disc != null && _disc!.base == 'yingyu-disc://${_disc!.id}'
                ? {'yingyuNativeDiscSession': _disc!.id}
                : const {},
          );
