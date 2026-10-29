namespace Yingyu.Update;

// Version belongs to the application that wrote the entry, including records
// kept across updates. Preserve the original message and native log fields.
public static class LogVersions
{
    public static string Annotate(string message, string version) => "appVersion=" + version + "; " + message;
}
