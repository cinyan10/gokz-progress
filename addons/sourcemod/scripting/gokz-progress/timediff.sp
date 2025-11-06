#if defined _GOKZ_PROGRESS_TIMEDIFF_SP_
#endinput
#endif
#define _GOKZ_PROGRESS_TIMEDIFF_SP_

/**
 * Per-player Time-diff module for gokz-progress.
 * Caches each player's own PB replay route per map (on map start), and refreshes the cache
 * when they beat their PB (via GOKZ_LR_OnTimeProcessed).
 *
 * Interval is a per-player clientpref:
 *   - "!timediff" toggles on/off
 *   - "!timediff 10" sets a 10s fixed interval and enables
 *   - "!timediff 1/10" sets a dynamic interval equal to (PB / 10) and enables
 * Default interval (if unset) is 1/20 of PB. Until PB is known, we use a 3.0s fallback.
 */

// ===================[ COOKIES / STATE ]=================

Cookie gTimeDiffCookie;                // show/hide toggle
Cookie gTDIntervalCookie;              // "timediff_interval" -> "10" or "1/20"

bool   gTimeDiffEnabled[MAXPLAYERS + 1];
float  gTimeDiffAcc[MAXPLAYERS + 1];   // seconds accumulator per player
Handle gTimeDiffClientTimer[MAXPLAYERS + 1]; // per-player 1s heartbeat

// per-player PB route + readiness
ArrayList gTimeDiffRoute[MAXPLAYERS + 1];
bool      gTimeDiffRouteReady[MAXPLAYERS + 1];

// per-player PB time (same unit used from DB; assumed seconds; adjust if your DB is ms)
float     gTimeDiffPBTime[MAXPLAYERS + 1]; // player's current PB time for this map/course/mode

// per-player interval preference
bool   gTDPrefIsFrac[MAXPLAYERS + 1];  // true -> "1/N", false -> fixed seconds
float  gTDPrefValue[MAXPLAYERS + 1];   // if frac: denominator N; if fixed: seconds S

// ===================[ SQL STRINGS ]=====================

static const char sql_mapcourses_getid[] =
    "SELECT MapCourseID \
     FROM MapCourses \
     WHERE MapID = %d AND Course = %d \
     LIMIT 1";

static const char sql_times_getpb_nub[] =
    "SELECT RunTime, Teleports, TimeGUID \
     FROM Times \
     WHERE SteamID32 = %d AND MapCourseID = %d AND Mode = %d \
     ORDER BY RunTime ASC \
     LIMIT 10";

// ===================[ INTERNAL HELPERS ]================

static void TimeDiff_StopClientTimer(int client)
{
    if (gTimeDiffClientTimer[client] != null && IsValidHandle(gTimeDiffClientTimer[client]))
    {
        KillTimer(gTimeDiffClientTimer[client]);
    }
    gTimeDiffClientTimer[client] = null;
    gTimeDiffAcc[client] = 0.0;
}

static void TimeDiff_StartClientTimer(int client)
{
    TimeDiff_StopClientTimer(client); // ensure clean state
    gTimeDiffAcc[client] = 0.0;
    // 1-second heartbeat; let it die naturally on map change
    gTimeDiffClientTimer[client] = CreateTimer(1.0, Timer_TimeDiffClient, GetClientUserId(client), TIMER_REPEAT);
}

static void TD_FormatReplayPath(const char[] guid, char[] outPath, int maxlen)
{
    // addons/sourcemod/data/gokz-replays/_runs/<TimeGUID>.replay
    Format(outPath, maxlen, "addons/sourcemod/data/gokz-replays/_runs/%s.replay", guid);
}

// Bridge parser: copy from global gTickPositions into a per-player ArrayList after ReadReplay()
static bool TD_ReadReplayInto(const char[] path, ArrayList dest)
{
    // Check replay size limit before loading
    int tickCount;
    ReadReplayHeader(path, tickCount);
    
    if (tickCount <= 0)
    {
        LogMessage("[TimeDiff] Invalid replay file: %s (tickCount: %d)", path, tickCount);
        return false;
    }
    
    // Check replay size limit (convert minutes to ticks at 128 tickrate)
    int maxTicks = RoundToFloor(gCvarMaxReplayTime.FloatValue * 60.0 * 128.0);
    if (tickCount > maxTicks)
    {
        LogMessage("[TimeDiff] Replay too large: %s (tickCount: %d, max: %d ticks / %.1f minutes)", 
            path, tickCount, maxTicks, gCvarMaxReplayTime.FloatValue);
        return false;
    }
    
    ReadReplay(path); // fills global gTickPositions
    if (gTickPositions == null || gTickPositions.Length <= 0)
        return false;

    dest.Clear();
    float pos[3];
    for (int i = 0; i < gTickPositions.Length; i++)
    {
        gTickPositions.GetArray(i, pos, 3);
        dest.PushArray(pos, 3);
    }
    return dest.Length > 0;
}

static int TD_NearestTickToPosIn(ArrayList route, const float pos[3])
{
    if (route == null) return -1;

    int len = route.Length;
    // Require enough ticks to have head/tail trimmed
    if (len <= 512) return -1;

    int start = 256;
    int end   = len - 256; // exclusive upper bound

    float tickPos[3];
    int nearest = -1;
    float best = 0.0;

    for (int i = start; i < end; i++)
    {
        route.GetArray(i, tickPos, 3);
        float d = GetVectorDistance(pos, tickPos);
        if (nearest == -1 || d < best)
        {
            nearest = i;
            best = d;
        }
    }
    return nearest;
}
// --- Interval prefs ---

static void TD_SetDefaultIntervalPref(int client)
{
    // default = 1/20 of PB
    gTDPrefIsFrac[client] = true;
    gTDPrefValue[client]  = 6.0;
}

static void TD_LoadIntervalCookie(int client)
{
    TD_SetDefaultIntervalPref(client);

    char buf[32];
    GetClientCookie(client, gTDIntervalCookie, buf, sizeof(buf));
    if (buf[0] == '\0')
        return;

    // parse "1/N" or plain seconds
    int slash = FindCharInString(buf, '/');
    if (slash > 0)
    {
        // fraction — we only accept "1/N"
        char left[8], right[16];
        strcopy(left, sizeof(left), buf);
        left[slash] = '\0'; // terminate "1"
        strcopy(right, sizeof(right), buf[slash + 1]); // N

        int num = StringToInt(left);
        int den = StringToInt(right);
        if (num == 1 && den > 0)
        {
            gTDPrefIsFrac[client] = true;
            gTDPrefValue[client]  = float(den);
        }
    }
    else
    {
        // seconds
        float secs = StringToFloat(buf);
        if (secs > 0.0)
        {
            gTDPrefIsFrac[client] = false;
            gTDPrefValue[client]  = secs;
        }
    }
}

static void TD_SaveIntervalCookie(int client)
{
    char buf[32];
    if (gTDPrefIsFrac[client])
    {
        Format(buf, sizeof(buf), "1/%d", RoundToFloor(gTDPrefValue[client]));
    }
    else
    {
        // store with up to 2 decimals for cleanliness
        Format(buf, sizeof(buf), "%.2f", gTDPrefValue[client]);
        TrimString(buf);
    }
    SetClientCookie(client, gTDIntervalCookie, buf);
}

static float TD_GetEffectiveInterval(int client)
{
    // If fixed seconds:
    if (!gTDPrefIsFrac[client])
    {
        float s = gTDPrefValue[client];
        if (s < 0.5) s = 0.5;
        if (s > 120.0) s = 120.0;
        return s;
    }

    // Fraction of PB time (PB / denominator)
    const float FALLBACK = 3.0; // until PB time is known
    float denom = (gTDPrefValue[client] > 0.0) ? gTDPrefValue[client] : 20.0;
    float base  = (gTimeDiffPBTime[client] > 0.0) ? gTimeDiffPBTime[client] : FALLBACK;

    float s = base / denom;
    if (s < 0.5) s = 0.5;
    if (s > 120.0) s = 120.0;
    return s;
}

// ===================[ PUBLIC INIT / MAP / CLIENT ]=====

public void TimeDiff_Init()
{
    gTimeDiffCookie   = RegClientCookie("show_timediff", "Show periodic time difference vs replay", CookieAccess_Public);
    gTDIntervalCookie = RegClientCookie("timediff_interval", "Interval for time-diff: seconds or 1/N of PB", CookieAccess_Public);

    for (int i = 1; i <= MaxClients; i++)
    {
        gTimeDiffEnabled[i] = false;
        gTimeDiffAcc[i] = 0.0;
        gTimeDiffClientTimer[i] = null;

        gTimeDiffRoute[i] = null;
        gTimeDiffRouteReady[i] = false;

        gTimeDiffPBTime[i] = 0.0;
        TD_SetDefaultIntervalPref(i);
    }
}

public void TimeDiff_OnMapStart()
{
    // reset timers/state
    for (int i = 1; i <= MaxClients; i++)
    {
        TimeDiff_StopClientTimer(i);

        if (IsClientInGame(i))
        {
            // enable/disable
            char v[4];
            GetClientCookie(i, gTimeDiffCookie, v, sizeof(v));
            gTimeDiffEnabled[i] = (strlen(v) > 0) ? (StringToInt(v) != 0) : false;

            // load interval pref
            TD_LoadIntervalCookie(i);
        }
        else
        {
            gTimeDiffEnabled[i] = false;
            TD_SetDefaultIntervalPref(i);
        }

        if (gTimeDiffRoute[i] != null) { delete gTimeDiffRoute[i]; gTimeDiffRoute[i] = null; }
        gTimeDiffRouteReady[i] = false;
        gTimeDiffPBTime[i] = 0.0;
    }

    // cache players' PB routes for the current map (course 0 by default) at map start
    int mapID = GOKZ_DB_GetCurrentMapID();
    if (mapID <= 0) return;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsValidClient(client) || !IsClientInGame(client)) continue;

        int mode = view_as<int>(GOKZ_GetCoreOption(client, Option_Mode));
        TD_LoadPBRouteForClient(client, /*course*/0, mode);
    }
}

public void TimeDiff_OnClientPutInServer(int client)
{
    if (!IsValidClient(client)) return;

    // enable/disable
    char v[4];
    GetClientCookie(client, gTimeDiffCookie, v, sizeof(v));
    gTimeDiffEnabled[client] = (strlen(v) > 0) ? (StringToInt(v) != 0) : false;

    // interval pref
    TD_LoadIntervalCookie(client);

    gTimeDiffAcc[client] = 0.0;
    TimeDiff_StopClientTimer(client);

    if (gTimeDiffRoute[client] != null) { delete gTimeDiffRoute[client]; gTimeDiffRoute[client] = null; }
    gTimeDiffRouteReady[client] = false;
    gTimeDiffPBTime[client] = 0.0;

    // If they connect after map start, also cache their current PB for this map (course 0)
    int mapID = GOKZ_DB_GetCurrentMapID();
    if (mapID > 0)
    {
        int mode = view_as<int>(GOKZ_GetCoreOption(client, Option_Mode));
        TD_LoadPBRouteForClient(client, /*course*/0, mode);
    }
}

public void TimeDiff_OnClientDisconnect(int client)
{
    gTimeDiffEnabled[client] = false;
    TimeDiff_StopClientTimer(client);

    if (gTimeDiffRoute[client] != null) { delete gTimeDiffRoute[client]; gTimeDiffRoute[client] = null; }
    gTimeDiffRouteReady[client] = false;
    gTimeDiffPBTime[client] = 0.0;
    TD_SetDefaultIntervalPref(client);
}

// ===================[ COMMAND ]=========================
//
// Usage:
//   !timediff              -> toggle on/off
//   !timediff 10           -> set 10s fixed interval and enable
//   !timediff 1/20         -> set PB/20 dynamic interval and enable
//
public Action Command_ToggleTimeDiff(int client, int args)
{
    if (!IsValidClient(client)) return Plugin_Handled;

    if (args == 0)
    {
        gTimeDiffEnabled[client] = !gTimeDiffEnabled[client];

        char v[4];
        IntToString(gTimeDiffEnabled[client] ? 1 : 0, v, sizeof(v));
        SetClientCookie(client, gTimeDiffCookie, v);

        float eff = TD_GetEffectiveInterval(client);
        GOKZ_PrintToChat(client, true, "TimeDiff %s — every %.2fs while running.",
            gTimeDiffEnabled[client] ? "enabled" : "disabled", eff);

        if (gTimeDiffEnabled[client] && IsClientInGame(client))
            TimeDiff_StartClientTimer(client);
        else
            TimeDiff_StopClientTimer(client);

        return Plugin_Handled;
    }

    // args >= 1 : parse interval argument
    char arg[32];
    GetCmdArg(1, arg, sizeof(arg));

    bool ok = false;

    int slash = FindCharInString(arg, '/');
    if (slash > 0)
    {
        // expect "1/N"
        char left[8], right[16];
        strcopy(left, sizeof(left), arg);
        left[slash] = '\0';
        strcopy(right, sizeof(right), arg[slash + 1]);

        int num = StringToInt(left);
        int den = StringToInt(right);

        if (num == 1 && den > 0)
        {
            gTDPrefIsFrac[client] = true;
            gTDPrefValue[client]  = float(den);
            ok = true;
        }
    }
    else
    {
        // seconds
        float secs = StringToFloat(arg);
        if (secs > 0.0)
        {
            gTDPrefIsFrac[client] = false;
            gTDPrefValue[client]  = secs;
            ok = true;
        }
    }

    if (!ok)
    {
        GOKZ_PrintToChat(client, true, "Usage: !timediff [seconds|1/N]. Examples: !timediff 10  or  !timediff 1/20");
        return Plugin_Handled;
    }

    TD_SaveIntervalCookie(client);

    gTimeDiffEnabled[client] = true;
    SetClientCookie(client, gTimeDiffCookie, "1");

    float eff = TD_GetEffectiveInterval(client);
    GOKZ_PrintToChat(client, true, "TimeDiff enabled — interval set to %.2fs.", eff);

    if (IsClientInGame(client))
        TimeDiff_StartClientTimer(client);

    return Plugin_Handled;
}

// ===================[ LIFECYCLE HOOKS ]================

public void TimeDiff_OnTimerStart_Post(int client, int course)
{
    if (!IsValidClient(client)) return;
    gTimeDiffAcc[client] = 0.0;

    if (gTimeDiffEnabled[client])
    {
        TimeDiff_StartClientTimer(client);
    }
}

public void TimeDiff_OnPause_Post(int client)
{
    if (!IsValidClient(client)) return;
    TimeDiff_StopClientTimer(client);
}

public void TimeDiff_OnResume_Post(int client)
{
    if (!IsValidClient(client)) return;
    if (gTimeDiffEnabled[client])
    {
        TimeDiff_StartClientTimer(client);
    }
}

public void TimeDiff_OnTimerEnd_Post(int client, int course, float time, int teleportsUsed)
{
    if (!IsValidClient(client)) return;
    TimeDiff_StopClientTimer(client);
}

public void TimeDiff_OnTimerStopped(int client)
{
    if (!IsValidClient(client)) return;
    TimeDiff_StopClientTimer(client);
}

public Action TD_TimerPBRefresh(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client) || !IsClientInGame(client))
        return Plugin_Stop;

    // Use current options at refresh time
    int mode   = view_as<int>(GOKZ_GetCoreOption(client, Option_Mode));
    int course = 0; // adjust if you support multi-course

    TD_LoadPBRouteForClient(client, course, mode);
    LogMessage("[TimeDiff] (DelayedRefresh) PB route reloaded for client=%d (course=%d, mode=%d)", client, course, mode);
    return Plugin_Stop;
}

// ===== Update cache when a player beats their PB on this map/course/mode =====

public void GOKZ_LR_OnTimeProcessed(
    int client,
    int steamID,
    int mapID,
    int course,
    int mode,
    int style,
    float runTime,
    int teleportsUsed,
    bool firstTime,
    float pbDiff,
    int rank,
    int maxRank,
    bool firstTimePro,
    float pbDiffPro,
    int rankPro,
    int maxRankPro)
{
    if (!IsValidClient(client) || !IsClientInGame(client)) 
    {
        LogMessage("[TimeDiff] Ignored invalid/not-in-game client %d", client);
        return;
    }

    LogMessage("[TimeDiff] OnTimeProcessed fired for client=%d steamID=%d mapID=%d course=%d mode=%d style=%d runtime=%.3f", 
        client, steamID, mapID, course, mode, style, runTime);

    // If they set ANY new PB (nub or pro), refresh cache
    bool beatNub = (firstTime || pbDiff < 0.0);
    bool beatPro = (firstTimePro || pbDiffPro < 0.0);

    if (beatNub || beatPro)
    {
        LogMessage("[TimeDiff] Scheduling PB route refresh in 2.0s for client=%d (course=%d, mode=%d)",
            client, course, mode);

        // Fire once after 2 seconds; prevent firing after a map change
        CreateTimer(2.0, TD_TimerPBRefresh, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
    }

}

// ===================[ HEARTBEAT ]=======================

public Action Timer_TimeDiffClient(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (!IsValidClient(client) || !IsClientInGame(client))
        return Plugin_Stop; // kill this timer

    float interval = TD_GetEffectiveInterval(client);
    if (interval < 0.5) interval = 0.5;

    gTimeDiffAcc[client] += 1.0;
    if (gTimeDiffAcc[client] + 0.001 < interval)
        return Plugin_Continue;

    gTimeDiffAcc[client] = 0.0;

    if (!gTimeDiffRouteReady[client] || gTimeDiffRoute[client] == null || gTimeDiffRoute[client].Length <= 0)
        return Plugin_Continue;

    // Compute nearest tick to client using their own PB route
    float pos[3];
    GetClientAbsOrigin(client, pos);
    int tick = TD_NearestTickToPosIn(gTimeDiffRoute[client], pos);
    if (tick < 0) return Plugin_Continue;

    // Convert tick to replay time using (tick - 256) / 128
    float replayTime = tick / 128.0;
    if (replayTime < 0.0) replayTime = 0.0;

    // Player current run time
    float playerTime = GOKZ_GetTime(client);

    float diff = playerTime - replayTime; // + behind, − ahead

    float mag = FloatAbs(diff);

    char sign[2];
    sign[0] = (diff >= 0.0) ? '+' : '-';
    sign[1] = '\0';

    if (diff < 0.0)
    {
        GOKZ_PrintToChat(client, true, "You are now ahead by {green}%s%.2fs", sign, mag);
    }
    else if (diff > 0.0)
    {
        GOKZ_PrintToChat(client, true, "You are now behind by {red}%s%.2fs", sign, mag);
    }
    else
    {
        GOKZ_PrintToChat(client, true, "You are now even with your PB");
    }

    return Plugin_Continue;
}

// ===================[ SQL PIPELINE ]====================
// 1) MapID + course -> MapCourseID
// 2) fetch PBs (NUB+PRO in one query via Teleports field), choose fastest with existing file,
//    parse into per-player route, cache in gTimeDiffRoute[client], and store PB time.

static void TD_LoadPBRouteForClient(int client, int course, int mode)
{
    if (!IsValidClient(client)) return;

    int steam32 = GetSteamAccountID(client);
    if (steam32 <= 0) return;

    int mapID = GOKZ_DB_GetCurrentMapID();
    if (mapID <= 0) return;

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client)); // 0

    Transaction txn = SQL_CreateTransaction();

    char q[256];
    FormatEx(q, sizeof(q), sql_mapcourses_getid, mapID, course);
    txn.AddQuery(q);

    Database db = TD_GetDB();
    if (db == null) { delete txn; delete pack; return; }
    SQL_ExecuteTransaction(db, txn, TD_TxnSuccess_MapCourseReady, TD_TxnFailure_Log, pack, DBPrio_Low);
}

public void TD_TxnSuccess_MapCourseReady(Handle db, DataPack data, int numQueries, Handle[] results, any[] queryData)
{
    data.Reset();
    int client = GetClientOfUserId(data.ReadCell());
    delete data;

    if (!IsValidClient(client)) return;

    if (!SQL_FetchRow(results[0]))
    {
        return; // no MapCourseID
    }

    int mapCourseID = SQL_FetchInt(results[0], 0);

    // Need steam32 and mode again at this point
    int steam32 = GetSteamAccountID(client);
    if (steam32 <= 0) return;
    int mode = view_as<int>(GOKZ_GetCoreOption(client, Option_Mode));

    DataPack pack2 = new DataPack();
    pack2.WriteCell(GetClientUserId(client));

    Transaction txn = SQL_CreateTransaction();

    char q[256];
    FormatEx(q, sizeof(q), sql_times_getpb_nub, steam32, mapCourseID, mode);
    txn.AddQuery(q);

    SQL_ExecuteTransaction(db, txn, TD_TxnSuccess_PBsReady, TD_TxnFailure_Log, pack2, DBPrio_Low);
}

public void TD_TxnSuccess_PBsReady(Handle db, DataPack data, int numQueries, Handle[] results, any[] queryData)
{
    data.Reset();
    int client = GetClientOfUserId(data.ReadCell());
    delete data;

    if (!IsValidClient(client)) return;

    char guid[256];
    char bestPath[PLATFORM_MAX_PATH];
    bool haveBest = false;
    float bestTimeDummy = 0.0; // kept only for tie-breaker logic vs PRO
    bool bestIsPro = false;    // tie-breaker: prefer PRO (0 TP)

    // Choose fastest existing replay file from mixed NUB/PRO rows.
    while (SQL_FetchRow(results[0]))
    {
        int runTime    = SQL_FetchInt(results[0], 0);   // DB units might be ms; we won't use it for PB length
        int teleports  = SQL_FetchInt(results[0], 1);
        SQL_FetchString(results[0], 2, guid, sizeof(guid));

        char path[PLATFORM_MAX_PATH];
        TD_FormatReplayPath(guid, path, sizeof(path));
        if (!FileExists(path))
            continue;

        // For selection only: use a float made from DB runtime but don't trust its unit for PB length.
        float selectTime = float(runTime);
        bool  isPro      = (teleports == 0);

        if (!haveBest
            || selectTime < bestTimeDummy
            || (FloatAbs(selectTime - bestTimeDummy) < 0.001 && isPro && !bestIsPro))
        {
            haveBest      = true;
            bestTimeDummy = selectTime;
            bestIsPro     = isPro;
            strcopy(bestPath, sizeof(bestPath), path);
        }
    }

    if (!haveBest)
        return;

    // Parse into per-player route (cache)
    if (gTimeDiffRoute[client] != null) { delete gTimeDiffRoute[client]; }
    gTimeDiffRoute[client] = new ArrayList(3);

    if (!TD_ReadReplayInto(bestPath, gTimeDiffRoute[client]))
    {
        delete gTimeDiffRoute[client];
        gTimeDiffRoute[client] = null;
        gTimeDiffRouteReady[client] = false;
        return;
    }

    gTimeDiffRouteReady[client] = true;

    // >>> Compute PB length from ticks (trim +/-256 ticks; 128 ticks per second)
    int ticks = gTimeDiffRoute[client].Length;
    float pbSecs;
    if (ticks > 512)
    {
        pbSecs = float(ticks - 512) / 128.0;
    }
    else
    {
        // Extremely short/invalid replay; fall back to whole length
        pbSecs = float(ticks) / 128.0;
    }
    gTimeDiffPBTime[client] = pbSecs; // used by TD_GetEffectiveInterval()
}


// Simple failure logger that swallows the DataPack safely
public void TD_TxnFailure_Log(Handle db, DataPack data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
    if (data != null) delete data;
    LogError("[TimeDiff] SQL failure at %d: %s", failIndex, error);
}

static Database TD_GetDB()
{
    Database db = GOKZ_DB_GetDatabase();
    if (db == null)
    {
        LogError("[TimeDiff] Could not get GOKZ local database handle.");
    }
    return db;
}
