using System.Globalization;

namespace Yingyu.Update;

internal enum HdrMedia { Unknown, Sdr, Hdr, Hdr10Plus, Hlg, DolbyVision }
internal enum HdrOutput { Sdr, Hdr10, Hdr10WithDynamicMetadata, ScRgb, SdrWithDynamicMetadata, SdrWithHighlightMapping }

internal static class HdrPlaybackPolicy
{
    // This renderer's RGB swap chain cannot preserve HLG directly. A disc
    // conversion may start at HDR10 by policy. Ordinary HLG can only descend.
    internal static bool CanRenderHdr(HdrMedia media, bool preferBase) =>
        media is HdrMedia.Hdr or HdrMedia.Hdr10Plus or HdrMedia.DolbyVision
        || media == HdrMedia.Hlg && preferBase;

    internal static HdrOutput Select(bool requested, HdrMedia media, HdrDisplay display,
        bool fallback, bool baseRejected = false, bool dynamicRejected = false,
        bool preferBase = false, bool scRgbAvailable = false, bool sceneMapperAvailable = true,
        bool manageSdrMapping = false, bool highlightMappingRejected = false)
    {
        bool mapScenes = (requested || manageSdrMapping) && media == HdrMedia.Hdr10Plus
            && sceneMapperAvailable && !dynamicRejected;
        bool mapHighlights = manageSdrMapping && !highlightMappingRejected && sceneMapperAvailable
            && media is HdrMedia.Hdr or HdrMedia.Hdr10Plus or HdrMedia.Hlg or HdrMedia.DolbyVision;
        var sdr = mapScenes ? HdrOutput.SdrWithDynamicMetadata
            : mapHighlights ? HdrOutput.SdrWithHighlightMapping : HdrOutput.Sdr;
        if (!requested || !CanRenderHdr(media,preferBase) || !display.HdrActive || fallback)
            return sdr;
        if (baseRejected) return scRgbAvailable ? HdrOutput.ScRgb : sdr;
        return mapScenes ? HdrOutput.Hdr10WithDynamicMetadata : HdrOutput.Hdr10;
    }

    internal static HdrMedia FromDecoder(string transfer, string matrix, string dvProfile, string sceneAverage)
    {
        if (matrix == "dolbyvision" || int.TryParse(dvProfile, out int profile) && profile is >= 1 and <= 10)
            return HdrMedia.DolbyVision;
        if (transfer is "pq" or "smpte2084")
            return double.TryParse(sceneAverage, NumberStyles.Float, CultureInfo.InvariantCulture, out var luma)
                && double.IsFinite(luma) && luma >= 0 ? HdrMedia.Hdr10Plus : HdrMedia.Hdr;
        if (transfer is "hlg" or "arib-std-b67") return HdrMedia.Hlg;
        return IsSdr(transfer) || transfer is "gamma1.8" or "gamma2.0" or "gamma2.6" or "gamma2.8" or "prophoto" or "st428"
            ? HdrMedia.Sdr : HdrMedia.Unknown;
    }

    internal static bool IsSdr(string transfer)
        => transfer is "srgb" or "bt.1886" or "bt.709" or "gamma2.2" or "gamma2.4";

    internal static bool IsSdr(HdrOutput output)
        => output is HdrOutput.Sdr or HdrOutput.SdrWithDynamicMetadata or HdrOutput.SdrWithHighlightMapping;

    internal static bool ConvertsToSdr(HdrOutput output)
        => output is HdrOutput.SdrWithDynamicMetadata or HdrOutput.SdrWithHighlightMapping;

    internal static bool MapsScenes(HdrOutput output)
        => output is HdrOutput.Hdr10WithDynamicMetadata or HdrOutput.SdrWithDynamicMetadata;

    internal static string TargetPeak(HdrOutput output, HdrDisplay display)
        => IsSdr(output) ? "203"
            : display is { HdrActive: true, PeakNits: int peak } && peak is >= 100 and <= 10000
                ? peak.ToString(CultureInfo.InvariantCulture) : "auto";

    internal static bool Confirms(HdrOutput output, string transfer, string primaries)
        => output switch
        {
            HdrOutput.Sdr or HdrOutput.SdrWithDynamicMetadata or HdrOutput.SdrWithHighlightMapping => IsSdr(transfer) && primaries == "bt.709",
            HdrOutput.ScRgb => transfer == "scrgb" && primaries == "bt.709",
            _ => (transfer is "pq" or "smpte2084") && primaries == "bt.2020",
        };

    internal static (string Key, string Value)[] Colors(HdrOutput output, bool sdrDisplay = true,
        bool dolby = false, HdrDisplay display = default)
    {
        bool hdr = !IsSdr(output);
        bool scRgb = output == HdrOutput.ScRgb;
        bool mapScenes = MapsScenes(output);
        return [
            ("target-prim", hdr && !scRgb ? "bt.2020" : "bt.709"),
            ("target-trc", scRgb ? "scrgb" : hdr ? "pq" : "srgb"),
            ("target-peak", TargetPeak(output,display)),
            ("target-colorspace-hint", "yes"),
            ("target-colorspace-hint-mode", "target"),
            // Apply the scene metadata while rendering to the display target.
            // Re-estimating the peak here would substitute measured scene data.
            ("tone-mapping", mapScenes ? "st2094-40"
                : output == HdrOutput.SdrWithHighlightMapping ? "bt.2446a" : "bt.2390"),
            ("hdr-compute-peak", mapScenes ? "no" : "yes"),
            ("hdr-contrast-recovery", "0.0"),
            // For Dolby conversion, compress out-of-gamut colours at constant
            // luminance without the perceptual mapper's optional hue shift.
            ("gamut-mapping-mode", dolby ? "desaturate" : "perceptual"),
            // Use the current display's ICC only on an ordinary SDR desktop.
            // Windows HDR/WCG already owns the display transform; applying an
            // ICC there would double-convert the verified PQ/BT.2020 target.
            ("icc-profile-auto", !hdr && sdrDisplay ? "yes" : "no"),
        ];
    }
    // Write file-local settings as a unit and verify what mpv actually kept.
    internal static bool TryApply(HdrOutput output, Func<string,string> read,
        Func<string,string,bool> write, Func<string,string,bool> matches,
        bool sdrDisplay = true, bool dolby = false, bool manageToneMapping = true, HdrDisplay display = default)
    {
        var previous = new List<(string Key, string Value)>();
        foreach (var (key, value) in Colors(output, sdrDisplay, dolby, display))
        {
            if (!manageToneMapping && key == "tone-mapping") continue;
            var before = read(key);
            if (matches(before, value)) continue;
            if (before.Length > 0)
            {
                previous.Add((key, before));
                if (write(key, value) && matches(read(key), value)) continue;
            }
            for (int i = previous.Count - 1; i >= 0; i--)
                write(previous[i].Key, previous[i].Value);
            return false;
        }
        return true;
    }
}
