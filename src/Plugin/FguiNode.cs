using System;
using Il2CppInterop.Runtime;
using UnityEngine;

namespace AstralParty.KoreanPatch;

// Owned overlay objects retain individual GC handles, including children whose
// native Dispose is reached through their parent. Game-owned roots are borrowed
// as pointers for the current tick only and are never disposed.
internal sealed class FguiNode : IDisposable
{
    private const string GObject = "FairyGUI.GObject";
    private static IntPtr rootClass;
    private static IntPtr registeredFont;
    private static nint registeredFontHandle;
    private static int registeredFontVersion;
    private static IntPtr fontFactoryField;
    private nint handle;
    private float x = float.NaN, y = float.NaN;
    private string? text;
    private Color color = new(float.NaN, 0f, 0f, 0f);

    private FguiNode(IntPtr pointer)
    {
        Pointer = pointer;
        handle = IL2CPP.il2cpp_gchandle_new(pointer, false);
    }

    internal IntPtr Pointer { get; }
    internal bool IsAlive => handle != 0 && IL2CPP.il2cpp_gchandle_get_target(handle) != IntPtr.Zero
        && !FairyGui.Get<bool>(Pointer, "get_isDisposed");

    internal static IntPtr RootPointer
    {
        get
        {
            if (rootClass == IntPtr.Zero && !FairyGui.TryClass("GRoot", out rootClass)) return IntPtr.Zero;
            return FairyGui.CallStatic(rootClass, "get_inst");
        }
    }

    internal static IntPtr ParentOf(IntPtr pointer) => pointer == IntPtr.Zero
        ? IntPtr.Zero : FairyGui.Call(pointer, "get_parent");

    internal static IntPtr TouchTarget(IntPtr root) => FairyGui.Call(root, "get_touchTarget");
    internal static float WidthOf(IntPtr pointer) => FairyGui.Get<float>(pointer, "get_width");
    internal static float HeightOf(IntPtr pointer) => FairyGui.Get<float>(pointer, "get_height");
    internal static void AddToRoot(IntPtr root, FguiNode node) => FairyGui.CallObject(root, "AddChild", GObject, node.Pointer);

    internal static FguiNode Component(float width, float height) => Create("GComponent", width, height);
    internal static FguiNode Graph(float width, float height) => Create("GGraph", width, height);
    internal static FguiNode Text(float width, float height) => Create("GTextField", width, height);

    private static FguiNode Create(string type, float width, float height)
    {
        var node = new FguiNode(FairyGui.New(FairyGui.Class(type)));
        try
        {
            FairyGui.Call(node.Pointer, "SetSize", FairyGui.Float + "," + FairyGui.Float, width, height);
            return node;
        }
        catch
        {
            try { node.Dispose(); } catch { }
            throw;
        }
    }

    internal void AddChild(FguiNode child) => FairyGui.CallObject(Pointer, "AddChild", GObject, child.Pointer);

    internal void SetXY(float nextX, float nextY)
    {
        if (x == nextX && y == nextY) return;
        FairyGui.Call(Pointer, "SetXY", FairyGui.Float + "," + FairyGui.Float, nextX, nextY);
        x = nextX;
        y = nextY;
    }

    internal void SetCenterPivot() => FairyGui.Call(Pointer, "SetPivot",
        FairyGui.Float + "," + FairyGui.Float + "," + FairyGui.Bool, 0.5f, 0.5f, true);
    internal void SetRotation(float degrees) => FairyGui.Set(Pointer, "set_rotation", FairyGui.Float, degrees);
    internal void SetVisible(bool value) => FairyGui.Set(Pointer, "set_visible", FairyGui.Bool, value);
    internal void SetTouchable(bool value) => FairyGui.Set(Pointer, "set_touchable", FairyGui.Bool, value);
    internal void SetOpaque(bool value) => FairyGui.Set(Pointer, "set_opaque", FairyGui.Bool, value);
    internal void SetSortingOrder(int value) => FairyGui.Set(Pointer, "set_sortingOrder", FairyGui.Int, value);

    internal void Fill(Color fill, float radius, float lineSize = 0f, Color lineColor = default) =>
        FairyGui.DrawRoundRect(FairyGui.Call(Pointer, "get_shape"), lineSize, lineColor, fill, radius);

    internal void SetTextStyle(string? font, int size, Color value, bool wrap)
    {
        // A null alias preserves the new GTextField's game-default font.
        FairyGui.Set(Pointer, "set_autoSize", "FairyGUI.AutoSizeType", 3);
        FairyGui.Set(Pointer, "set_singleLine", FairyGui.Bool, !wrap);
        FairyGui.Set(Pointer, "set_align", "FairyGUI.AlignType", 0);
        FairyGui.Set(Pointer, "set_verticalAlign", "FairyGUI.VertAlignType", 1);
        var format = FairyGui.Call(Pointer, "get_textFormat");
        if (font != null) FairyGui.WriteStringField(format, "font", font);
        FairyGui.WriteField(format, "size", size);
        FairyGui.WriteField(format, "color", value);
        FairyGui.WriteField(format, "bold", false);
        FairyGui.CallObject(Pointer, "set_textFormat", "FairyGUI.TextFormat", format);
        color = value;
    }

    internal void SetText(string value)
    {
        if (string.Equals(text, value, StringComparison.Ordinal)) return;
        FairyGui.SetString(Pointer, "set_text", value);
        text = value;
    }

    internal void SetColor(Color value)
    {
        if (color == value) return;
        FairyGui.Set(Pointer, "set_color", FairyGui.ColorType, value);
        color = value;
    }

    internal static void RegisterFont(string alias, Font font)
    {
        var name = IL2CPP.ManagedStringToIl2Cpp(alias);
        var nameHandle = IL2CPP.il2cpp_gchandle_new(name, false);
        try
        {
            var dynamicFont = FairyGui.NewWithObjects(FairyGui.Class("DynamicFont"),
                FairyGui.String + ",UnityEngine.Font", name, font.Pointer);
            var fontHandle = IL2CPP.il2cpp_gchandle_new(dynamicFont, false);
            try
            {
                FairyGui.CallStaticObjects(FairyGui.Class("FontManager"), "RegisterFont",
                    "FairyGUI.BaseFont," + FairyGui.String, dynamicFont, name);
            }
            catch
            {
                DisposeFont(dynamicFont, fontHandle);
                throw;
            }
            var previous = registeredFont;
            var previousHandle = registeredFontHandle;
            registeredFont = dynamicFont;
            registeredFontHandle = fontHandle;
            registeredFontVersion = FontRegistryVersion();
            // Register the replacement first: unregistering the old font could
            // otherwise remove the replacement's alias too.
            if (previous != IntPtr.Zero) DisposeFont(previous, previousHandle);
        }
        finally { IL2CPP.il2cpp_gchandle_free(nameHandle); }
    }

    // The game's FontManager.Clear() (UIManager.AsyncLoadFonts, run when the
    // game starts after the login screen) disposes every registered font. A
    // disposed DynamicFont stops following Font.textureRebuilt, so text bound to
    // it keeps stale atlas UVs. Any registry write after ours means re-register.
    internal static bool FontRegistryChanged =>
        registeredFont != IntPtr.Zero && FontRegistryVersion() != registeredFontVersion;

    private static int FontRegistryVersion()
    {
        if (fontFactoryField == IntPtr.Zero)
            fontFactoryField = FairyGui.StaticField(FairyGui.Class("FontManager"), "sFontFactory");
        var factory = FairyGui.ReadStaticObject(fontFactoryField);
        return factory == IntPtr.Zero ? -1 : FairyGui.ReadField<int>(factory, "_version");
    }

    internal static void ReleaseFont()
    {
        var font = registeredFont;
        var fontHandle = registeredFontHandle;
        registeredFont = IntPtr.Zero;
        registeredFontHandle = 0;
        if (font == IntPtr.Zero) return;
        try { FairyGui.CallStaticObject(FairyGui.Class("FontManager"), "UnregisterFont", "FairyGUI.BaseFont", font); }
        finally { DisposeFont(font, fontHandle); }
    }

    private static void DisposeFont(IntPtr font, nint fontHandle)
    {
        try
        {
            FairyGui.Call(font, "Dispose");
            // DynamicFont.Dispose only unsubscribes Font.textureRebuilt; the NTexture
            // it created owns materials. Its destroyMethod=None keeps the shared
            // Unity font atlas alive while the materials are destroyed.
            var texture = FairyGui.ReadField<IntPtr>(font, "mainTexture");
            if (texture != IntPtr.Zero) FairyGui.Call(texture, "Dispose");
        }
        finally { IL2CPP.il2cpp_gchandle_free(fontHandle); }
    }

    public void Dispose()
    {
        try
        {
            if (IsAlive) FairyGui.Call(Pointer, "Dispose");
        }
        finally
        {
            if (handle != 0) IL2CPP.il2cpp_gchandle_free(handle);
            handle = 0;
        }
    }
}
