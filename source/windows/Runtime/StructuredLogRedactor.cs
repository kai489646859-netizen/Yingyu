using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Yingyu.Update;

// Runs before the original log redactor and on older exported/viewed logs.
// No logging or IO here: a redactor must never recurse into the log writer.
public static class StructuredLogRedactor
{
    static readonly HashSet<string> Sensitive = new(StringComparer.OrdinalIgnoreCase)
    {
        "accesstoken", "refreshtoken", "idtoken", "token", "apikey", "password", "pw",
        "authorization", "proxyauthorization", "cookie", "setcookie", "xembytoken",
        "xmediabrowsertoken", "clientsecret", "secret", "username"
    };
    static readonly Regex Plain = new(
        @"(?:^|[^\w-])(?<key>access[_-]?token|refresh[_-]?token|id[_-]?token|token|api[_-]?key|password|pw|authorization|proxy-authorization|cookie|set-cookie|x-emby-token|x-mediabrowser-token|client[_-]?secret|secret|username)\s*[:=：][ \t]*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant | RegexOptions.NonBacktracking,
        TimeSpan.FromMilliseconds(100));
    const string Hidden = "[敏感信息已隐藏]";

    public static string Redact(string text)
    {
        if (string.IsNullOrEmpty(text)) return text;
        if (text.Length > 1024 * 1024) return "超长诊断内容已隐藏。";
        var output = new StringBuilder(); int copied = 0;
        for (int i = 0; i < text.Length;)
        {
            if (text[i] is not ('"' or '\'')) { i++; continue; }
            int end = QuotedEnd(text, i);
            if (end < 0) break;
            string key = "";
            if (end - i <= 256)
            {
                try { key = text[i] == '"' ? JsonSerializer.Deserialize<string>(text[i..end]) ?? "" : text[(i + 1)..(end - 1)]; }
                catch (JsonException) { }
            }
            int separator = end;
            while (separator < text.Length && char.IsWhiteSpace(text[separator])) separator++;
            if (!Sensitive.Contains(key.Replace("_", "").Replace("-", ""))
                || separator >= text.Length || text[separator] is not (':' or '=')) { i = end; continue; }
            int start = separator + 1;
            while (start < text.Length && char.IsWhiteSpace(text[start])) start++;
            int finish = ValueEnd(text, start);
            output.Append(text, copied, start - copied).Append('"').Append(Hidden).Append('"');
            copied = finish; i = finish;
        }
        string masked = copied == 0 ? text : output.Append(text, copied, text.Length - copied).ToString();
        try
        {
            output.Clear(); copied = 0;
            foreach (Match match in Plain.Matches(masked))
            {
                if (match.Index < copied) continue;
                int start = match.Index + match.Length, finish = ValueEnd(masked, start);
                string key = match.Groups["key"].Value;
                if (start < masked.Length && masked[start] is not ('"' or '\'' or '{' or '[')
                    && (key.Equals("Cookie", StringComparison.OrdinalIgnoreCase) || key.Equals("Set-Cookie", StringComparison.OrdinalIgnoreCase)))
                {
                    // Semicolons and commas are cookie data, not safe boundaries.
                    finish = start;
                    while (finish < masked.Length && masked[finish] is not ('\r' or '\n')) finish++;
                }
                output.Append(masked, copied, start - copied).Append('"').Append(Hidden).Append('"');
                copied = finish;
            }
            return copied == 0 ? masked : output.Append(masked, copied, masked.Length - copied).ToString();
        }
        catch (RegexMatchTimeoutException) { return "敏感信息过滤超时，内容已隐藏。"; }
    }

    // Returns the first index after the closing quote; escaped quotes/backslashes
    // remain within the value. Unterminated sensitive values are hidden to EOF.
    static int QuotedEnd(string text, int start)
    {
        char quote = text[start];
        for (int i = start + 1; i < text.Length; i++)
        {
            if (text[i] == '\\') { i++; continue; }
            if (text[i] == quote) return i + 1;
        }
        return -1;
    }
    static int ValueEnd(string text, int start)
    {
        if (start >= text.Length) return text.Length;
        if (text[start] is '"' or '\'') return QuotedEnd(text, start) is int end && end >= 0 ? end : text.Length;
        if (text[start] is '{' or '[')
        {
            int depth = 0;
            for (int i = start; i < text.Length; i++)
            {
                if (text[i] is '"' or '\'') { int end = QuotedEnd(text, i); if (end < 0) return text.Length; i = end - 1; }
                else if (text[i] is '{' or '[') depth++;
                else if (text[i] is '}' or ']') { if (--depth == 0) return i + 1; }
            }
            return text.Length;
        }
        int finish = start;
        while (finish < text.Length && text[finish] is not (',' or '}' or ']' or '\r' or '\n' or ';' or '；')) finish++;
        return finish;
    }
}
