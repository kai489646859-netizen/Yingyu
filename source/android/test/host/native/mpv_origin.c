// Generated from pinned MPV stream.c / stream.h (LGPL-2.1-or-later).
// Tests only; full source and license are in dependencies/native-sources.
#define STREAM_ORIGIN_DIRECT    (1 << 2) // passed from cmdline or loadfile
#define STREAM_ORIGIN_FS        (2 << 2) // referenced from playlist on unix FS
#define STREAM_ORIGIN_NET       (3 << 2) // referenced from playlist on network
#define STREAM_ORIGIN_UNSAFE    (4 << 2) // from a grotesque source
#define STREAM_ORIGIN_MASK      (7 << 2) // for extracting origin value from flags
static int check_origin(int src, int new)
{
    switch (src) {
    case STREAM_ORIGIN_DIRECT:
    case STREAM_ORIGIN_UNSAFE:
        // Allow anything, but constrain it to the new origin.
        return new;
    case STREAM_ORIGIN_FS:
        // From unix FS, allow all but unsafe.
        if (new == STREAM_ORIGIN_FS || new == STREAM_ORIGIN_NET)
            return new;
        break;
    case STREAM_ORIGIN_NET:
        // Allow only other network links.
        if (new == STREAM_ORIGIN_NET)
            return new;
        break;
    }
    return 0;
}
__declspec(dllexport) int yt_mpv_origin_from_playlist(int from_playlist) {
    return check_origin(from_playlist ? STREAM_ORIGIN_FS : STREAM_ORIGIN_DIRECT,
                        STREAM_ORIGIN_UNSAFE);
}
