using System;
using UnityEngine;

namespace AstralParty.KoreanPatch;

// Main-thread glue only; the JSON and source URL parser stays Unity-free.
internal static class GameInfoReader
{
    private const int PollFrames = 120;
    private const float TimeoutSeconds = 60f;
    private static bool started;
    private static bool finished;
    private static float startedAt;
    private static int nextPollFrame;
    internal static string Version { get; private set; } = "-";
    internal static string Revision { get; private set; } = "확인 중";
    internal static int ChangeRevision { get; private set; }

    internal static void Initialize(string fallbackVersion) => Version = fallbackVersion;

    internal static void Tick(int frame)
    {
        if (finished) return;
        try
        {
            var now = Time.realtimeSinceStartup;
            if (!started)
            {
                started = true;
                startedAt = now;
                nextPollFrame = frame;
            }
            if (now - startedAt >= TimeoutSeconds)
            {
                FinishUnavailable("hot-update data was unavailable after 60 seconds");
                return;
            }
            if (frame < nextPollFrame) return;
            nextPollFrame = frame + PollFrames;
            if (!GameInfo.TryParse(App.WebServerConfig._hotUpdateConfigData, out var info)) return;
            if (info!.Version.Length != 0) Version = info.Version;
            Revision = info.Revision;
            finished = true;
            ChangeRevision++;
            Plugin.Event("GAME_INFO_READ", "version=" + Version + "; revision=" + Revision + "; route=" + info.Route);
        }
        catch (Exception ex) { FinishUnavailable(ex.GetType().Name + ":" + ex.Message); }
    }

    private static void FinishUnavailable(string reason)
    {
        finished = true;
        Revision = "-";
        ChangeRevision++;
        Plugin.Event("GAME_INFO_UNAVAILABLE", reason);
    }
}
