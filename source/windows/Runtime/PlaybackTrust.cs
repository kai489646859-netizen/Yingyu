using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using Richasy.MpvKernel.Core;

namespace Yingyu.Update;

public static class PlaybackTrust
{
    static readonly Lazy<string> Bundle = new(CreateBundle);
    public static void Configure(MpvClient client)
    {
        // Native TLS libraries do not necessarily read the Windows certificate
        // store used by .NET media preflight. Export public, trusted roots only.
        string path = Bundle.Value;
        if (PlaybackTransport.Set(client, "tls-ca-file", path) < 0)
            throw new InvalidOperationException("无法配置播放器受信任证书来源。");
        if (PlaybackTransport.Set(client, "tls-verify", "yes") < 0)
            throw new InvalidOperationException("无法保留播放连接证书校验。");
        PlaybackTransport.Write("Info", "Playback.Trust", "原生网络读取使用 Windows 受信任根证书，保留 TLS 校验；不修改系统证书库。 ");
    }
    static string CreateBundle()
    {
        var excluded = new HashSet<string>();
        var roots = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var location in new[] { StoreLocation.LocalMachine, StoreLocation.CurrentUser })
        {
            using var denied = new X509Store(StoreName.Disallowed, location);
            try { denied.Open(OpenFlags.ReadOnly | OpenFlags.OpenExistingOnly); }
            catch (CryptographicException) { continue; }
            foreach (var certificate in denied.Certificates)
            {
                using (certificate) excluded.Add(Convert.ToHexStringLower(SHA256.HashData(certificate.RawData)));
            }
        }
        foreach (var location in new[] { StoreLocation.LocalMachine, StoreLocation.CurrentUser })
        {
            using var store = new X509Store(StoreName.Root, location);
            try { store.Open(OpenFlags.ReadOnly | OpenFlags.OpenExistingOnly); }
            catch (CryptographicException) { continue; }
            foreach (var certificate in store.Certificates)
            {
                using (certificate)
                {
                    string id = Convert.ToHexStringLower(SHA256.HashData(certificate.RawData));
                    if (!excluded.Contains(id) && certificate.NotAfter.ToUniversalTime() > DateTime.UtcNow
                        && certificate.NotBefore.ToUniversalTime() <= DateTime.UtcNow)
                        roots[id] = certificate.ExportCertificatePem();
                }
            }
        }
        if (roots.Count == 0) throw new InvalidOperationException("系统没有可用的受信任根证书。");
        string pem = string.Join("\n", roots.Values) + "\n";
        string digest = Convert.ToHexStringLower(SHA256.HashData(Encoding.ASCII.GetBytes(pem)));
        string directory = CachePaths.Certificates;
        Directory.CreateDirectory(directory);
        string path = Path.Combine(directory, "windows-roots-" + digest + ".pem");
        // Write atomically; another instance may be preparing the identical bundle.
        if (!File.Exists(path) || File.ReadAllText(path) != pem)
        {
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            File.WriteAllText(temporary, pem, Encoding.ASCII);
            File.Move(temporary, path, overwrite: true);
        }
        return path;
    }
}
