namespace Yingyu.Update;

/// <summary>
/// Separates the user-visible, disk-backed video cache from MPV's packet RAM.
/// They serve different purposes and must never share one multi-gigabyte cap.
/// </summary>
public static class PlaybackCachePolicy
{
    public const int DefaultDiskGB = 5;
    public const string PacketMemoryLimit = "512MiB";

    public static long DiskBytes(int gigabytes) =>
        gigabytes < 0 ? -1 : gigabytes * 1024L * 1024 * 1024;
}
