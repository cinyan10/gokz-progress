#include <sourcemod>
#include <sdktools>
#include <gokz/core>
#include <cstrike>
#include <clientprefs>

#include "gokz-progress/replay.sp"
#include "gokz-progress/utils.sp"

#pragma semicolon 1
#pragma newdecls required

ConVar gCvarIncludeBots;

bool gMenuOpen[MAXPLAYERS + 1];
Handle gProgressMenus[MAXPLAYERS + 1];
Handle gProgressMenuTimers[MAXPLAYERS + 1];
float gProgressValues[MAXPLAYERS + 1];
bool gValidReplayAvailable = true;

// State
int g_ProgressClients[MAXPLAYERS + 1];
int g_ProgressClientCount = 0;
int g_ProgressClientIndex = 0;
Handle g_ProgressGlobalTimer = null;
bool g_IsProcessing[MAXPLAYERS + 1];

Cookie gRankDisplayCookie;
Cookie gProgressDisplayCookie;

enum ProgressStatus
{
    Progress_None = 0,   // 未开始
    Progress_Running,    // 正在进行中
    Progress_DNF,        // 中途放弃
    Progress_Finished    // 结束，100%
};

ProgressStatus gProgressStatus[MAXPLAYERS + 1];

public Plugin myinfo = 
{
    name = "gokz-progress",
    author = "Cinyan10",
    description = "show player's progress of current map",
    version = "1.0"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("GetOnePlayerProgressStats", Native_GetOnePlayerProgressStats);
    CreateNative("GetProgressText", Native_GetProgressText);
    RegPluginLibrary("gokz_progress");
    return APLRes_Success;
}

public void OnPluginStart()
{
    gCvarIncludeBots = CreateConVar("gokz_progress_include_bots", "0", "Include bots in ranking", FCVAR_NONE, true, 0.0, true, 1.0);
    HookConVarChange(gCvarIncludeBots, OnIncludeBotsChanged);
    RegConsoleCmd("sm_rank", Command_ToggleRank);
    RegConsoleCmd("sm_progress", Command_ToggleProgress);  // 已使用 sm_progress 显示菜单的话改名 sm_progress_pref
    RegConsoleCmd("sm_progressmenu", Cmd_ShowProgress);
    gRankDisplayCookie = RegClientCookie("show_rank", "Show rank in progress menu", CookieAccess_Public);
    gProgressDisplayCookie = RegClientCookie("show_progress", "Show progress in progress menu", CookieAccess_Public);
    gTickPositions = new ArrayList(3);
}

public void OnIncludeBotsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    bool oldVal = StringToInt(oldValue) != 0;
    bool newVal = StringToInt(newValue) != 0;

    if (oldVal != newVal)
    {
        LogMessage("[Progress] gokz_progress_include_bots changed: %d -> %d", oldVal, newVal);

        // 更新所有状态
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
}

public void GOKZ_OnTimerStopped(int client)
{
    if (!IsValidClient(client)) return;

    g_IsProcessing[client] = false;
    if (gProgressStatus[client] == Progress_Running)
        gProgressStatus[client] = Progress_DNF;

    RebuildProgressClientList();
}

public void GOKZ_OnTimerEnd_Post(int client, int course)
{
    if (!IsValidClient(client)) return;

    g_IsProcessing[client] = false;
    gProgressStatus[client] = Progress_Finished;
    gProgressValues[client] = 1.0; // 强制100%

    int score = RoundToNearest(gProgressValues[client] * 100.0);
    CS_SetClientContributionScore(client, score);
    RebuildProgressClientList();
}

public void OnMapStart()
{
    ResetProgressData();
    char path[256];
    gValidReplayAvailable = FindBestReplayFilePath(path, sizeof(path));

    if (!gValidReplayAvailable)
    {
        LogMessage(" Skipping plugin — no valid replay available.");
        return;
    }

    ReadReplay(path);
    LogMessage(" Loaded %d ticks from %s", gTickPositions.Length, path);

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


public void OnPlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (!IsValidClient(client)) return;
    CreateTimer(0.2, Timer_ShowMenuHeader, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientDisconnect(int client)
{
    g_IsProcessing[client] = false;
    RebuildProgressClientList();
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
}


/* -------------------Commands--------------------- */

public Action Command_ToggleRank(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    char value[4];
    GetClientCookie(client, gRankDisplayCookie, value, sizeof(value));
    bool enabled = (StringToInt(value) == 0);  // 默认关闭，点击后启用

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

public Action Cmd_ShowProgress(int client, int args)
{
    if (!gValidReplayAvailable) return Plugin_Handled;
    if (!IsClientInGame(client)) return Plugin_Handled;

    if (g_ProgressClientCount == 0)
    {
        PrintToChat(client, " No Players in the ranking pool now");
        return Plugin_Handled;
    }

    if (gMenuOpen[client])
    {
        // Toggle off
        KillProgressMenuTimer(client);
        gMenuOpen[client] = false;
    }
    else
    {
        // Toggle on
        KillProgressMenuTimer(client); // Ensure stale timer cleared
        gProgressMenuTimers[client] = CreateTimer(0.1, Timer_UpdateProgressMenu, GetClientUserId(client), TIMER_REPEAT);
        gMenuOpen[client] = true;
    }

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
        float pos[3];
        GetClientAbsOrigin(client, pos);

        int nearestTick = -1;
        float nearestDist = -1.0, tickPos[3];

        for (int i = 0; i < gTickPositions.Length; i++) {
            gTickPositions.GetArray(i, tickPos, 3);
            float dist = GetVectorDistance(pos, tickPos);
            if (nearestTick == -1 || dist < nearestDist) {
                nearestTick = i;
                nearestDist = dist;
            }
        }

        gProgressValues[client] = float(nearestTick) / float(gTickPositions.Length);
        int score = RoundToNearest(gProgressValues[client] * 100.0);
        CS_SetClientContributionScore(client, score);
    }

    g_ProgressClientIndex = (g_ProgressClientIndex + 1) % g_ProgressClientCount;
    return Plugin_Continue;
}

public Action Timer_ShowMenuHeader(Handle timer, any userid)
{
    if (!gValidReplayAvailable) return Plugin_Stop;

    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client) || !IsPlayerAlive(client)) return Plugin_Continue;

    if (gTickPositions.Length <= 0) return Plugin_Stop;

    float clientPos[3];
    GetClientAbsOrigin(client, clientPos);

    int nearestTick = -1;
    float nearestDist = -1.0, tickPos[3];
    for (int i = 0; i < gTickPositions.Length; i++) {
        gTickPositions.GetArray(i, tickPos, 3);
        float dist = GetVectorDistance(clientPos, tickPos);
        if (nearestTick == -1 || dist < nearestDist) {
            nearestTick = i;
            nearestDist = dist;
        }
    }

    float progress = float(nearestTick) / float(gTickPositions.Length);

    float clientProgress[MAXPLAYERS + 1];
    int validPlayers[MAXPLAYERS + 1];
    int total = 0, rank = 1;
    bool includeBots = gCvarIncludeBots.BoolValue;

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsValidClient(i)) continue;
        if (!includeBots && IsFakeClient(i)) continue;

        float pos[3];
        GetClientAbsOrigin(i, pos);

        int nearest = -1;
        float minDist = -1.0;
        for (int j = 0; j < gTickPositions.Length; j++) {
            gTickPositions.GetArray(j, tickPos, 3);
            float dist = GetVectorDistance(pos, tickPos);
            if (nearest == -1 || dist < minDist) {
                nearest = j;
                minDist = dist;
            }
        }

        float prog = float(nearest) / float(gTickPositions.Length);
        clientProgress[i] = prog;
        validPlayers[total++] = i;

        if (i != client && prog > progress)
            rank++;
    }

    SortCustom1D(validPlayers, total, SortProgressDesc);

    char buffer[1024];
    Format(buffer, sizeof(buffer), "\nProgress: %.1f% Rank: %d / %d\n", progress * 100.0, rank, total);

    int idx = -1;
    for (int i = 0; i < total; i++) {
        if (validPlayers[i] == client) {
            idx = i;
            break;
        }
    }

    for (int i = idx - 3; i <= idx + 3; i++) {
        if (i < 0 || i >= total) continue;

        char name[64];
        GetClientName(validPlayers[i], name, sizeof(name));
        Format(buffer, sizeof(buffer), "%s%s%d. %s %.1f%%\n", buffer, (validPlayers[i] == client ? "-> " : ""), i + 1, name, clientProgress[validPlayers[i]] * 100.0);
    }

    if (gProgressMenus[client] != null && IsValidHandle(gProgressMenus[client]))
    {
        SetMenuTitle(gProgressMenus[client], buffer);
    }
    return Plugin_Continue;
}


public Action Timer_UpdateProgressMenu(Handle timer, any userid)
{
    if (!gValidReplayAvailable) return Plugin_Stop;

    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client)) return Plugin_Stop;

    bool includeBots = gCvarIncludeBots.BoolValue;

    int players[MAXPLAYERS + 1];
    int count = 0, rank = 1;
    float myProgress = gProgressValues[client];

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsValidClient(i)) continue;
        if (!includeBots && IsFakeClient(i)) continue;
        if (gProgressStatus[i] == Progress_None) continue;

        players[count++] = i;
        if (i != client && gProgressValues[i] > myProgress) rank++;
    }

    // Sort players by progress descending
    for (int i = 0; i < count - 1; i++) {
        for (int j = 0; j < count - i - 1; j++) {
            if (gProgressValues[players[j]] < gProgressValues[players[j + 1]]) {
                int temp = players[j];
                players[j] = players[j + 1];
                players[j + 1] = temp;
            }
        }
    }

    // Find my index
    int myIndex = -1;
    for (int i = 0; i < count; i++) {
        if (players[i] == client) {
            myIndex = i;
            break;
        }
    }

    // Prepare display list
    int titleList[10];
    int titleCount = 0;

    for (int i = 0; i < 2 && i < count; i++) titleList[titleCount++] = players[i];
    for (int i = myIndex - 2; i < myIndex; i++) {
        if (i >= 2 && i < count && !IsInArray(players[i], titleList, titleCount))
            titleList[titleCount++] = players[i];
    }
    if (!IsInArray(client, titleList, titleCount))
        titleList[titleCount++] = client;
    for (int i = myIndex + 1; i <= myIndex + 2 && i < count; i++) {
        if (!IsInArray(players[i], titleList, titleCount))
            titleList[titleCount++] = players[i];
    }
    for (int i = count - 2; i < count; i++) {
        if (i >= 0 && i < count && !IsInArray(players[i], titleList, titleCount))
            titleList[titleCount++] = players[i];
    }

    // Build menu string
    char title[1024];
    Format(title, sizeof(title), "Progress: %.1f%% Rank: %d / %d\n", myProgress * 100.0, rank, count);

    for (int i = 0; i < count; i++) {
        int target = players[i];
        char name[64], state[8] = "", marker[8] = "";
        GetClientName(target, name, sizeof(name));

        switch (gProgressStatus[target])
        {
            case Progress_DNF:
            {
                strcopy(state, sizeof(state), "DNF");
            }
            case Progress_Finished:
            {
                strcopy(state, sizeof(state), "✓");
            }
            default:
            {
                strcopy(state, sizeof(state), "");
            }
        }

        if (target == client) 
        {
            strcopy(marker, sizeof(marker), "-> ");
        }

        Format(title, sizeof(title), "%s%s%2d. %-20s %5.1f%% %s\n",
            title, marker, i + 1, name, gProgressValues[target] * 100.0, state);
    }

    Menu menu = new Menu(MenuCloseHandler);
    menu.SetTitle(title);
    menu.AddItem(" ", " ");
    menu.ExitButton = true;
    menu.Display(client, 10);
    gProgressMenus[client] = menu;
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

public int MenuCloseHandler(Menu menu, MenuAction action, int client, int param)
{
    if (action == MenuAction_End)
    {
        if (client > 0 && client <= MaxClients && IsClientInGame(client)) {
            KillProgressMenuTimer(client);
        }
    }
    return 0;
}

void KillProgressMenuTimer(int client)
{
    if (gProgressMenuTimers[client] != null && IsValidHandle(gProgressMenuTimers[client]))
    {
        KillTimer(gProgressMenuTimers[client]);
        gProgressMenuTimers[client] = null;
    }

    if (gProgressMenus[client] != null && IsValidHandle(gProgressMenus[client]))
    {
        delete gProgressMenus[client];
        gProgressMenus[client] = null;
    }

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
        gMenuOpen[i] = false;
        KillProgressMenuTimer(i);
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

    // 读取 cookie
    bool showRank = true;
    bool showProgress = true;

    char value[4];
    GetClientCookie(client, gRankDisplayCookie, value, sizeof(value));
    if (strlen(value) > 0) showRank = StringToInt(value) != 0;

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

    if (showRank)
        Format(text, sizeof(text), "Rank: %d / %d", rank, total);

    if (showProgress)
    {
        Format(text, sizeof(text), "%s%sProgress: %.1f%%%%",  // ← 双重转义！
            text, (strlen(text) > 0 ? "\n" : ""), progress * 100.0);
    }
    SetNativeString(bufferIndex, text, maxlen, true);
    return 1;
}
