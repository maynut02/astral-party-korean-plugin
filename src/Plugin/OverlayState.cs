using System.Globalization;

namespace AstralParty.KoreanPatch;

internal enum StatusSeverity { Checking, Success, Warning, Error }
internal sealed record OverlaySnapshot(string GameVersion, string GameRevision,
    string PackVersion, string PackRevision, string PackNumber, string InstalledVersion,
    string LatestVersion, string Status, StatusSeverity Severity);

internal static class OverlayState
{
    internal static OverlaySnapshot Create(string gameVersion, string gameRevision, string installed, string latest,
        bool supported, string? cleanupFailure, PackState state)
    {
        var pack = state.Frozen ? state.Active : state.Candidate;
        string status;
        StatusSeverity severity;
        if (cleanupFailure != null)
        { status = "이전 파일 정리 실패: " + cleanupFailure + " 파일을 삭제해 주세요"; severity = StatusSeverity.Error; }
        else if (!supported)
        { status = "지원하지 않는 게임입니다 (INT/CN 전용)"; severity = StatusSeverity.Error; }
        else if (state.UpdateRequired)
        { status = "번역 팩 형식이 변경되었습니다. 플러그인을 업데이트해 주세요"; severity = StatusSeverity.Warning; }
        else if (state.Frozen && state.Candidate != null && state.Candidate.Number > (state.Active?.Number ?? 0))
        { status = "새 번역 팩 #" + state.Candidate.Number + "은 다음 실행부터 적용됩니다"; severity = StatusSeverity.Warning; }
        else if (state.Checking)
        { status = "번역 팩 확인 중"; severity = StatusSeverity.Checking; }
        else if (pack == null)
        { status = "번역 팩이 없어 원문을 표시합니다"; severity = StatusSeverity.Error; }
        else if (state.Offline)
        { status = "오프라인: 저장된 번역 팩 #" + pack.Number + " 사용 중"; severity = StatusSeverity.Warning; }
        else
        { status = state.Frozen ? "최신 번역 팩 #" + pack.Number + " 적용 완료" : "최신 번역 팩 #" + pack.Number + " 적용 준비 완료"; severity = StatusSeverity.Success; }
        return new OverlaySnapshot(gameVersion, gameRevision, pack?.Version ?? "-", pack?.Revision ?? "-",
            pack == null ? "-" : "#" + pack.Number.ToString(CultureInfo.InvariantCulture),
            "v" + installed, latest, status, severity);
    }
}
