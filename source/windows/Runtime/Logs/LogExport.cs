using System.IO;
using System.IO.Compression;
using System.Text;
using EmbyDesktop.Core.Services;

namespace Yingyu.LogCenter;

internal sealed record ExportResult(int Files, long Rows);

internal static class LogExport
{
    internal static async Task<ExportResult> WriteAsync(string destination, CancellationToken token)
    {
        destination = Path.GetFullPath(destination);
        if (!string.Equals(Path.GetExtension(destination), ".zip", StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("诊断日志应导出为压缩包");
        string folder = Path.GetDirectoryName(destination)!;
        string temporary = Path.Combine(folder, ".映屿日志导出-" + Guid.NewGuid().ToString("N") + ".tmp");
        int files = 0; long rows = 0;
        try
        {
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, FileOptions.Asynchronous))
            {
                using var zip = new ZipArchive(output, ZipArchiveMode.Create, true, Encoding.UTF8);
                // Fixed original rotation names only; do not enumerate account,
                // cache or configuration directories, and do not take the app lock.
                for (int i = 15; i >= 0; i--)
                {
                    token.ThrowIfCancellationRequested();
                    string name = i == 0 ? "映屿.log" : "映屿.log." + i;
                    string path = Path.Combine(LocalLogTail.DirectoryPath, name);
                    FileStream input;
                    try { input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 64 * 1024, FileOptions.Asynchronous | FileOptions.SequentialScan); }
                    catch (FileNotFoundException) { continue; }
                    catch (DirectoryNotFoundException) { continue; }
                    await using (input)
                    {
                        // Snapshot the original file length. Preserve the native
                        // timestamps, levels, areas, machine fields and stacks;
                        // retain the application's original export redactor.
                        long remaining = input.Length;
                        var decoder = Encoding.UTF8.GetDecoder();
                        var pending = new StringBuilder();
                        await using var writer = new StreamWriter(zip.CreateEntry(name, CompressionLevel.Fastest).Open(), new UTF8Encoding(false));
                        byte[] buffer = new byte[64 * 1024];
                        char[] characters = new char[Encoding.UTF8.GetMaxCharCount(buffer.Length)];
                        async Task Write(string line)
                        {
                            rows++;
                            string raw = SensitiveText.HideRaw(DiagnosticRedactor.Redact(line.TrimEnd('\r')));
                            await writer.WriteLineAsync(raw.AsMemory(), token).ConfigureAwait(false);
                        }
                        while (remaining > 0)
                        {
                            int count = await input.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)), token).ConfigureAwait(false);
                            if (count == 0) break;
                            remaining -= count;
                            int decoded = decoder.GetChars(buffer, 0, count, characters, 0, remaining == 0);
                            int start = 0;
                            for (int characterIndex = 0; characterIndex < decoded; characterIndex++)
                            {
                                if (characters[characterIndex] != '\n') continue;
                                pending.Append(characters, start, characterIndex - start);
                                await Write(pending.ToString()).ConfigureAwait(false);
                                pending.Clear(); start = characterIndex + 1;
                            }
                            pending.Append(characters, start, decoded - start);
                        }
                        if (pending.Length > 0) await Write(pending.ToString()).ConfigureAwait(false);
                        files++;
                    }
                }
                if (files == 0) throw new FileNotFoundException("没有可导出的本地日志");
                await using var info = new StreamWriter(zip.CreateEntry("诊断说明.txt", CompressionLevel.Fastest).Open(), new UTF8Encoding(false));
                await info.WriteLineAsync($"映屿原始日志：测试版 0.5.8\n导出时间：{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz}\n内容：{files}份本机原始格式日志，共{rows}行。\n完整读取最多十六份现有轮转文件，保留机器字段及调用栈，沿用软件原有敏感信息过滤；未转换为可视化摘要。\n每份文件按打开时长度导出，随后追加的记录可能在下次导出中出现。\n未读取账户配置或缓存，未请求服务器。\n操作请求与实际状态分别记录，未知值保留；日志线索不代表已完成实际功能验证。".AsMemory(), token).ConfigureAwait(false);
            }
            token.ThrowIfCancellationRequested();
            File.Move(temporary, destination, true);
            return new(files, rows);
        }
        finally
        {
            // Only remove the exact temporary file created by this export.
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }
}
