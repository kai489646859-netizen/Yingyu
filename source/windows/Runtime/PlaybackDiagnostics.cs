namespace Yingyu.Update;

public static class PlaybackDiagnostics
{
    // These messages describe demuxer probing, not a TLS handshake. Genuine
    // native errors, EndFile, HTTP status handling and startup timeout remain.
    public static bool HeaderSeekIsTls(string text, string pattern, StringComparison comparison) => false;
    public static bool SeekIsTls(string text, string pattern) => false;
}
