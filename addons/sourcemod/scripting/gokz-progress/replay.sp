
#define REPLAY_DIR_FORMAT "addons/sourcemod/data/gokz-replays/_runs/%s/"

ArrayList gTickPositions;


void ReadReplayHeader(const char[] path, int &tickCount)
{
    File file = OpenFile(path, "rb");
    if (file == null) {
        LogMessage(" Failed to open file: %s", path);
        return;
    }

    int magic; file.ReadInt32(magic);
    int format; file.ReadInt8(format);
    int type; file.ReadInt8(type);

    int len;
    file.ReadInt8(len);
    char gokzVersion[64];
    file.ReadString(gokzVersion, sizeof(gokzVersion), len);

    file.ReadInt8(len);
    char mapName[64];
    file.ReadString(mapName, sizeof(mapName), len);

    int mapFileSize; file.ReadInt32(mapFileSize);
    int ip; file.ReadInt32(ip);
    int timestamp; file.ReadInt32(timestamp);

    file.ReadInt8(len);
    char alias[64];
    file.ReadString(alias, sizeof(alias), len);

    int steamid; file.ReadInt32(steamid);
    int mode; file.ReadInt8(mode);
    int style; file.ReadInt8(style);
    int sens; file.ReadInt32(sens);
    int yaw; file.ReadInt32(yaw);
    int tickrate; file.ReadInt32(tickrate);
    file.ReadInt32(tickCount);
    int weapon; file.ReadInt32(weapon);
    int knife; file.ReadInt32(knife);

    delete file;
}

void ReadReplayInfoForDebug(const char[] path, char[] mapName, int mapNameSize, int &format, int &type, int &course, int &tickCount, char[] alias, int aliasSize, int &time)
{
    File file = OpenFile(path, "rb");
    if (file == null) {
        mapName[0] = '\0';
        alias[0] = '\0';
        format = 0;
        type = 0;
        course = 0;
        tickCount = 0;
        time = 0;
        return;
    }

    int magic; file.ReadInt32(magic);
    int tempFormat; file.ReadInt8(tempFormat); format = tempFormat;
    int tempType; file.ReadInt8(tempType); type = tempType;
    
    if (format == 1)
    {
        // Skip GOKZ version
        char tmp[64];
        ReadLPString(file, tmp, sizeof(tmp));
        
        // Map name
        ReadLPString(file, mapName, mapNameSize);
        
        // Course
        file.ReadInt32(course);
        
        // Skip mode, style
        file.Seek(8, SEEK_CUR);
        
        // Time
        file.ReadInt32(time);
        
        // Skip teleports, steamid
        file.Seek(8, SEEK_CUR);
        
        // Skip SteamID2, IP
        ReadLPString(file, tmp, sizeof(tmp));
        ReadLPString(file, tmp, sizeof(tmp));
        
        // Alias
        ReadLPString(file, alias, aliasSize);
        
        // Tick count
        file.ReadInt32(tickCount);
    }
    else if (format == 2)
    {
        // Skip GOKZ version
        char tmp[64];
        ReadLPString(file, tmp, sizeof(tmp));
        
        // Map name
        ReadLPString(file, mapName, mapNameSize);
        
        // Skip mapFileSize, ip, timestamp
        file.Seek(12, SEEK_CUR);
        
        // Alias
        ReadLPString(file, alias, aliasSize);
        
        // Skip: steamid, mode, style, sens, yaw, tickrate
        file.Seek(4 + 1 + 1 + 4 + 4 + 4, SEEK_CUR);
        
        // Tick count
        file.ReadInt32(tickCount);
        
        // Skip weapon, knife
        file.Seek(8, SEEK_CUR);
        
        // Time and course
        if (type == 0) {
            file.ReadInt32(time);
            file.ReadInt8(course);
        } else {
            time = 0;
            course = 0;
        }
    }
    else
    {
        mapName[0] = '\0';
        alias[0] = '\0';
        course = 0;
        tickCount = 0;
        time = 0;
    }

    delete file;
}

void ReadReplay(const char[] path)
{
    if (gTickPositions == null)
        gTickPositions = new ArrayList(3);

    LogMessage(" Reading Header from %s", path);

    // Debug output if enabled
    if (gCvarDebug.BoolValue)
    {
        char mapName[64];
        char alias[64];
        int format, type, course, tickCount, time;
        ReadReplayInfoForDebug(path, mapName, sizeof(mapName), format, type, course, tickCount, alias, sizeof(alias), time);
        
        LogMessage("[DEBUG] Replay Info:");
        LogMessage("  Path: %s", path);
        LogMessage("  Format: %d, Type: %d", format, type);
        LogMessage("  Map: %s, Course: %d", mapName, course);
        LogMessage("  Player: %s", alias);
        LogMessage("  Tick Count: %d", tickCount);
        if (time > 0) {
            float timeSeconds = float(time) / 1000.0;
            LogMessage("  Time: %.3f seconds", timeSeconds);
        }
    }

    gTickPositions.Clear();
    bool ok = RP_ReadReplayInto(path, gTickPositions);

    if (ok) {
        LogMessage(" Loaded replay into global route, length=%d", gTickPositions.Length);
        if (gCvarDebug.BoolValue) {
            LogMessage("[DEBUG] Successfully loaded %d tick positions", gTickPositions.Length);
        }
    } else {
        LogMessage(" Failed to load replay into global route: %s", path);
    }
}


void ReadReplayHeader2(const char[] path, int &tickCount, char[] mapNameOut, int mapNameSize, int &course)
{
    File file = OpenFile(path, "rb");
    if (file == null) {
        tickCount = 0;
        if (mapNameSize > 0) mapNameOut[0] = '\0';
        course = 0;
        return;
    }

    int magic;   file.ReadInt32(magic);
    int format;  file.ReadInt8(format);
    int type;    file.ReadInt8(type); // 0=Run, 1=Jump, 2=Cheater

    // Use a larger local buffer to reduce truncation in practice
    char mapName[128];

    if (format == 1)
    {
        // Skip GOKZ version
        char tmp[2]; // not used; just consume properly
        ReadLPString(file, tmp, sizeof(tmp));

        // Map name (safe)
        ReadLPString(file, mapName, sizeof(mapName));

        // Read course (Int32 in v1)
        file.ReadInt32(course);

        // Skip mode + style (2x Int32)
        file.Seek(8, SEEK_CUR);

        // Skip time, teleports, steamID (3x Int32)
        file.Seek(12, SEEK_CUR);

        // Skip SteamID2
        ReadLPString(file, tmp, sizeof(tmp));

        // Skip IP
        ReadLPString(file, tmp, sizeof(tmp));

        // Skip alias
        ReadLPString(file, tmp, sizeof(tmp));

        // Read tick count
        file.ReadInt32(tickCount);
    }
    else if (format == 2)
    {
        // Skip GOKZ version
        char tmp[2];
        ReadLPString(file, tmp, sizeof(tmp));

        // Map name (safe)
        ReadLPString(file, mapName, sizeof(mapName));

        // Skip mapFileSize, ip, timestamp (3x Int32)
        file.Seek(12, SEEK_CUR);

        // Skip alias
        ReadLPString(file, tmp, sizeof(tmp));

        // Skip: steamid(Int32), mode(Int8), style(Int8), sens(Int32), yaw(Int32), tickrate(Int32)
        file.Seek(4 + 1 + 1 + 4 + 4 + 4, SEEK_CUR);

        // Read tick count
        file.ReadInt32(tickCount);

        // Skip weapon, knife (2x Int32)
        file.Seek(8, SEEK_CUR);

        // Skip time (Int32) then read course (Int8) as per your layout
        file.Seek(4, SEEK_CUR);
        file.ReadInt8(course);
    }
    else
    {
        delete file;
        tickCount = 0;
        if (mapNameSize > 0) mapNameOut[0] = '\0';
        course = 0;
        return;
    }

    // Copy map name out
    strcopy(mapNameOut, mapNameSize, mapName);

    delete file;
}

bool FindBestReplayFilePath(char[] outPath, int maxlen)
{
    char map[64];
    GetCurrentMap(map, sizeof(map));

    char dir[PLATFORM_MAX_PATH];
    Format(dir, sizeof(dir), REPLAY_DIR_FORMAT, map);

    if (gCvarDebug.BoolValue)
    {
        LogMessage("[DEBUG] Searching for best replay in directory: %s", dir);
        LogMessage("[DEBUG] Looking for map: %s, course: 0", map);
    }

    DirectoryListing files = OpenDirectory(dir);
    if (files == null)
    {
        if (gCvarDebug.BoolValue)
            LogMessage("[DEBUG] Failed to open directory: %s", dir);
        return false;
    }

    int bestTicks = -1;
    char bestPath[PLATFORM_MAX_PATH];
    char fileName[PLATFORM_MAX_PATH];
    FileType type;
    int checkedCount = 0;
    int validCount = 0;

    while (files.GetNext(fileName, sizeof(fileName), type))
    {
        if (type != FileType_File || !StrContains(fileName, ".replay", false))
            continue;

        checkedCount++;
        char fullPath[PLATFORM_MAX_PATH];
        Format(fullPath, sizeof(fullPath), "%s%s", dir, fileName);

        int tickCount, course;
        char mapName[64];
        ReadReplayHeader2(fullPath, tickCount, mapName, sizeof(mapName), course);

        if (gCvarDebug.BoolValue)
        {
            LogMessage("[DEBUG] Checking replay: %s", fileName);
            LogMessage("  Map: %s (current: %s), Course: %d, Ticks: %d", mapName, map, course, tickCount);
        }

        // Must be current map & course 0
        if (!StrEqual(mapName, map, false) || course != 0)
        {
            if (gCvarDebug.BoolValue)
                LogMessage("  -> Skipped (wrong map or course)");
            continue;
        }

        validCount++;
        if (bestTicks == -1 || tickCount < bestTicks)
        {
            bestTicks = tickCount;
            strcopy(bestPath, sizeof(bestPath), fullPath);
            if (gCvarDebug.BoolValue)
                LogMessage("  -> New best replay (ticks: %d)", tickCount);
        }
    }

    delete files;

    if (gCvarDebug.BoolValue)
    {
        LogMessage("[DEBUG] Replay search summary:");
        LogMessage("  Files checked: %d", checkedCount);
        LogMessage("  Valid replays found: %d", validCount);
        LogMessage("  Best replay ticks: %d", bestTicks);
    }

    // Check replay size limit (convert minutes to ticks at 128 tickrate)
    int maxTicks = RoundToFloor(gCvarMaxReplayTime.FloatValue * 60.0 * 128.0);
    if (gCvarDebug.BoolValue && bestTicks > 0)
    {
        LogMessage("[DEBUG] Max replay time: %.1f minutes (%d ticks)", gCvarMaxReplayTime.FloatValue, maxTicks);
    }

    if (bestTicks <= maxTicks && bestTicks > 0)
    {
        strcopy(outPath, maxlen, bestPath);
        LogMessage("Best replay path: %s (tickCount = %d)", bestPath, bestTicks);
        if (gCvarDebug.BoolValue)
            LogMessage("[DEBUG] Selected best replay: %s", bestPath);
        return true;
    }

    if (bestTicks > maxTicks)
    {
        LogMessage("[Progress] Best replay exceeds size limit: %s (tickCount: %d, max: %d ticks / %.1f minutes)", 
            bestPath, bestTicks, maxTicks, gCvarMaxReplayTime.FloatValue);
        if (gCvarDebug.BoolValue)
            LogMessage("[DEBUG] Replay rejected due to size limit");
    }
    else if (gCvarDebug.BoolValue)
    {
        LogMessage("[DEBUG] No valid replay found (bestTicks: %d)", bestTicks);
    }

    return false;
}

public int GetBestReplayTickCount()
{
    char path[PLATFORM_MAX_PATH];

    if (!FindBestReplayFilePath(path, sizeof(path)))
    {
        LogMessage("No best replay file found.");
        return -1;
    }

    int tickCount;
    ReadReplayHeader(path, tickCount);
    return tickCount;
}

// --- Safe reader for len-prefixed strings -----------------------------------
static bool ReadLPString(File file, char[] out, int outMax)
{
    int len;
    if (!file.ReadInt8(len))        // length prefix (1 byte)
        return false;

    if (len <= 0) {
        if (outMax > 0) out[0] = '\0';
        return true;
    }

    int toRead = len;
    if (outMax > 0) {
        int cap = outMax - 1;                   // leave room for '\0'
        if (toRead > cap) toRead = cap;
    } else {
        toRead = 0;
    }

    // Read up to our capacity
    if (toRead > 0)
        file.ReadString(out, outMax, toRead);
    if (outMax > 0)
        out[toRead] = '\0';

    // If the stored string was longer, skip the remainder to keep alignment
    int skip = len - toRead;
    if (skip > 0)
        file.Seek(skip, SEEK_CUR);

    return true;
}

/**
 * Reads a replay file and fills 'dest' with float[3] positions (one per tick point).
 * - Supports format 1 (no trimming) and format 2 (trims first/last 256 ticks).
 * - Returns true on success with at least one point.
 *
 * NOTE: This mirrors your ReadReplay() logic but writes into 'dest' instead of gTickPositions.
 */
stock bool RP_ReadReplayInto(const char[] path, ArrayList dest)
{
    if (dest == null)
        return false;

    File file = OpenFile(path, "rb");
    if (file == null) {
        LogMessage(" Failed to open file: %s", path);
        return false;
    }

    int magic; file.ReadInt32(magic);
    if (magic != 0x676F6B7A) {
        LogMessage(" Invalid magic number: %d", magic);
        delete file;
        return false;
    }

    int format; file.ReadInt8(format);
    int type;   file.ReadInt8(type);

    // We need tickCount for format 1 sizing and also for logging.
    int tickCount;
    ReadReplayHeader(path, tickCount); // re-opens file internally; harmless but convenient

    if (tickCount <= 0) {
        LogMessage(" Invalid tick count");
        delete file;
        return false;
    }

    dest.Clear();

    if (format == 1)
    {
        // --- Read format 1 with NO trimming ---
        int len;
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // GOKZ version
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // Map name

        file.Seek(4 * 3, SEEK_CUR); // course, mode, style
        file.Seek(4 * 4, SEEK_CUR); // time, teleports, steamid, steamid2

        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // steamID2
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // IP
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // alias

        any   tick[7];
        float pos[3];

        dest.Resize(tickCount);
        for (int i = 0; i < tickCount; i++) {
            file.Read(tick, 7, 4);
            pos[0] = view_as<float>(tick[0]);
            pos[1] = view_as<float>(tick[1]);
            pos[2] = view_as<float>(tick[2]);
            dest.SetArray(i, pos, 3);
        }

        delete file;
        return dest.Length > 0;
    }
    else if (format == 2)
    {
        // --- Read format 2, then trim first/last 256 ticks ---
        int len;
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // GOKZ version
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // Map name

        file.Seek(4 * 3, SEEK_CUR);                   // mapFileSize, ip, timestamp
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // alias
        file.Seek(4 + 1 + 1 + 4 + 4 + 4, SEEK_CUR);   // steamid, mode, style, sens, yaw, tickrate
        file.ReadInt32(tickCount);
        file.Seek(4 * 2, SEEK_CUR);                   // weapon, knife

        int replayType = type;
        if (replayType == 0) {
            file.Seek(4 + 1 + 4, SEEK_CUR);          // time, course, teleports
        } else if (replayType == 1) {
            file.Seek(1, SEEK_CUR);                  // acReason
        } else if (replayType == 2) {
            file.Seek(4 + 4 + 4 + 1 + 4 + 4 + 4, SEEK_CUR); // Jump replay block
        }

        float prevPos[3] = {0.0, 0.0, 0.0};

        int actual = 0;
        for (int i = 0; i < tickCount; i++) {
            int deltaFlags; file.ReadInt32(deltaFlags);

            if (deltaFlags & 0x2) {
                int deltaFlags2; file.ReadInt32(deltaFlags2); // unused now
            }

            int tickdata[32];
            tickdata[7] = view_as<int>(prevPos[0]); // ORIGIN_X
            tickdata[8] = view_as<int>(prevPos[1]); // ORIGIN_Y
            tickdata[9] = view_as<int>(prevPos[2]); // ORIGIN_Z

            for (int j = 1; j < 32; j++) {
                if (deltaFlags & (1 << j)) {
                    file.ReadInt32(tickdata[j]);
                }
            }

            float pos[3];
            pos[0] = view_as<float>(tickdata[7]);
            pos[1] = view_as<float>(tickdata[8]);
            pos[2] = view_as<float>(tickdata[9]);

            // Early-termination guard
            if (pos[0] == 0.0 && pos[1] == 0.0 && pos[2] == 0.0 &&
                prevPos[0] == 0.0 && prevPos[1] == 0.0 && prevPos[2] == 0.0) {
                break;
            }

            int idx = dest.Length;
            dest.Resize(idx + 1);
            dest.SetArray(idx, pos, 3);

            prevPos[0] = pos[0];
            prevPos[1] = pos[1];
            prevPos[2] = pos[2];
            actual++;
        }

        // Trim first & last 256 ticks safely
        const int FRONT = 256;
        const int BACK  = 256;

        if (actual <= FRONT + BACK) {
            dest.Resize(0); // nothing usable
        } else {
            int start = FRONT;
            int end   = actual - BACK;    // exclusive
            float tmp[3];
            int outIdx = 0;

            // Compact in-place: copy [start, end) to front
            for (int i = start; i < end; i++) {
                dest.GetArray(i, tmp, 3);
                dest.SetArray(outIdx++, tmp, 3);
            }
            dest.Resize(outIdx);
        }

        delete file;
        return dest.Length > 0;
    }

    LogMessage(" Unsupported format %d", format);
    delete file;
    return false;
}
