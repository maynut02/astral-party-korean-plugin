using System;
using System.Collections.Generic;
using UnityEngine;

namespace AstralParty.KoreanPatch;

// No class injection or managed UI delegates: all native objects and input are
// driven from Plugin's EventSystem.Update prefix on the Unity main thread.
internal static class StatusOverlay
{
    private const float Width = 520f;
    private const float Height = 400f;
    private const float Margin = 32f;
    private const int SortingOrder = 890000; // The sibling chat window uses 900000.
    private const string FontAlias = "AstralPartyKoreanPatchOverlay";
    private static readonly Color PanelColor = new Color32(7, 16, 20, 255);
    private static readonly Color AccentColor = new Color32(255, 0, 180, 255);
    private static readonly Color BodyColor = new(0.94f, 0.97f, 1f, 0.92f);
    private static readonly Color CaptionColor = new(0.56f, 0.66f, 0.78f, 0.75f);
    private static readonly List<FguiNode> Nodes = new();
    private static FguiNode? window;
    private static FguiNode? closeButton;
    private static FguiNode? restartButton;
    private static float panelHeight = Height;
    private static bool updateNotified;
    private static FguiNode? gameVersion;
    private static FguiNode? gameRevision;
    private static FguiNode? packVersion;
    private static FguiNode? packRevision;
    private static FguiNode? packNumber;
    private static FguiNode? installedVersion;
    private static FguiNode? latestVersion;
    private static FguiNode? status;
    private static OverlaySnapshot? snapshot;
    private static int seenPackRevision = -1;
    private static int seenUpdateRevision = -1;
    private static int seenGameRevision = -1;
    private static bool closed;
    private static bool disabled;
    private static bool readyLogged;
    private static bool fontFailureLogged;
    private static bool retiring;
    private static bool fontResetLogged;
    private static string? fontName;

    internal static void Tick()
    {
        if (disabled) return;
        if (retiring)
        {
            // Hidden on the previous frame. FairyGUI caches each frame's hit target,
            // and game code reads GRoot.touchTarget.touchable when the pointer is on
            // UI; disposing that frame's target would make it null mid-frame.
            retiring = false;
            DisposeNodes();
            ReleaseFont();
        }
        try
        {
            if (!updateNotified && Plugin.Updates.Snapshot().RestartRequired)
            {
                updateNotified = true;
                closed = false;
                Plugin.Event("OVERLAY_UPDATE_INSTALLED", "Reopening once to offer game restart");
                if (window != null)
                {
                    Retire();
                    return;
                }
            }
            if (closed) return;
            var root = FguiNode.RootPointer;
            if (root == IntPtr.Zero) return;
            if (window != null && (!window.IsAlive || FguiNode.ParentOf(window.Pointer) != root))
                DisposeNodes();
            else if (window != null && FguiNode.FontRegistryChanged)
            {
                // Rebuild next frame so every text field binds to a freshly registered font.
                Retire();
                if (!fontResetLogged)
                {
                    fontResetLogged = true;
                    Plugin.Event("OVERLAY_FONT_RESET", "FairyGUI font registry changed; overlay rebuilt");
                }
                return;
            }
            if (disabled)
            {
                ReleaseFont();
                return;
            }
            if (window == null) Create(root);
            window!.SetXY(Math.Max(0f, FguiNode.WidthOf(root) - Width - Margin),
                Math.Max(0f, FguiNode.HeightOf(root) - panelHeight - Margin));
            RefreshTexts();
            if (Input.GetKeyDown(KeyCode.Escape))
                Close("Escape");
            else if (Input.GetMouseButtonUp(0))
            {
                if (ButtonTarget(root, closeButton)) Close("close button");
                else if (ButtonTarget(root, restartButton)) Plugin.Restart();
            }
        }
        catch (Exception ex)
        {
            ReportFailure(ex);
            DisposeNodes();
            ReleaseFont();
        }
    }

    private static bool ButtonTarget(IntPtr root, FguiNode? button)
    {
        if (button == null) return false;
        var target = FguiNode.TouchTarget(root);
        for (var depth = 0; target != IntPtr.Zero && depth < 16; depth++)
        {
            if (target == button.Pointer) return true;
            if (target == root || target == window!.Pointer) break;
            target = FguiNode.ParentOf(target);
        }
        return false;
    }

    private static void Create(IntPtr root)
    {
        RegisterFont();
        panelHeight = Plugin.Updates.Snapshot().RestartRequired ? Height + 60f : Height;
        window = Track(FguiNode.Component(Width, panelHeight));
        // Never expose a partially constructed tree if a game signature changed.
        window.SetVisible(false);
        window.SetOpaque(true);
        window.SetSortingOrder(SortingOrder);
        FguiNode.AddToRoot(root, window);
        AddGraph(window, 0f, 0f, Width, panelHeight, PanelColor, 26f, 2f, AccentColor);
        AddText(window, "아스트랄 파티 한글패치", 28, BodyColor, 28f, 22f, 410f, 42f);
        closeButton = AddComponent(window, 454f, 18f, 48f, 48f);
        closeButton.SetOpaque(true);
        AddGraph(closeButton, 0f, 0f, 48f, 48f, AccentColor, 14f);
        AddCloseStroke(45f);
        AddCloseStroke(-45f);

        AddSection("게임", 92f);
        gameVersion = AddCell("버전", 130f, 92f, 132f);
        gameRevision = AddCell("리비전", 276f, 92f, 112f);
        AddSection("번역 팩", 164f);
        packVersion = AddCell("버전", 130f, 164f, 132f);
        packRevision = AddCell("리비전", 276f, 164f, 112f);
        packNumber = AddCell("번호", 402f, 164f, 90f);
        AddSection("플러그인", 236f);
        installedVersion = AddCell("설치", 130f, 236f, 132f);
        latestVersion = AddCell("최신", 276f, 236f, 216f);
        AddSection("상태", 314f);
        // Same 56-unit band as the cell rows, so the text centers on the "상태" label.
        status = AddText(window, "", 18, StatusColor(StatusSeverity.Checking),
            130f, 314f, 362f, 56f, wrap: true);
        if (Plugin.Updates.Snapshot().RestartRequired)
        {
            restartButton = AddComponent(window, 306f, 390f, 186f, 42f);
            restartButton.SetOpaque(true);
            AddGraph(restartButton, 0f, 0f, 186f, 42f, AccentColor, 12f);
            AddText(restartButton, "지금 다시 시작", 19, BodyColor, 24f, 0f, 154f, 42f);
        }
        RefreshTexts();
        window.SetXY(Math.Max(0f, FguiNode.WidthOf(root) - Width - Margin),
            Math.Max(0f, FguiNode.HeightOf(root) - panelHeight - Margin));
        window.SetVisible(true);
        if (!readyLogged)
        {
            readyLogged = true;
            Plugin.Event("OVERLAY_READY", "FairyGUI; 520x" + panelHeight + " GRoot units; sortingOrder=890000; opaque hit testing; " +
                "font=" + (fontName ?? "game default"));
        }
    }

    private static void RegisterFont()
    {
        FontAssets.EnsureLoaded();
        var font = FontAssets.KoreanFont;
        if (font == null) return;
        try
        {
            FguiNode.RegisterFont(FontAlias, font);
            fontName = FontAlias;
        }
        catch (Exception ex)
        {
            // Font registration is optional: leave each GTextField on the game's
            // default font rather than disabling an otherwise usable overlay.
            fontName = null;
            if (fontFailureLogged) return;
            fontFailureLogged = true;
            Plugin.Event("OVERLAY_FONT_UNAVAILABLE", ex.GetType().Name + ":" + ex.Message);
        }
    }

    private static void RefreshTexts()
    {
        var nextPack = Plugin.Packs.Revision;
        var nextUpdate = Plugin.Updates.Revision;
        var nextGame = GameInfoReader.ChangeRevision;
        if (snapshot != null && nextPack == seenPackRevision && nextUpdate == seenUpdateRevision
            && nextGame == seenGameRevision) return;
        seenPackRevision = nextPack;
        seenUpdateRevision = nextUpdate;
        seenGameRevision = nextGame;
        var next = Plugin.GetUiSnapshot();
        if (next == snapshot) return;
        gameVersion!.SetText(next.GameVersion);
        gameRevision!.SetText(next.GameRevision);
        packVersion!.SetText(next.PackVersion);
        packRevision!.SetText(next.PackRevision);
        packNumber!.SetText(next.PackNumber);
        installedVersion!.SetText(next.InstalledVersion);
        latestVersion!.SetText(next.LatestVersion);
        status!.SetText(next.Status);
        status.SetColor(StatusColor(next.Severity));
        snapshot = next;
    }

    private static FguiNode Track(FguiNode node)
    {
        Nodes.Add(node);
        return node;
    }

    private static FguiNode AddComponent(FguiNode parent, float x, float y, float width, float height)
    {
        var node = Track(FguiNode.Component(width, height));
        parent.AddChild(node);
        node.SetXY(x, y);
        return node;
    }

    private static void AddGraph(FguiNode parent, float x, float y, float width, float height,
        Color color, float radius, float lineSize = 0f, Color lineColor = default)
    {
        var node = Track(FguiNode.Graph(width, height));
        parent.AddChild(node);
        node.SetXY(x, y);
        node.SetTouchable(false);
        node.Fill(color, radius, lineSize, lineColor);
    }

    private static void AddCloseStroke(float rotation)
    {
        var node = Track(FguiNode.Graph(24f, 3f));
        closeButton!.AddChild(node);
        node.SetTouchable(false);
        node.Fill(Color.white, 1.5f);
        node.SetCenterPivot();
        node.SetXY(24f, 24f);
        node.SetRotation(rotation);
    }

    private static FguiNode AddText(FguiNode parent, string text, int size, Color color,
        float x, float y, float width, float height, bool wrap = false)
    {
        var node = Track(FguiNode.Text(width, height));
        parent.AddChild(node);
        node.SetTouchable(false);
        node.SetTextStyle(fontName, size, color, wrap);
        node.SetXY(x, y);
        node.SetText(text);
        return node;
    }

    private static void AddSection(string label, float y) =>
        AddText(window!, label, 18, CaptionColor, 28f, y + 12f, 88f, 32f);

    private static FguiNode AddCell(string caption, float x, float y, float width)
    {
        AddText(window!, caption, 14, CaptionColor, x, y, width, 21f);
        return AddText(window!, "", 23, BodyColor, x, y + 22f, width, 34f);
    }

    private static void Close(string reason)
    {
        closed = true;
        Retire();
        Plugin.Event("OVERLAY_CLOSED", reason);
    }

    private static void Retire()
    {
        window!.SetVisible(false);
        retiring = true;
    }

    private static void DisposeNodes()
    {
        // Dispose every owned node even after a parent/game teardown. Each
        // wrapper releases its handle exactly once, including disposed children.
        for (var index = Nodes.Count - 1; index >= 0; index--)
        {
            try { Nodes[index].Dispose(); }
            catch (Exception ex) { ReportFailure(ex); }
        }
        Nodes.Clear();
        window = closeButton = restartButton = gameVersion = gameRevision = null;
        packVersion = packRevision = packNumber = installedVersion = latestVersion = status = null;
        snapshot = null;
    }

    private static void ReleaseFont()
    {
        try { FguiNode.ReleaseFont(); }
        catch (Exception ex) { ReportFailure(ex); }
        fontName = null;
    }

    private static void ReportFailure(Exception ex)
    {
        if (disabled) return;
        disabled = true;
        Plugin.Event("OVERLAY_DISABLED", ex.GetType().Name + ":" + ex.Message);
    }

    private static Color StatusColor(StatusSeverity severity) => severity switch
    {
        StatusSeverity.Error => new Color(1f, 0.30f, 0.32f, 1f),
        StatusSeverity.Warning => new Color(1f, 0.72f, 0.24f, 1f),
        StatusSeverity.Success => new Color(0.30f, 0.90f, 0.48f, 1f),
        _ => new Color(0.30f, 0.62f, 1f, 1f)
    };
}
