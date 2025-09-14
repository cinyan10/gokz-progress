#if defined _GOKZ_PROGRESS_TIMEDIFF_SP_
#endinput
#endif
#define _GOKZ_PROGRESS_TIMEDIFF_SP_

/**
 * Time-diff module for gokz-progress.
 * Shows player's time difference vs the replay every N seconds.
 *
 * Depends on:
 *  - gValidReplayAvailable (bool)
 *  - gProgressStatus[] (enum ProgressStatus)
 *  - IsValidClient(), GP_NearestTickToPos(), etc.
 *  - GOKZ_GetTime(client) from GOKZ/core
 *  - gTickPositions (ArrayList of float[3])
 */

ConVar gCvarTimeDiffInterval; // seconds, default 10.0

Cookie gTimeDiffCookie;       // "show_timediff" per player
bool   gTimeDiffEnabled[MAXPLAYERS + 1];
float  gTimeDiffAcc[MAXPLAYERS + 1];   // seconds accumulator per player

Handle gTimeDiffTimer = null;

static void TimeDiff_StartTimer()
{
    if (gTimeDiffTimer != null && IsValidHandle(gTimeDiffTimer))
        return;

    // 1-second heartbeat; we accumulate to respect dynamic interval changes.
    gTimeDiffTimer = CreateTimer(1.0, Timer_TimeDiffHeartbeat, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

static void TimeDiff_KillTimer()
{
    if (gTimeDiffTimer != null && IsValidHandle(gTimeDiffTimer))
    {
        KillTimer(gTimeDiffTimer);
        gTimeDiffTimer = null;
    }
}

public void TimeDiff_Init()
{
    // interval cvar (changeable later without recompile)
    gCvarTimeDiffInterval = CreateConVar(
        "gokz_progress_timediff_interval",
        "10.0",
        "Seconds between time-diff prints per player (vs replay).",
        FCVAR_NONE, true, 1.0, true, 120.0
    );

    // cookie
    gTimeDiffCookie = RegClientCookie("show_timediff", "Show periodic time difference vs replay", CookieAccess_Public);

    // start heartbeat
    TimeDiff_StartTimer();
}

public void TimeDiff_OnMapStart()
{
    // Reset per-player accumulators on new map
    for (int i = 1; i <= MaxClients; i++)
        gTimeDiffAcc[i] = 0.0;
}

public void TimeDiff_OnClientPutInServer(int client)
{
    if (!IsValidClient(client)) return;

    // Load cookie preference
    char v[4];
    GetClientCookie(client, gTimeDiffCookie, v, sizeof(v));
    if (strlen(v) == 0)
    {
        // default OFF
        gTimeDiffEnabled[client] = false;
    }
    else
    {
        gTimeDiffEnabled[client] = StringToInt(v) != 0;
    }

    gTimeDiffAcc[client] = 0.0;
}

public void TimeDiff_OnClientDisconnect(int client)
{
    gTimeDiffEnabled[client] = false;
    gTimeDiffAcc[client] = 0.0;
}

/**
 * sm_timediff — toggle per-player prints
 */
public Action Command_ToggleTimeDiff(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    gTimeDiffEnabled[client] = !gTimeDiffEnabled[client];

    char v[4];
    IntToString(gTimeDiffEnabled[client] ? 1 : 0, v, sizeof(v));
    SetClientCookie(client, gTimeDiffCookie, v);

    GOKZ_PrintToChat(client, true, "TimeDiff %s — showing comparison %s every %.0f s.",
        gTimeDiffEnabled[client] ? "enabled" : "disabled",
        gTimeDiffEnabled[client] ? "vs replay" : "off",
        gCvarTimeDiffInterval.FloatValue
    );

    // Reset their accumulator so it prints after a full interval
    gTimeDiffAcc[client] = 0.0;

    return Plugin_Handled;
}

/**
 * 1-second heartbeat that checks all players and prints when their
 * accumulator reaches the configured interval.
 */
public Action Timer_TimeDiffHeartbeat(Handle timer)
{
    // If timer was stopped or map ended, keep going harmlessly
    float interval = gCvarTimeDiffInterval.FloatValue;
    if (interval < 1.0) interval = 1.0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!gTimeDiffEnabled[client]) continue;
        if (!IsValidClient(client) || !IsClientInGame(client)) continue;

        // Only print while actually running
        // Progress_Running must be visible where this file is included
        if (gProgressStatus[client] != Progress_Running) {
            gTimeDiffAcc[client] = 0.0;
            continue;
        }

        // Need a valid replay route
        if (!gValidReplayAvailable || gTickPositions == null || gTickPositions.Length <= 0)
            continue;

        gTimeDiffAcc[client] += 1.0;
        if (gTimeDiffAcc[client] + 0.001 < interval) // small epsilon
            continue;

        gTimeDiffAcc[client] = 0.0;

        // Compute nearest tick to client
        float pos[3];
        GetClientAbsOrigin(client, pos);
        int tick = GP_NearestTickToPos(pos);
        if (tick < 0) continue;

        // Convert tick to replay time using (tick - 256) / 128
        float replayTime = float(tick - 256) / 128.0;
        if (replayTime < 0.0) replayTime = 0.0;

        // Player current run time
        float playerTime = GOKZ_GetTime(client);

        float diff = playerTime - replayTime; // positive = behind; negative = ahead

        // Format like +0.54s or -5.32s
        char sign[2];
        sign[0] = (diff >= 0.0) ? '+' : '-';
        sign[1] = '\0';

        float mag = FloatAbs(diff);

        // Optional label
        const char[] hint = (diff >= 0.0) ? "(behind)" : "(ahead)";

        GOKZ_PrintToChat(client, true, "Δt: %s%.2fs %s", sign, mag, hint);
    }

    return Plugin_Continue;
}
