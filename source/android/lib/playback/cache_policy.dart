// Keep initial/seek packet buffering small. Once settled, the packet byte
// budget is the effective MPV limit. Disk read-ahead has its own byte limit.
const fastPacketCacheSeconds = 10;
const steadyPacketCacheSeconds = 3600000;
const defaultPlaybackCacheGB = 5;
const playbackReadAheadBytes = 5 * playbackGiB;
const playbackCacheBlockBytes = 256 * 1024;
const playbackCacheHeaderBytes = 32;

int playbackDiskQuota(int gigabytes) {
  if (gigabytes < 0) return -1;
  final bytes = gigabytes * playbackGiB;
  // A full forward window stores 5 GiB of video plus per-block digests.
  if (gigabytes != defaultPlaybackCacheGB) return bytes;
  return bytes + bytes ~/ playbackCacheBlockBytes * playbackCacheHeaderBytes;
}

/// CPU decoded pictures have a separate bound from compressed packet caching.
/// Keep the existing memory tiers; large pictures may allow only one frame.
int playbackCopyQueueBytes(int packetBytes) => packetBytes >= 128 * 1024 * 1024
    ? 160 * 1024 * 1024
    : packetBytes.clamp(16 * 1024 * 1024, 64 * 1024 * 1024);

const playbackCacheChoices = <int, String>{
  0: '不缓存',
  2: '2 GB',
  5: '5 GB',
  10: '10 GB',
  20: '20 GB',
  50: '50 GB',
  -1: '不限制',
};
const playbackGiB = 1024 * 1024 * 1024;
