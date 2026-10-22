using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace AstralParty.KoreanPatch;

internal static class LangPatcher
{
    internal static string Patch(string xml, IReadOnlyDictionary<string, string> translations)
    {
        using var reader = new XmlTextReader(new StringReader(xml))
            { Normalization = false, DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null };
        var document = XDocument.Load(reader, LoadOptions.PreserveWhitespace);
        var changed = false;
        foreach (var element in document.Descendants("string"))
        {
            var key = ((string?)element.Attribute("name"))?.Trim();
            if (key == null || !translations.TryGetValue(key, out var text)) continue;
            element.Value = text;
            changed = true;
        }
        if (!changed) return xml;
        var body = new StringBuilder(xml.Length);
        using (var writer = XmlWriter.Create(body, new XmlWriterSettings
            { OmitXmlDeclaration = true, Indent = false, NewLineHandling = NewLineHandling.None }))
            document.WriteTo(writer);
        return document.Declaration == null ? body.ToString() : document.Declaration + body.ToString();
    }
}

// Rewrite only the route's string field. Unlisted entries and unknown fields remain byte-exact.
internal static class StrPatcher
{
    internal static byte[] Patch(byte[] data, IReadOnlyDictionary<uint, string> translations, int targetField)
    {
        if (targetField != 2 && targetField != 3) throw new ArgumentOutOfRangeException(nameof(targetField));
        return RewriteContainer(data, 0, data.Length, translations, targetField, false) ?? data;
    }

    private static byte[]? RewriteContainer(byte[] data, int start, int end,
        IReadOnlyDictionary<uint, string> translations, int targetField, bool mirror)
    {
        MemoryStream? output = null;
        var copied = start;
        var offset = start;
        try
        {
            while (offset < end)
            {
                var fieldStart = offset;
                var tag = ReadVarint(data, ref offset, end);
                var tagEnd = offset;
                var field = checked((int)(tag >> 3));
                var wire = (int)(tag & 7);
                byte[]? rewritten = null;
                if (wire == 2 && (mirror ? field == 2 : field == 1 || field == 2))
                {
                    var length = ReadLength(data, ref offset, end);
                    var payloadEnd = offset + length;
                    rewritten = !mirror && field == 2 ?
                        RewriteContainer(data, offset, payloadEnd, translations, targetField, true) :
                        RewriteEntry(data, offset, payloadEnd, translations, targetField);
                    offset = payloadEnd;
                }
                else Skip(data, ref offset, end, tag);
                if (rewritten == null) continue;
                output ??= new MemoryStream(end - start);
                output.Write(data, copied, fieldStart - copied);
                output.Write(data, fieldStart, tagEnd - fieldStart);
                WriteVarint(output, (ulong)rewritten.Length);
                output.Write(rewritten);
                copied = offset;
            }
            if (output == null) return null;
            output.Write(data, copied, end - copied);
            return output.ToArray();
        }
        finally { output?.Dispose(); }
    }

    private static byte[]? RewriteEntry(byte[] data, int start, int end,
        IReadOnlyDictionary<uint, string> translations, int targetField)
    {
        uint id = 0; // proto3 omits id 0.
        var offset = start;
        while (offset < end)
        {
            var tag = ReadVarint(data, ref offset, end);
            if (tag == 13)
            {
                Require(offset, 4, end);
                id = (uint)(data[offset] | data[offset + 1] << 8 | data[offset + 2] << 16 | data[offset + 3] << 24);
            }
            Skip(data, ref offset, end, tag);
        }
        if (!translations.TryGetValue(id, out var text)) return null;
        var encoded = Encoding.UTF8.GetBytes(text);
        using var output = new MemoryStream(end - start + encoded.Length);
        var written = false;
        offset = start;
        while (offset < end)
        {
            var fieldStart = offset;
            var tag = ReadVarint(data, ref offset, end);
            var field = (int)(tag >> 3);
            Skip(data, ref offset, end, tag);
            if (field == targetField && (tag & 7) == 2)
            {
                if (!written) WriteString(output, targetField, encoded);
                written = true;
                continue;
            }
            if (!written && field > targetField)
            {
                WriteString(output, targetField, encoded);
                written = true;
            }
            output.Write(data, fieldStart, offset - fieldStart);
        }
        if (!written) WriteString(output, targetField, encoded);
        return output.ToArray();
    }

    private static void Require(int offset, int length, int end)
    {
        if (length < 0 || offset > end - length) throw new InvalidDataException("Truncated STR field");
    }

    private static int ReadLength(byte[] data, ref int offset, int end)
    {
        var length = checked((int)ReadVarint(data, ref offset, end));
        Require(offset, length, end);
        return length;
    }

    private static void Skip(byte[] data, ref int offset, int end, ulong tag)
    {
        if ((tag >> 3) == 0) throw new InvalidDataException("Invalid STR field number");
        switch (tag & 7)
        {
            case 0: ReadVarint(data, ref offset, end); break;
            case 1: Require(offset, 8, end); offset += 8; break;
            case 2: var length = ReadLength(data, ref offset, end); offset += length; break;
            case 3:
                while (true)
                {
                    var nested = ReadVarint(data, ref offset, end);
                    if ((nested & 7) == 4)
                    {
                        if ((nested >> 3) != (tag >> 3)) throw new InvalidDataException("Mismatched STR group");
                        break;
                    }
                    Skip(data, ref offset, end, nested);
                }
                break;
            case 5: Require(offset, 4, end); offset += 4; break;
            default: throw new InvalidDataException("Unsupported STR wire type");
        }
    }

    private static ulong ReadVarint(byte[] data, ref int offset, int end)
    {
        ulong value = 0;
        for (var shift = 0; shift < 64; shift += 7)
        {
            Require(offset, 1, end);
            var b = data[offset++];
            if (shift == 63 && b > 1) throw new InvalidDataException("STR varint overflow");
            value |= (ulong)(b & 0x7F) << shift;
            if ((b & 0x80) == 0) return value;
        }
        throw new InvalidDataException("STR varint too long");
    }

    private static void WriteVarint(Stream output, ulong value)
    {
        while (value >= 0x80) { output.WriteByte((byte)(value | 0x80)); value >>= 7; }
        output.WriteByte((byte)value);
    }

    private static void WriteString(Stream output, int field, byte[] value)
    {
        WriteVarint(output, (ulong)((field << 3) | 2));
        WriteVarint(output, (ulong)value.Length);
        output.Write(value);
    }
}
