using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AstralParty.KoreanPatch;

internal sealed class UnsupportedPackSchemaException : Exception
{
    internal UnsupportedPackSchemaException(int schema) : base("Unsupported translation pack schemaVersion: " + schema) { }
}

internal sealed class PackPointer
{
    internal const int CompressedLimit = 32 * 1024 * 1024;
    private static readonly Regex PackPath = new("^packs/[0-9]+\\.json\\.gz$", RegexOptions.CultureInvariant);
    internal long Number { get; }
    internal string Path { get; }
    internal int Size { get; }
    internal string Sha256 { get; }

    private PackPointer(long number, string path, int size, string sha256)
    { Number = number; Path = path; Size = size; Sha256 = sha256; }

    internal static PackPointer Parse(byte[] bytes)
    {
        using var document = JsonDocument.Parse(bytes);
        var root = document.RootElement;
        TranslationPack.ValidateFormat(root);
        var number = root.GetProperty("number").GetInt64();
        var path = root.GetProperty("path").GetString() ?? "";
        var size = root.GetProperty("size").GetInt32();
        var sha = root.GetProperty("sha256").GetString() ?? "";
        if (number <= 0 || !PackPath.IsMatch(path) || path != "packs/" + number.ToString(CultureInfo.InvariantCulture) + ".json.gz")
            throw new InvalidDataException("Translation pack path/number mismatch");
        if (size <= 0 || size > CompressedLimit) throw new InvalidDataException("Translation pack size is invalid");
        if (sha.Length != 64) throw new InvalidDataException("Translation pack SHA-256 is invalid");
        foreach (var c in sha)
            if (!Uri.IsHexDigit(c)) throw new InvalidDataException("Translation pack SHA-256 is invalid");
        return new PackPointer(number, path, size, sha);
    }
}

internal sealed class TranslationPack
{
    private const int ExpandedLimit = 128 * 1024 * 1024;
    internal long Number { get; }
    internal string Version { get; }
    internal string Revision { get; }
    internal IReadOnlyDictionary<string, string> Lang { get; }
    internal IReadOnlyDictionary<string, Dictionary<uint, string>> Str { get; }

    private TranslationPack(long number, string version, string revision,
        Dictionary<string, string> lang, Dictionary<string, Dictionary<uint, string>> str)
    { Number = number; Version = version; Revision = revision; Lang = lang; Str = str; }

    internal static void ValidateFormat(JsonElement root)
    {
        var schema = root.GetProperty("schemaVersion").GetInt32();
        if (schema != 1) throw new UnsupportedPackSchemaException(schema);
        if (root.GetProperty("locale").GetString() != "ko") throw new InvalidDataException("Translation pack locale is not ko");
    }

    internal static TranslationPack Parse(PackPointer pointer, byte[] compressed)
    {
        if (compressed.Length != pointer.Size) throw new InvalidDataException("Translation pack size mismatch");
        if (!string.Equals(Convert.ToHexString(SHA256.HashData(compressed)), pointer.Sha256, StringComparison.OrdinalIgnoreCase))
            throw new InvalidDataException("Translation pack SHA-256 mismatch");
        using var input = new MemoryStream(compressed, writable: false);
        using var gzip = new GZipStream(input, CompressionMode.Decompress);
        using var expanded = new MemoryStream();
        var buffer = new byte[64 * 1024];
        int read;
        while ((read = gzip.Read(buffer, 0, buffer.Length)) != 0)
        {
            if (expanded.Length + read > ExpandedLimit) throw new InvalidDataException("Expanded translation pack exceeds size limit");
            expanded.Write(buffer, 0, read);
        }
        expanded.Position = 0;
        using var document = JsonDocument.Parse(expanded);
        var root = document.RootElement;
        ValidateFormat(root);
        var metadata = root.GetProperty("pack");
        if (metadata.GetProperty("number").GetInt64() != pointer.Number)
            throw new InvalidDataException("Translation pack number mismatch");
        var version = metadata.GetProperty("version").GetString() ?? "";
        var revision = metadata.GetProperty("revision").GetString() ?? "";
        _ = metadata.GetProperty("publishedAt").GetString();
        var lang = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var entry in root.GetProperty("lang").EnumerateObject())
            lang.Add(entry.Name, entry.Value.GetString() ?? throw new InvalidDataException("Null lang translation"));
        var str = new Dictionary<string, Dictionary<uint, string>>(StringComparer.Ordinal);
        foreach (var asset in root.GetProperty("str").EnumerateObject())
        {
            var entries = new Dictionary<uint, string>();
            foreach (var entry in asset.Value.EnumerateObject())
            {
                if (!uint.TryParse(entry.Name, NumberStyles.None, CultureInfo.InvariantCulture, out var id))
                    throw new InvalidDataException("Invalid STR translation id");
                entries.Add(id, entry.Value.GetString() ?? throw new InvalidDataException("Null STR translation"));
            }
            str.Add(asset.Name, entries);
        }
        return new TranslationPack(pointer.Number, version, revision, lang, str);
    }
}
