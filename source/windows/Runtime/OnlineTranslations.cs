using System.Text.Json;
using EmbyDesktop.Core.Services;

namespace Yingyu.Update;

public static class OnlineTranslations
{
    public static OverviewTranslationMode Mode(OverviewTranslationMode _) => OverviewTranslationMode.OnlineFirst;
    public static async Task<OverviewTranslationResult?> ReadCached(object service, string text, string scope, CancellationToken token)
    {
        string path = (string)Access.Call(service, "CachePath", text, scope)!;
        try
        {
            var file = new FileInfo(path);
            if (!file.Exists || file.Length > 262144) return null;
            var value = JsonSerializer.Deserialize<OverviewTranslationResult>(await File.ReadAllTextAsync(path, token),
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });
            // Keep existing user files; never relabel an old offline result as online.
            if (value == null || value.IsOffline || value.Provider is not ("Google" or "Yandex")
                || !(bool)typeof(OverviewTranslationService).GetMethod("IsValidTranslation",
                    System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Public)!.Invoke(null, [text, value.Text])!) return null;
            return value with { Cached = true };
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or JsonException) { return null; }
    }
}
