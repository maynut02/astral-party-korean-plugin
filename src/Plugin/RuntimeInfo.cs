using System;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AstralParty.KoreanPatch;

internal sealed record GameRoute(string Name, string LangAsset, int StrField)
{
    internal static GameRoute? Detect(string processName, string dataPath)
    {
        var process = Path.GetFileNameWithoutExtension(processName);
        var route = FromName(process);
        if (route != null) return route;
        var directory = Path.GetFileName(dataPath.TrimEnd('/', '\\'));
        if (directory.EndsWith("_Data", StringComparison.OrdinalIgnoreCase))
            directory = directory.Substring(0, directory.Length - 5);
        return FromName(directory);
    }

    private static GameRoute? FromName(string name)
    {
        if (name.Equals("AstralParty_INT", StringComparison.OrdinalIgnoreCase)) return new("INT", "English", 3);
        if (name.Equals("AstralParty_CN", StringComparison.OrdinalIgnoreCase)) return new("CN", "Simplified Chinese", 2);
        return null;
    }
}

// Unity-free interpretation of App.WebServerConfig's hot-update JSON.
internal sealed record GameInfo(string Version, string Revision, string Route)
{
    internal static bool TryParse(string? json, out GameInfo? info)
    {
        info = null;
        if (string.IsNullOrWhiteSpace(json)) return false;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return false;
            var version = Text(root, "version");
            var route = Text(root, "route");
            var source = Text(root, "sourceUrl");
            if (version.Length == 0 && route.Length == 0 && source.Length == 0) return false;
            info = new GameInfo(version, RevisionFromSourceUrl(source, route, version), route);
            return true;
        }
        catch (JsonException) { return false; }
    }

    private static string Text(JsonElement root, string name) =>
        root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? (value.GetString() ?? "").Trim() : "";

    private static string RevisionFromSourceUrl(string source, string route, string version)
    {
        if (!Uri.TryCreate(source, UriKind.Absolute, out var uri)
            || (uri.Scheme != Uri.UriSchemeHttp && uri.Scheme != Uri.UriSchemeHttps)
            || uri.Host.Length == 0) return "-";
        // Use the original path: Uri.AbsolutePath normalizes '.' and '..',
        // which must not turn a malformed source URL into a valid revision.
        var schemeEnd = source.IndexOf("://", StringComparison.Ordinal);
        if (schemeEnd < 0) return "-";
        var pathStart = source.IndexOf('/', schemeEnd + 3);
        var authorityEnd = source.AsSpan(schemeEnd + 3).IndexOfAny('?', '#');
        if (pathStart < 0 || (authorityEnd >= 0 && pathStart >= schemeEnd + 3 + authorityEnd)) return "-";
        var path = source.AsSpan(pathStart + 1);
        var suffix = path.IndexOfAny('?', '#');
        if (suffix >= 0) path = path.Slice(0, suffix);
        if (path.EndsWith("/".AsSpan(), StringComparison.Ordinal)) path = path.Slice(0, path.Length - 1);
        var parts = path.ToString().Split('/');
        foreach (var part in parts)
            if (part.Length == 0 || part == "." || part == "..") return "-";
        string revision;
        var routeIndex = route.Length == 0 ? -1 : Array.IndexOf(parts, route);
        if (routeIndex >= 0)
        {
            var remaining = parts.Length - routeIndex;
            // Match the builder's fixed route/version/revision[/suffix] tail.
            // A JSON/URL version mismatch is not a trustworthy game revision.
            if (remaining is not (3 or 4) || parts[routeIndex + 1] != version) return "-";
            revision = parts[routeIndex + 2];
        }
        else if (parts.Length == 1 || (parts.Length == 2 && parts[0] == "game"))
            revision = parts[parts.Length - 1];
        else return "-";
        foreach (var digit in revision)
            if (digit < '0' || digit > '9') return "-";
        return revision;
    }
}

internal sealed class SemanticVersion : IComparable<SemanticVersion>
{
    private static readonly Regex Format = new("^v?(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*))?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$", RegexOptions.CultureInvariant);
    private readonly string[] core;
    private readonly string[] pre;
    internal string Text { get; }
    internal bool IsPrerelease => pre.Length != 0;
    private SemanticVersion(string text, string[] core, string[] pre) { Text = text; this.core = core; this.pre = pre; }

    internal static SemanticVersion Parse(string value)
    {
        var match = Format.Match(value);
        if (!match.Success) throw new FormatException("Invalid SemVer: " + value);
        var pre = match.Groups[4].Success ? match.Groups[4].Value.Split('.') : Array.Empty<string>();
        foreach (var part in pre)
            if (Numeric(part) && part.Length > 1 && part[0] == '0') throw new FormatException("Invalid numeric prerelease identifier");
        return new SemanticVersion(value.StartsWith("v", StringComparison.Ordinal) ? value.Substring(1) : value,
            new[] { match.Groups[1].Value, match.Groups[2].Value, match.Groups[3].Value }, pre);
    }

    private static bool Numeric(string value)
    {
        foreach (var c in value) if (c < '0' || c > '9') return false;
        return true;
    }

    private static int CompareNumber(string left, string right) => left.Length != right.Length ?
        left.Length.CompareTo(right.Length) : string.CompareOrdinal(left, right);

    public int CompareTo(SemanticVersion? other)
    {
        if (other == null) return 1;
        for (var i = 0; i < core.Length; i++)
        {
            var comparison = CompareNumber(core[i], other.core[i]);
            if (comparison != 0) return comparison;
        }
        if (pre.Length == 0 || other.pre.Length == 0)
            return pre.Length == other.pre.Length ? 0 : pre.Length == 0 ? 1 : -1;
        for (var i = 0; i < Math.Min(pre.Length, other.pre.Length); i++)
        {
            var leftNumber = Numeric(pre[i]);
            var rightNumber = Numeric(other.pre[i]);
            var comparison = leftNumber && rightNumber ? CompareNumber(pre[i], other.pre[i]) :
                leftNumber != rightNumber ? (leftNumber ? -1 : 1) : string.CompareOrdinal(pre[i], other.pre[i]);
            if (comparison != 0) return comparison;
        }
        return pre.Length.CompareTo(other.pre.Length);
    }
}
