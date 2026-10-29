import 'models.dart';

/// A row from the server's Resume response. This provenance is deliberately
/// typed, rather than a JSON flag: cached local viewing data cannot claim it.
/// Display consumers keep this checkpoint; playback still resolves durable
/// pending progress through AppStore when the user actually opens the media.
class ServerResumeItem extends MediaItem {
  ServerResumeItem(MediaItem item)
    : super({
        ...item.data,
        if (item.data['UserData'] is Map)
          'UserData': {...object(item.data['UserData'])},
      });
}
