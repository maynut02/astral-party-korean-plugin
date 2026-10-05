from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PLUGIN = ROOT


def test_windows_plugin_build_has_no_game_install_dependency() -> None:
    projects = "\n".join(
        path.read_text(encoding="utf-8")
        for path in [
            PLUGIN / "src/Preloader/AstralPartyKoreanPlugin.dataUnity3dRedirect.csproj",
            PLUGIN / "src/Plugin/AstralPartyKoreanPlugin.csproj",
            PLUGIN / "src/UnityEngine.UI.Reference/UnityEngine.UI.Reference.csproj",
        ]
    )
    assert "GameRoot" not in projects
    assert "BepInEx/interop" not in projects
    assert "BepInEx\\interop" not in projects
    assert "csc.exe" not in projects
    assert "AstralDepsRoot" in projects


def test_windows_plugin_components_share_package_version() -> None:
    preloader = (PLUGIN / "src/Preloader/DataUnity3dRedirect.cs").read_text(encoding="utf-8")
    plugin = (PLUGIN / "src/Plugin/AddressablesInProcessPatch.cs").read_text(encoding="utf-8")
    preloader_project = (PLUGIN / "src/Preloader/AstralPartyKoreanPlugin.dataUnity3dRedirect.csproj").read_text(encoding="utf-8")
    plugin_project = (PLUGIN / "src/Plugin/AstralPartyKoreanPlugin.csproj").read_text(encoding="utf-8")
    assert "AstralBuildVersion.Value" in preloader
    assert "PluginVersion = AstralBuildVersion.Value" in plugin
    assert "AstralBuildVersionSource" in preloader_project
    assert "AstralBuildVersionSource" in plugin_project


def test_plugin_uses_compile_only_ui_reference() -> None:
    source = (PLUGIN / "src/Plugin/AddressablesInProcessPatch.cs").read_text(encoding="utf-8")
    project = (PLUGIN / "src/Plugin/AstralPartyKoreanPlugin.csproj").read_text(
        encoding="utf-8"
    )
    ui_reference = (PLUGIN / "src/UnityEngine.UI.Reference/UnityEngine.UI.Reference.cs").read_text(
        encoding="utf-8"
    )
    assert "using UnityEngine.EventSystems;" not in source
    assert "UnityEngine.UI.Reference.csproj" in project
    assert "Compile-only API surface" in ui_reference
    assert "Resources.FindObjectsOfTypeAll<Font>()" not in source
    assert "MakeGenericMethod(typeof(Font)).Invoke" in source


def test_preloader_restores_game_window_foreground_once() -> None:
    source = (PLUGIN / "src/Preloader/DataUnity3dRedirect.cs").read_text(encoding="utf-8")
    assert "WsExNoActivate" in source
    assert "SwShowNoActivate" in source
    assert "ScheduleGameForegroundRestore" in source
    assert '"UnityWndClass"' in source
    assert "TryActivateGameWindow" in source
    assert "AttachThreadInput" in source
    assert "SetForegroundWindow(gameWindow)" in source
    assert "HwndTopmost" in source
    assert "HwndNoTopmost" in source


def test_preloader_allows_installed_data_unity3d_mismatch() -> None:
    source = (PLUGIN / "src/Preloader/DataUnity3dRedirect.cs").read_text(encoding="utf-8")
    assert "AstralBuildVersion.Value" in source
    assert "installed data.unity3d does not match release source" not in source
    assert "installed data.unity3d is missing or unreadable" in source
    assert '" action=" + (matchesManifestSource ? "accepted" : "ignored-mismatch")' in source
    assert "if (info.Length != state.SourceSize) return false;" not in source
    assert "return true;" in source[source.index("private static bool VerifySource"):source.index("private static bool VerifyReplacement")]
    assert "if (info.Length != state.PayloadSize) return false;" in source
    assert "string.Equals(actual, state.PayloadSha256" in source


def test_overlay_close_glyph_uses_release_safe_image_icon() -> None:
    source = (PLUGIN / "src/Plugin/AddressablesInProcessPatch.cs").read_text(encoding="utf-8")
    assert "CreateCloseGlyphBar" in source
    assert "GetSolidSprite" in source
    assert "texture.SetPixel(0, 0, Color.white)" in source
    assert "texture.SetPixels(" not in source
    assert 'glyph.text = "×"' not in source
