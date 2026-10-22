// Builds the plugin-owned Korean font AssetBundle without the Unity Editor.
//
// Output bundle (Unity 2022.3, UnityFS/LZ4) contains only native object types, so it never
// depends on game MonoScripts or Addressables bundles:
//   Font       "AstralKorean ONE Mobile POP"  dynamic legacy font (+ Font Material, Font Texture)
//   Texture2D  "AstralKorean TMP Atlas"       Alpha8 SDF atlas for the TMP glyph table
//   TextAsset  "AstralKorean TMP Data"        JSON face info, glyph and character tables
//
// Type trees come from the game's own TMP bundle (AssetBundle, Material, Texture2D) and from
// classdata.tpk (Font, TextAsset). Font/Material/Font Texture values are cloned from the game's
// original Afacad-Regular objects in the game's read-only source bundle; only the font data changes.

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AssetsTools.NET;
using AssetsTools.NET.Extra;

internal static class Program
{
    private const string BundleName = "astralkorean_fonts";
    private const string FontName = "AstralKorean ONE Mobile POP";
    private const string AtlasName = "AstralKorean TMP Atlas";
    private const string TmpDataName = "AstralKorean TMP Data";
    private const string TemplateFontName = "Afacad-Regular";
    private const long AssetBundlePathId = 1;
    private const long FontPathId = 2;
    private const long FontMaterialPathId = 3;
    private const long FontTexturePathId = 4;
    private const long AtlasPathId = 5;
    private const long TmpDataPathId = 6;

    private static int Main(string[] args)
    {
        try
        {
            var options = Options.Parse(args);
            Build(options);
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine($"error: {error}");
            return 1;
        }
    }

    private static void Build(Options options)
    {
        var manager = new AssetsManager();
        manager.LoadClassPackage(options.ClassData);

        var templateBundle = manager.LoadBundleFile(options.TemplateBundle, unpackIfPacked: true);
        var serializedIndex = Enumerable.Range(0, templateBundle.file.BlockAndDirInfo.DirectoryInfos.Count)
            .Single(templateBundle.file.IsAssetsFile);
        var target = manager.LoadAssetsFileFromBundle(templateBundle, serializedIndex);
        var file = target.file;
        var unityVersion = file.Metadata.UnityVersion;
        var classDatabase = manager.LoadClassDatabaseFromPackage(unityVersion)
            ?? throw new InvalidDataException($"classdata has no database for {unityVersion}");

        foreach (var type in new[] { AssetClassID.AssetBundle, AssetClassID.Material, AssetClassID.Texture2D })
        {
            var gameHash = file.Metadata.FindTypeTreeTypeByID((int)type)!.TypeHash;
            var classHash = ConvertClassDatabaseType(classDatabase, type).TypeHash;
            Console.WriteLine($"classdata {type}: {(classHash.data.SequenceEqual(gameHash.data) ? "matches" : "differs from")} game layout");
        }
        // Parse the Korean TMP_FontAsset payload with the game's own MonoBehaviour type tree.
        var tmpInfo = file.GetAssetsOfType(AssetClassID.MonoBehaviour)
            .Single(info => manager.GetBaseField(target, info)["m_Name"].AsString.EndsWith("_TMP", StringComparison.Ordinal));
        var tmpTemplate = manager.GetTemplateBaseField(target, tmpInfo);
        var tmpPayload = File.ReadAllBytes(options.TmpData);
        AssetTypeValueField tmp;
        using (var reader = new AssetsFileReader(new MemoryStream(tmpPayload)))
        {
            tmp = tmpTemplate.MakeValue(reader);
            if (reader.Position != tmpPayload.Length)
                throw new InvalidDataException($"TMP payload has {tmpPayload.Length - reader.Position} trailing bytes");
        }
        var atlasWidth = tmp["m_AtlasWidth"].AsInt;
        var atlasHeight = tmp["m_AtlasHeight"].AsInt;
        var atlasPixels = Png.ReadAlpha8BottomUp(options.TmpAtlas, atlasWidth, atlasHeight);
        var tmpJson = TmpJson(tmp);

        var templateAtlasInfo = file.GetAssetsOfType(AssetClassID.Texture2D).Single();
        var atlas = manager.GetBaseField(target, templateAtlasInfo);
        var assetBundle = manager.GetBaseField(target, file.GetAssetsOfType(AssetClassID.AssetBundle).Single());

        // Source values for the legacy Font from the game's data.unity3d (no type trees: cldb).
        var unityData = manager.LoadBundleFile(options.UnityData, unpackIfPacked: true);
        var resources = manager.LoadAssetsFileFromBundle(unityData, "resources.assets");
        var resourcesFile = resources.file;
        var sourceFontInfo = resourcesFile.GetAssetsOfType(AssetClassID.Font)
            .Single(info => manager.GetBaseField(resources, info)["m_Name"].AsString == TemplateFontName);
        var font = manager.GetBaseField(resources, sourceFontInfo);
        var sourceMaterial = manager.GetExtAsset(resources, font["m_DefaultMaterial"]).baseField;
        var sourceFontTexture = manager.GetExtAsset(resources, font["m_Texture"]).baseField;
        var shaderPointer = sourceMaterial["m_Shader"];
        var shaderExternal = resourcesFile.Metadata.Externals[shaderPointer["m_FileID"].AsInt - 1];
        if (!shaderExternal.PathName.EndsWith("unity default resources", StringComparison.Ordinal) &&
            !shaderExternal.PathName.EndsWith("unity_builtin_extra", StringComparison.Ordinal))
            throw new InvalidDataException($"unexpected font shader location {shaderExternal.PathName}");

        // Rebuild the serialized file: keep only template type trees we reuse, drop every object.
        var keptTypes = new HashSet<int> { (int)AssetClassID.AssetBundle, (int)AssetClassID.Material, (int)AssetClassID.Texture2D };
        file.Metadata.TypeTreeTypes = file.Metadata.TypeTreeTypes.Where(type => keptTypes.Contains(type.TypeId) && type.ScriptTypeIndex == ushort.MaxValue).ToList();
        file.Metadata.ScriptTypes.Clear();
        file.Metadata.RefTypes.Clear();
        file.Metadata.Externals = new List<AssetsFileExternal> { shaderExternal };
        file.Metadata.AssetInfos = new List<AssetFileInfo>();

        // Font: clone of Afacad-Regular with ONE Mobile POP data.
        var fontBytes = File.ReadAllBytes(options.Ttf);
        font["m_Name"].AsString = FontName;
        SetByteVector(font["m_FontData"], fontBytes);
        SetPointer(font["m_DefaultMaterial"], 0, FontMaterialPathId);
        SetPointer(font["m_Texture"], 0, FontTexturePathId);
        AddAsset(file, FontPathId, AssetClassID.Font, classDatabase, font, resourcesFile);

        // Font Material and Font Texture: same values as the game's, re-pointed to this bundle.
        var material = NewValue(file, AssetClassID.Material);
        CopyByName(sourceMaterial, material);
        SetPointer(material["m_Shader"], 1, shaderPointer["m_PathID"].AsLong);
        foreach (var texEnv in material["m_SavedProperties"]["m_TexEnvs"]["Array"].Children)
        {
            if (texEnv["first"].AsString == "_MainTex") SetPointer(texEnv["second"]["m_Texture"], 0, FontTexturePathId);
        }
        AddAsset(file, FontMaterialPathId, AssetClassID.Material, classDatabase, material);

        var fontTexture = NewValue(file, AssetClassID.Texture2D);
        CopyByName(sourceFontTexture, fontTexture);
        AddAsset(file, FontTexturePathId, AssetClassID.Texture2D, classDatabase, fontTexture);

        // TMP atlas: template atlas settings, Korean pixels stored inline (no .resS).
        atlas["m_Name"].AsString = AtlasName;
        atlas["m_Width"].AsInt = atlasWidth;
        atlas["m_Height"].AsInt = atlasHeight;
        atlas["m_CompleteImageSize"].AsUInt = (uint)atlasPixels.Length;
        atlas["m_TextureFormat"].AsInt = 1; // Alpha8
        atlas["m_MipCount"].AsInt = 1;
        atlas["m_ImageCount"].AsInt = 1;
        atlas["m_IsReadable"].AsBool = false;
        SetByteVector(atlas["image data"], atlasPixels);
        atlas["m_StreamData"]["offset"].AsULong = 0;
        atlas["m_StreamData"]["size"].AsUInt = 0;
        atlas["m_StreamData"]["path"].AsString = string.Empty;
        AddAsset(file, AtlasPathId, AssetClassID.Texture2D, classDatabase, atlas);

        var tmpData = NewValue(file, AssetClassID.TextAsset, classDatabase, resourcesFile);
        tmpData["m_Name"].AsString = TmpDataName;
        tmpData["m_Script"].AsString = tmpJson;
        AddAsset(file, TmpDataPathId, AssetClassID.TextAsset, classDatabase, tmpData, resourcesFile);

        // AssetBundle object: one container entry per loadable asset.
        assetBundle["m_Name"].AsString = BundleName;
        assetBundle["m_AssetBundleName"].AsString = BundleName;
        assetBundle["m_Dependencies"]["Array"].Children.Clear();
        assetBundle["m_IsStreamedSceneAssetBundle"].AsBool = false;
        assetBundle["m_ExplicitDataLayout"].AsInt = 0;
        assetBundle["m_PathFlags"].AsInt = 7;
        var preload = assetBundle["m_PreloadTable"]["Array"];
        preload.Children.Clear();
        var container = assetBundle["m_Container"]["Array"];
        container.Children.Clear();
        AddContainer(preload, container, "assets/astralkorean/onemobilepop.ttf", FontPathId, FontMaterialPathId, FontTexturePathId);
        AddContainer(preload, container, "assets/astralkorean/tmp-atlas.asset", AtlasPathId);
        AddContainer(preload, container, "assets/astralkorean/tmp-data.json", TmpDataPathId);
        SetPointer(assetBundle["m_MainAsset"]["asset"], 0, 0);
        AddAsset(file, AssetBundlePathId, AssetClassID.AssetBundle, classDatabase, assetBundle);

        // Bundle: one uniquely named serialized file, LZ4 blocks.
        var cabName = "CAB-" + Convert.ToHexString(MD5.HashData(Encoding.UTF8.GetBytes(BundleName))).ToLowerInvariant();
        var directories = templateBundle.file.BlockAndDirInfo.DirectoryInfos;
        for (var index = 0; index < directories.Count; index++)
        {
            if (index == serializedIndex)
            {
                directories[index].Name = cabName;
                directories[index].SetNewData(file);
            }
            else
            {
                directories[index].SetRemoved();
            }
        }

        var unpacked = new MemoryStream();
        using (var writer = new AssetsFileWriter(unpacked))
        {
            templateBundle.file.Write(writer);
        }
        var repacked = new AssetBundleFile();
        repacked.Read(new AssetsFileReader(new MemoryStream(unpacked.ToArray())));
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(options.Output))!);
        var temporary = options.Output + ".tmp";
        using (var output = File.Create(temporary))
        using (var writer = new AssetsFileWriter(output))
        {
            repacked.Pack(writer, AssetBundleCompressionType.LZ4);
        }
        File.Move(temporary, options.Output, overwrite: true);
        if (options.TmpJsonOutput != null) File.WriteAllText(options.TmpJsonOutput, tmpJson, new UTF8Encoding(false));

        Console.WriteLine($"unity={unityVersion} cab={cabName} font={fontBytes.Length}B atlas={atlasWidth}x{atlasHeight} " +
            $"glyphs={tmp["m_GlyphTable"]["Array"].Children.Count} characters={tmp["m_CharacterTable"]["Array"].Children.Count} " +
            $"bundle={new FileInfo(options.Output).Length}B -> {options.Output}");
    }

    private static AssetTypeValueField NewValue(AssetsFile file, AssetClassID type, ClassDatabaseFile? classDatabase = null, AssetsFile? hashSource = null)
    {
        var typeTree = EnsureType(file, type, classDatabase, hashSource);
        var template = new AssetTypeTemplateField();
        template.FromTypeTree(typeTree);
        return ValueBuilder.DefaultValueFieldFromTemplate(template);
    }

    private static TypeTreeType EnsureType(AssetsFile file, AssetClassID type, ClassDatabaseFile? classDatabase, AssetsFile? hashSource)
    {
        var existing = file.Metadata.FindTypeTreeTypeByID((int)type);
        if (existing != null) return existing;
        if (classDatabase == null) throw new InvalidDataException($"template bundle lacks a {type} type tree");
        var converted = ConvertClassDatabaseType(classDatabase, type);
        // Unity's type hash is the MD4 of the type tree. Matching the game's own hash proves the
        // classdata layout is the exact runtime layout, and lets Unity skip a conversion pass.
        var gameType = hashSource?.Metadata.FindTypeTreeTypeByID((int)type)
            ?? throw new InvalidDataException($"game data lacks a {type} type hash");
        if (!converted.TypeHash.data.SequenceEqual(gameType.TypeHash.data))
            throw new InvalidDataException($"classdata {type} layout hash {converted.TypeHash} differs from game {gameType.TypeHash}");
        file.Metadata.TypeTreeTypes.Add(converted);
        return converted;
    }

    // AssetsTools.NET 3.0.5 ClassDatabaseToTypeTree throws (null TypeBlob); this is the same
    // conversion with a private string table only (no common-string offsets).
    private static TypeTreeType ConvertClassDatabaseType(ClassDatabaseFile classDatabase, AssetClassID type)
    {
        var classType = classDatabase.FindAssetClassByID((int)type) ?? throw new InvalidDataException($"classdata lacks {type}");
        var nodes = new List<TypeTreeNode>();
        var strings = new MemoryStream();
        var offsets = new Dictionary<string, uint>(StringComparer.Ordinal);
        uint Offset(string value)
        {
            if (offsets.TryGetValue(value, out var offset)) return offset;
            offset = (uint)strings.Length;
            var bytes = Encoding.UTF8.GetBytes(value);
            strings.Write(bytes);
            strings.WriteByte(0);
            offsets.Add(value, offset);
            return offset;
        }
        void Add(ClassDatabaseTypeNode node, int depth)
        {
            nodes.Add(new TypeTreeNode
            {
                Level = (byte)depth,
                MetaFlags = node.MetaFlag,
                Index = (uint)nodes.Count,
                TypeFlags = (TypeTreeNodeFlags)node.TypeFlags,
                TypeStrOffset = Offset(classDatabase.GetString(node.TypeName)),
                NameStrOffset = Offset(classDatabase.GetString(node.FieldName)),
                ByteSize = node.ByteSize,
                Version = node.Version,
            });
            foreach (var child in node.Children) Add(child, depth + 1);
        }
        Add(classType.GetPreferredNode(false), 0);
        var typeTree = new TypeTreeType
        {
            TypeId = classType.ClassId,
            ScriptTypeIndex = ushort.MaxValue,
            IsStrippedType = false,
            ScriptIdHash = Hash128.NewBlankHash(),
            TypeDependencies = Array.Empty<int>(),
            TypeBlob = new TypeTreeBlob { Nodes = nodes, StringBufferBytes = strings.ToArray() },
            TypeBlobIsDefinition = true,
        };
        typeTree.TypeHash = TypeHash(typeTree);
        return typeTree;
    }

    private static Hash128 TypeHash(TypeTreeType typeTree)
    {
        var md4 = new MD4();
        foreach (var node in typeTree.Nodes)
        {
            md4.Update(Encoding.UTF8.GetBytes(node.GetTypeString(typeTree.StringBufferBytes, TypeTreeType.COMMON_STRING_TABLE)));
            md4.Update(Encoding.UTF8.GetBytes(node.GetNameString(typeTree.StringBufferBytes, TypeTreeType.COMMON_STRING_TABLE)));
            md4.Update(BitConverter.GetBytes(node.ByteSize));
            md4.Update(BitConverter.GetBytes((int)node.TypeFlags));
            md4.Update(BitConverter.GetBytes((int)node.Version));
            md4.Update(BitConverter.GetBytes((int)(node.MetaFlags & 0x4000u)));
        }
        return new Hash128(md4.Digest());
    }

    private static void AddAsset(AssetsFile file, long pathId, AssetClassID type, ClassDatabaseFile classDatabase, AssetTypeValueField value, AssetsFile? hashSource = null)
    {
        EnsureType(file, type, classDatabase, hashSource);
        var info = AssetFileInfo.Create(file, pathId, (int)type, classDatabase)
            ?? throw new InvalidDataException($"cannot create {type}");
        info.SetNewData(value);
        file.Metadata.AddAssetInfo(info);
    }

    private static void AddContainer(AssetTypeValueField preload, AssetTypeValueField container, string path, params long[] pathIds)
    {
        var preloadIndex = preload.Children.Count;
        foreach (var pathId in pathIds)
        {
            var pointer = ValueBuilder.DefaultValueFieldFromArrayTemplate(preload);
            SetPointer(pointer, 0, pathId);
            preload.Children.Add(pointer);
        }
        var entry = ValueBuilder.DefaultValueFieldFromArrayTemplate(container);
        entry["first"].AsString = path;
        entry["second"]["preloadIndex"].AsInt = preloadIndex;
        entry["second"]["preloadSize"].AsInt = pathIds.Length;
        SetPointer(entry["second"]["asset"], 0, pathIds[0]);
        container.Children.Add(entry);
    }

    private static void SetPointer(AssetTypeValueField pointer, int fileId, long pathId)
    {
        pointer["m_FileID"].AsInt = fileId;
        pointer["m_PathID"].AsLong = pathId;
    }

    private static void SetByteVector(AssetTypeValueField field, byte[] bytes)
    {
        var array = field.TemplateField.IsArray ? field : field["Array"];
        array.TemplateField.ValueType = AssetValueType.ByteArray;
        array.Children = new List<AssetTypeValueField>();
        array.Value = new AssetTypeValue(AssetValueType.ByteArray, bytes);
    }

    // Copies values between two type trees of the same class field by field.
    private static void CopyByName(AssetTypeValueField source, AssetTypeValueField target)
    {
        if (target.TemplateField.IsArray)
        {
            if (target.TemplateField.ValueType == AssetValueType.ByteArray || source.TemplateField.ValueType == AssetValueType.ByteArray)
            {
                var bytes = source.TemplateField.ValueType == AssetValueType.ByteArray
                    ? source.AsByteArray
                    : source.Children.Select(child => child.AsByte).ToArray();
                SetByteVector(target, bytes);
                return;
            }
            target.Children = new List<AssetTypeValueField>();
            foreach (var sourceItem in source.Children)
            {
                var item = ValueBuilder.DefaultValueFieldFromArrayTemplate(target);
                CopyByName(sourceItem, item);
                target.Children.Add(item);
            }
            return;
        }
        if (target.Children.Count == 0 || target.TemplateField.ValueType == AssetValueType.String)
        {
            if (target.Value != null && source.Value != null) target.Value = source.Value.Clone();
            return;
        }
        foreach (var child in target.Children)
        {
            var sourceChild = source[child.FieldName];
            if (sourceChild.IsDummy) throw new InvalidDataException($"source lacks field {child.FieldName}");
            CopyByName(sourceChild, child);
        }
    }

    private static string TmpJson(AssetTypeValueField tmp)
    {
        var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer))
        {
            json.WriteStartObject();
            json.WriteNumber("schemaVersion", 1);
            json.WriteString("name", tmp["m_Name"].AsString);
            json.WriteString("version", tmp["m_Version"].AsString);
            json.WriteStartObject("faceInfo");
            foreach (var field in tmp["m_FaceInfo"].Children)
            {
                var name = field.FieldName.StartsWith("m_", StringComparison.Ordinal) ? field.FieldName[2..] : field.FieldName;
                name = char.ToLowerInvariant(name[0]) + name[1..];
                switch (field.TemplateField.ValueType)
                {
                    case AssetValueType.String: json.WriteString(name, field.AsString); break;
                    case AssetValueType.Float: json.WriteNumber(name, field.AsFloat); break;
                    default: json.WriteNumber(name, field.AsLong); break;
                }
            }
            json.WriteEndObject();
            json.WriteNumber("atlasWidth", tmp["m_AtlasWidth"].AsInt);
            json.WriteNumber("atlasHeight", tmp["m_AtlasHeight"].AsInt);
            json.WriteNumber("atlasPadding", tmp["m_AtlasPadding"].AsInt);
            json.WriteNumber("atlasRenderMode", tmp["m_AtlasRenderMode"].AsInt);
            foreach (var name in new[] { "normalStyle", "normalSpacingOffset", "boldStyle", "boldSpacing" })
                json.WriteNumber(name, tmp[name].AsFloat);
            json.WriteNumber("italicStyle", tmp["italicStyle"].AsInt);
            json.WriteNumber("tabSize", tmp["tabSize"].AsInt);
            // [index, width, height, bearingX, bearingY, advance, rectX, rectY, rectWidth, rectHeight, scale, atlasIndex]
            json.WriteStartArray("glyphs");
            foreach (var glyph in tmp["m_GlyphTable"]["Array"].Children)
            {
                var metrics = glyph["m_Metrics"];
                var rect = glyph["m_GlyphRect"];
                json.WriteStartArray();
                json.WriteNumberValue(glyph["m_Index"].AsUInt);
                json.WriteNumberValue(metrics["m_Width"].AsFloat);
                json.WriteNumberValue(metrics["m_Height"].AsFloat);
                json.WriteNumberValue(metrics["m_HorizontalBearingX"].AsFloat);
                json.WriteNumberValue(metrics["m_HorizontalBearingY"].AsFloat);
                json.WriteNumberValue(metrics["m_HorizontalAdvance"].AsFloat);
                json.WriteNumberValue(rect["m_X"].AsInt);
                json.WriteNumberValue(rect["m_Y"].AsInt);
                json.WriteNumberValue(rect["m_Width"].AsInt);
                json.WriteNumberValue(rect["m_Height"].AsInt);
                json.WriteNumberValue(glyph["m_Scale"].AsFloat);
                json.WriteNumberValue(glyph["m_AtlasIndex"].AsInt);
                json.WriteEndArray();
            }
            json.WriteEndArray();
            // [unicode, glyphIndex, scale]
            json.WriteStartArray("characters");
            foreach (var character in tmp["m_CharacterTable"]["Array"].Children)
            {
                json.WriteStartArray();
                json.WriteNumberValue(character["m_Unicode"].AsUInt);
                json.WriteNumberValue(character["m_GlyphIndex"].AsUInt);
                json.WriteNumberValue(character["m_Scale"].AsFloat);
                json.WriteEndArray();
            }
            json.WriteEndArray();
            json.WriteEndObject();
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    private sealed record Options(string TemplateBundle, string UnityData, string ClassData, string Ttf, string TmpData, string TmpAtlas, string Output, string? TmpJsonOutput)
    {
        public static Options Parse(string[] args)
        {
            var values = new Dictionary<string, string>(StringComparer.Ordinal);
            for (var index = 0; index < args.Length; index += 2)
            {
                if (!args[index].StartsWith("--", StringComparison.Ordinal) || index + 1 >= args.Length)
                    throw new ArgumentException(Usage);
                values[args[index][2..]] = args[index + 1];
            }
            string Required(string name) => values.TryGetValue(name, out var value) ? value : throw new ArgumentException($"missing --{name}\n{Usage}");
            return new Options(Required("template-bundle"), Required("unity-data"), Required("classdata"), Required("ttf"),
                Required("tmp-data"), Required("tmp-atlas"), Required("out"), values.GetValueOrDefault("tmp-json"));
        }

        private const string Usage = "usage: FontBundleBuilder --template-bundle <game TMP font bundle> --unity-data <data.unity3d> " +
            "--classdata <classdata.tpk> --ttf <font.ttf> --tmp-data <tmp-font.dat> --tmp-atlas <tmp-font-atlas.png> --out <bundle> [--tmp-json <file>]";
    }
}

// Minimal PNG reader for 8-bit non-interlaced atlases; returns the alpha channel bottom row first
// (Unity texture order).
internal static class Png
{
    public static byte[] ReadAlpha8BottomUp(string path, int expectedWidth, int expectedHeight)
    {
        var data = File.ReadAllBytes(path);
        ReadOnlySpan<byte> signature = new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 };
        if (!data.AsSpan(0, 8).SequenceEqual(signature)) throw new InvalidDataException("atlas is not a PNG");
        int width = 0, height = 0, colorType = -1;
        var idat = new MemoryStream();
        for (var offset = 8; offset < data.Length;)
        {
            var length = ReadBigEndian(data, offset);
            var type = Encoding.ASCII.GetString(data, offset + 4, 4);
            var body = offset + 8;
            if (type == "IHDR")
            {
                width = ReadBigEndian(data, body);
                height = ReadBigEndian(data, body + 4);
                if (data[body + 8] != 8 || data[body + 12] != 0) throw new InvalidDataException("atlas must be 8-bit non-interlaced");
                colorType = data[body + 9];
            }
            else if (type == "IDAT") idat.Write(data, body, length);
            else if (type == "IEND") break;
            offset = body + length + 4;
        }
        if (width != expectedWidth || height != expectedHeight)
            throw new InvalidDataException($"atlas is {width}x{height}, TMP data expects {expectedWidth}x{expectedHeight}");
        var channels = colorType switch { 0 => 1, 4 => 2, 6 => 4, _ => throw new InvalidDataException($"unsupported PNG color type {colorType}") };
        var stride = width * channels;
        var raw = new byte[(stride + 1) * height];
        idat.Position = 0;
        using (var inflater = new ZLibStream(idat, CompressionMode.Decompress))
        {
            var read = 0;
            while (read < raw.Length)
            {
                var count = inflater.Read(raw, read, raw.Length - read);
                if (count == 0) throw new InvalidDataException("truncated PNG data");
                read += count;
            }
        }
        var previous = new byte[stride];
        var current = new byte[stride];
        var alpha = new byte[width * height];
        for (var y = 0; y < height; y++)
        {
            var row = y * (stride + 1);
            var filter = raw[row];
            for (var x = 0; x < stride; x++)
            {
                int left = x >= channels ? current[x - channels] : 0;
                int up = previous[x];
                int upLeft = x >= channels ? previous[x - channels] : 0;
                int value = raw[row + 1 + x];
                current[x] = (byte)(filter switch
                {
                    0 => value,
                    1 => value + left,
                    2 => value + up,
                    3 => value + ((left + up) >> 1),
                    4 => value + Paeth(left, up, upLeft),
                    _ => throw new InvalidDataException($"bad PNG filter {filter}")
                });
            }
            var destination = (height - 1 - y) * width;
            for (var x = 0; x < width; x++) alpha[destination + x] = current[x * channels + channels - 1];
            (previous, current) = (current, previous);
        }
        return alpha;
    }

    private static int Paeth(int a, int b, int c)
    {
        var p = a + b - c;
        int pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    }

    private static int ReadBigEndian(byte[] data, int offset) =>
        (data[offset] << 24) | (data[offset + 1] << 16) | (data[offset + 2] << 8) | data[offset + 3];
}
