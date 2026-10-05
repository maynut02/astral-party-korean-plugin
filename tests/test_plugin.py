from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_windows_plugin_uses_local_core_and_interop_references() -> None:
    projects = "\n".join(path.read_text(encoding="utf-8") for path in [
        ROOT / "src/Preloader/AstralPartyKoreanPlugin.dataUnity3dRedirect.csproj",
        ROOT / "src/Plugin/AstralPartyKoreanPlugin.csproj",
    ])
    props = (ROOT / "Directory.Build.props").read_text(encoding="utf-8")
    assert "AstralBepInExRoot" in projects
    assert "/core/" in projects and "/interop/" in projects
    assert "AstralRefsRoot" in props and "AstralGameRoot" in props
    assert "AstralDepsRoot" not in projects
    assert "<Private>false</Private>" in projects


def test_windows_plugin_components_share_package_version() -> None:
    preloader = (ROOT / "src/Preloader/DataUnity3dRedirect.cs").read_text(encoding="utf-8")
    plugin = (ROOT / "src/Plugin/AddressablesInProcessPatch.cs").read_text(encoding="utf-8")
    preloader_project = (ROOT / "src/Preloader/AstralPartyKoreanPlugin.dataUnity3dRedirect.csproj").read_text(encoding="utf-8")
    plugin_project = (ROOT / "src/Plugin/AstralPartyKoreanPlugin.csproj").read_text(encoding="utf-8")
    assert "AstralBuildVersion.Value" in preloader
    assert "PluginVersion = AstralBuildVersion.Value" in plugin
    assert "AstralBuildVersionSource" in preloader_project
    assert "AstralBuildVersionSource" in plugin_project


def test_plugin_uses_game_ui_reference() -> None:
    source = (ROOT / "src/Plugin/AddressablesInProcessPatch.cs").read_text(encoding="utf-8")
    project = (ROOT / "src/Plugin/AstralPartyKoreanPlugin.csproj").read_text(encoding="utf-8")
    assert "using UnityEngine.EventSystems;" not in source
    assert "/interop/UnityEngine.UI.dll" in project
    assert "UnityEngine.UI.Reference" not in project
    assert not (ROOT / "src/UnityEngine.UI.Reference").exists()
    assert "Resources.FindObjectsOfTypeAll<Font>()" not in source
    assert "MakeGenericMethod(typeof(Font)).Invoke" in source


def test_preloader_restores_game_window_foreground_once() -> None:
    source = (ROOT / "src/Preloader/DataUnity3dRedirect.cs").read_text(encoding="utf-8")
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
    source = (ROOT / "src/Preloader/DataUnity3dRedirect.cs").read_text(encoding="utf-8")
    assert "AstralBuildVersion.Value" in source
    assert "installed data.unity3d does not match release source" not in source
    assert "installed data.unity3d is missing or unreadable" in source
    assert '" action=" + (matchesManifestSource ? "accepted" : "ignored-mismatch")' in source
    assert "if (info.Length != state.SourceSize) return false;" not in source
    assert "return true;" in source[source.index("private static bool VerifySource"):source.index("private static bool VerifyReplacement")]
    assert "if (info.Length != state.PayloadSize) return false;" in source
    assert "string.Equals(actual, state.PayloadSha256" in source


def test_overlay_close_glyph_uses_release_safe_image_icon() -> None:
    source = (ROOT / "src/Plugin/AddressablesInProcessPatch.cs").read_text(encoding="utf-8")
    assert "CreateCloseGlyphBar" in source
    assert "GetSolidSprite" in source
    assert "texture.SetPixel(0, 0, Color.white)" in source
    assert "texture.SetPixels(" not in source
    assert 'glyph.text = "×"' not in source
