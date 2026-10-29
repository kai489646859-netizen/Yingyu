/// Application pacing choices, not an Emby server rate-limit specification.
enum ImageLoadSpeed {
  slow('慢速', '2 秒', Duration(seconds: 2)),
  balanced('均衡', '1 秒', Duration(seconds: 1)),
  fast('快速', '0.4 秒', Duration(milliseconds: 400));

  const ImageLoadSpeed(this.label, this.intervalLabel, this.interval);
  final String label, intervalLabel;
  final Duration interval;
}
