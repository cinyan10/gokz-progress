#include <sourcemod>
#include <sdktools>
#include <gokz/core>
#include <gokz/localdb>
#include <gokz/localranks>
#include <gokz/replays>
#include <cstrike>
#include <clientprefs>

#include "gokz-progress/var.sp"
#include "gokz-progress/replay.sp"
#include "gokz-progress/utils.sp"
#include "gokz-progress/calc.sp"
#include "gokz-progress/timediff.sp"

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo = 
{
    name = "gokz-progress",
    author = "Cinyan10",
    description = "show player's progress of current map",
    version = "1.0.0"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("GetOnePlayerProgressStats", Native_GetOnePlayerProgressStats);
    CreateNative("GetProgressText", Native_GetProgressText);
    RegPluginLibrary("gokz_progress");
    return APLRes_Success;
}

/* ----------- Events ------------*/

public void OnPluginStart()
{
    gCvarIncludeBots = CreateConVar("gokz_progress_include_bots", "0", "Include bots in ranking", FCVAR_NONE, true, 0.0, true, 1.0);
    HookConVarChange(gCvarIncludeBots, OnIncludeBotsChanged);
    gCvarDebug = CreateConVar("gokz_progress_debug", "0", "Enable debug output for replay loading", FCVAR_NONE, true, 0.0, true, 1.0);
    gCvarMaxReplayTime = CreateConVar("gokz_progress_max_replay_time", "30", "Maximum replay time in minutes (default: 30)", FCVAR_NONE, true, 1.0, true, 120.0);
    RegConsoleCmd("sm_rank", Command_ToggleRank);
    RegConsoleCmd("sm_progress", Command_ToggleProgress);
    RegConsoleCmd("sm_timediff", Command_ToggleTimeDiff);   // <-- add
    TimeDiff_Init();

    gRankDisplayCookie = RegClientCookie("show_rank", "Show rank in progress menu", CookieAccess_Public);
    gProgressDisplayCookie = RegClientCookie("show_progress", "Show progress in progress menu", CookieAccess_Public);
    gTickPositions = new ArrayList(3);
    RestartProgressUpdater();
}

public void OnMapStart()
{
    RestartProgressUpdater();
    TimeDiff_OnMapStart();
}

public void OnIncludeBotsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    bool oldVal = StringToInt(oldValue) != 0;
    bool newVal = StringToInt(newValue) != 0;

    if (oldVal != newVal)
    {
        LogMessage("[Progress] gokz_progress_include_bots changed: %d -> %d", oldVal, newVal);

        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsClientInGame(i)) continue;

            if (IsFakeClient(i))
            {
                gProgressStatus[i] = newVal ? Progress_Running : Progress_None;
                gProgressValues[i] = 0.0;
            }
        }

        RebuildProgressClientList();
    }
    PrintToChatAll("[Progress] Bots %s ranking now.", newVal ? "included in" : "excluded from");
}

public void GOKZ_OnTimerStart_Post(int client, int course)
{
    if (!IsValidClient(client)) return;

    g_IsProcessing[client] = true;
    gProgressStatus[client] = Progress_Running;
    RebuildProgressClientList();

    TimeDiff_OnTimerStart_Post(client, course);
}

public void GOKZ_OnPause_Post(int client)
{
    TimeDiff_OnPause_Post(client);                // <— pause (stop) timer
}

public void GOKZ_OnResume_Post(int client)
{
    TimeDiff_OnResume_Post(client);               // <— resume (start) timer if enabled
}

public void GOKZ_OnTimerStopped(int client)
{
    if (!IsValidClient(client)) return;

    g_IsProcessing[client] = false;
    if (gProgressStatus[client] == Progress_Running)
        gProgressStatus[client] = Progress_DNF;

    RebuildProgressClientList();

    TimeDiff_OnTimerStopped(client);
}

public void GOKZ_OnTimerEnd_Post(int client, int course)
{
    if (!IsValidClient(client)) return;

    g_IsProcessing[client] = false;
    gProgressStatus[client] = Progress_Finished;
    gProgressValues[client] = 1.0;

    int score = RoundToNearest(gProgressValues[client] * 1000.0);
    CS_SetClientContributionScore(client, score);
    RebuildProgressClientList();

    TimeDiff_OnTimerEnd_Post(client, course, /*time*/0.0, /*tps*/0); // params not used internally
}

public void OnClientDisconnect(int client)
{
    g_IsProcessing[client] = false;
    RebuildProgressClientList();
    TimeDiff_OnClientDisconnect(client); 
}

public void OnClientPutInServer(int client)
{
    if (!IsValidClient(client))
        return;

    if (IsFakeClient(client) && gCvarIncludeBots.BoolValue)
    {
        gProgressStatus[client] = Progress_Running;
        gProgressValues[client] = 0.0;
    }

    RebuildProgressClientList();
    TimeDiff_OnClientPutInServer(client);
}

/* ---------------Functions----------------*/

void RestartProgressUpdater()
{
    ResetProgressData();
    char path[256];
    gValidReplayAvailable = FindBestReplayFilePath(path, sizeof(path));

    if (!gValidReplayAvailable)
    {
        LogMessage("Skipping plugin — no valid replay available.");
        return;
    }

    ReadReplay(path);
    if (g_ProgressGlobalTimer != null && IsValidHandle(g_ProgressGlobalTimer))
    {
        KillTimer(g_ProgressGlobalTimer);
        g_ProgressGlobalTimer = null;
    }
    StartGlobalProgressUpdater();

    // Mark all bots as running if convar allows
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsFakeClient(i) && gCvarIncludeBots.BoolValue)
        {
            gProgressStatus[i] = Progress_Running;
        }
    }
    RebuildProgressClientList();
}

/* -------------------Commands--------------------- */

public Action Command_ToggleRank(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    char value[4];
    GetClientCookie(client, gRankDisplayCookie, value, sizeof(value));
    bool enabled = (StringToInt(value) == 0);  // If cookie not set or 0, toggle to 1 (enable)

    // store new state
    IntToString(enabled ? 1 : 0, value, sizeof(value));
    SetClientCookie(client, gRankDisplayCookie, value);

    GOKZ_PrintToChat(client, true, "Rank display %s", enabled ? "enabled" : "disabled");
    return Plugin_Handled;
}

public Action Command_ToggleProgress(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    char value[4];
    GetClientCookie(client, gProgressDisplayCookie, value, sizeof(value));
    bool enabled = (StringToInt(value) == 0);

    IntToString(enabled ? 1 : 0, value, sizeof(value));
    SetClientCookie(client, gProgressDisplayCookie, value);

    GOKZ_PrintToChat(client, true, "Progress display %s", enabled ? "enabled" : "disabled");
    return Plugin_Handled;
}

/* ---------------------------------------- */

void StartGlobalProgressUpdater()
{
    if (g_ProgressGlobalTimer != null && IsValidHandle(g_ProgressGlobalTimer))
        return;

    float interval = CalculateRefreshInterval();
    g_ProgressGlobalTimer = CreateTimer(interval, Timer_UpdateOnePlayerProgress, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void RebuildProgressClientList()
{
    g_ProgressClientCount = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;

        if (IsFakeClient(i)) {
            if (gCvarIncludeBots.BoolValue && gProgressStatus[i] == Progress_Running) {
                g_ProgressClients[g_ProgressClientCount++] = i;
            }
        } else {
            if (gProgressStatus[i] == Progress_Running) {
                g_ProgressClients[g_ProgressClientCount++] = i;
            }
        }
    }

    g_ProgressClientIndex = 0;
}

public Action Timer_UpdateOnePlayerProgress(Handle timer)
{
    if (g_ProgressClientCount == 0 || gTickPositions == null || gTickPositions.Length <= 0)
        return Plugin_Continue;

    int client = g_ProgressClients[g_ProgressClientIndex];

    if (IsClientInGame(client) && gProgressStatus[client] == Progress_Running && IsPlayerAlive(client))
    {
        GP_UpdateClientProgressAndScore(client);
    }

    g_ProgressClientIndex = (g_ProgressClientIndex + 1) % g_ProgressClientCount;
    return Plugin_Continue;
}

public int SortProgressDesc(int elem1, int elem2, const int[] array, Handle hndl)
{
    float a = gProgressValues[elem1];
    float b = gProgressValues[elem2];
    if (a > b) return -1;
    if (a < b) return 1;
    return 0;
}

public any Native_GetOnePlayerProgressStats(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    float progress = gProgressValues[client];

    int rank = 1;
    int total = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i)) continue;
        if (gProgressStatus[i] == Progress_None) continue;

        total++;
        if (i != client && gProgressValues[i] > progress)
            rank++;
    }

    SetNativeCellRef(2, progress);
    SetNativeCellRef(3, rank);
    SetNativeCellRef(4, total);
    return 0;
}

void ResetProgressData()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        gProgressStatus[i] = Progress_None;
        gProgressValues[i] = 0.0;
        g_IsProcessing[i] = false;
        // removed menu state resets & KillProgressMenuTimer
    }

    g_ProgressClientCount = 0;
    g_ProgressClientIndex = 0;

    if (gTickPositions != null)
    {
        gTickPositions.Clear();
    }
}

public any Native_GetProgressText(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    int bufferIndex = 2;
    int maxlen = GetNativeCell(3);

    if (!IsValidClient(client))
    {
        SetNativeString(bufferIndex, "", maxlen, true);
        return 0;
    }

    // read cookie
    bool showProgress = true;

    char value[4];
    GetClientCookie(client, gProgressDisplayCookie, value, sizeof(value));
    if (strlen(value) > 0) showProgress = StringToInt(value) != 0;

    float progress = gProgressValues[client];
    int rank = 1, total = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidClient(i)) continue;
        if (gProgressStatus[i] == Progress_None) continue;

        total++;
        if (i != client && gProgressValues[i] > progress)
            rank++;
    }

    char text[128];
    text[0] = '\0';

    // if (showRank)
    //     Format(text, sizeof(text), "Rank: %d / %d", rank, total);

    if (showProgress)
    {
        Format(text, sizeof(text), "%s%sProgress: %.1f%%%",
            text, (strlen(text) > 0 ? "\n" : ""), progress * 100.0);
    }

    SetNativeString(bufferIndex, text, maxlen, true);
    return 1;
}
