
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

void ReadReplay(const char[] path)
{
    File file = OpenFile(path, "rb");
    if (file == null) {
        LogMessage(" Failed to open file: %s", path);
        return;
    }

    LogMessage(" Reading Header from %s", path);

    int magic; file.ReadInt32(magic);
    if (magic != 0x676F6B7A) {
        LogMessage(" Invalid magic number: %d", magic);
        delete file;
        return;
    }

    int format; file.ReadInt8(format);
    int type; file.ReadInt8(type);

    int tickCount;
    ReadReplayHeader(path, tickCount);
    LogMessage(" Replay format %d, tickcount: %d", format, tickCount);

    if (tickCount <= 0) {
        LogMessage(" Invalid tick count");
        delete file;
        return;
    }

    gTickPositions.Clear();
    gTickPositions.Resize(tickCount);

    if (format == 1)
    {
        int len;
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // GOKZ version
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // Map name

        file.Seek(4 * 3, SEEK_CUR); // course, mode, style
        file.Seek(4 * 4, SEEK_CUR); // time, teleports, steamid, steamid2

        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // steamID2
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // IP
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // alias

        any tick[7];
        float pos[3];

        int keepStart = 2 * 128;
        int keepEnd = 2 * 128;
        int outputIndex = 0;

        for (int i = 0; i < tickCount; i++) {
            file.Read(tick, 7, 4);
            pos[0] = view_as<float>(tick[0]);
            pos[1] = view_as<float>(tick[1]);
            pos[2] = view_as<float>(tick[2]);

            if (i < keepStart || i >= keepEnd)
                continue;
            gTickPositions.SetArray(i, pos, 3);
        }
        gTickPositions.Resize(outputIndex);

        delete file;
        return;
    }
    else if (format == 2)
    {
        int len;
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // GOKZ version
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // Map name

        file.Seek(4 * 3, SEEK_CUR); // mapFileSize, ip, timestamp
        file.ReadInt8(len); file.Seek(len, SEEK_CUR); // alias
        file.Seek(4 + 1 + 1 + 4 + 4 + 4, SEEK_CUR); // steamid, mode, style, sens, yaw, tickrate
        file.ReadInt32(tickCount);
        file.Seek(4 * 2, SEEK_CUR); // weapon, knife

        int replayType = type; // type 是 replayType
        if (replayType == 0) {
            file.Seek(4 + 1 + 4, SEEK_CUR); // time, course, teleports
        } else if (replayType == 1) {
            file.Seek(1, SEEK_CUR); // acReason
        } else if (replayType == 2) {
            file.Seek(4 + 4 + 4 + 1 + 4 + 4 + 4, SEEK_CUR); // Jump replay block
        }

        float prevPos[3] = {0.0, 0.0, 0.0};

        for (int i = 0; i < tickCount; i++) {
            int deltaFlags; file.ReadInt32(deltaFlags);

            if (deltaFlags & 0x2) {
                int deltaFlags2; file.ReadInt32(deltaFlags2); // currently unused
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
            pos[0] = view_as<float>(tickdata[7]);  // ORIGIN_X
            pos[1] = view_as<float>(tickdata[8]);  // ORIGIN_Y
            pos[2] = view_as<float>(tickdata[9]);  // ORIGIN_Z

            if (pos[0] == 0.0 && pos[1] == 0.0 && pos[2] == 0.0 &&
                prevPos[0] == 0.0 && prevPos[1] == 0.0 && prevPos[2] == 0.0) {
                break;
            }

            gTickPositions.SetArray(i, pos, 3);
            prevPos[0] = pos[0];
            prevPos[1] = pos[1];
            prevPos[2] = pos[2];
        }

        delete file;
        return;
    }

    LogMessage(" Unsupported format %d", format);
    delete file;
}

void ReadReplayHeader2(const char[] path, int &tickCount, char[] mapNameOut, int mapNameSize, int &course)
{
    File file = OpenFile(path, "rb");
    if (file == null) return;

    int magic; file.ReadInt32(magic);
    int format; file.ReadInt8(format);
    int type; file.ReadInt8(type); // 0=Run, 1=Jump, 2=Cheater

    int len;
    char mapName[64];

    if (format == 1)
    {
        // Skip GOKZ version
        file.ReadInt8(len);
        file.Seek(len, SEEK_CUR);

        // Map name
        file.ReadInt8(len);
        file.ReadString(mapName, sizeof(mapName), len);
        mapName[len] = '\0';

        // Read course
        file.ReadInt32(course);

        // Skip mode + style (2x Int32)
        file.Seek(8, SEEK_CUR);

        // Skip time, teleports, steamID (3x Int32)
        file.Seek(12, SEEK_CUR);

        // Skip SteamID2
        file.ReadInt8(len);
        file.Seek(len, SEEK_CUR);

        // Skip IP
        file.ReadInt8(len);
        file.Seek(len, SEEK_CUR);

        // Skip alias
        file.ReadInt8(len);
        file.Seek(len, SEEK_CUR);

        // Read tick count
        file.ReadInt32(tickCount);
    }
    else if (format == 2)
    {
        // Skip GOKZ version
        file.ReadInt8(len);
        file.Seek(len, SEEK_CUR);

        // Map name
        file.ReadInt8(len);
        file.ReadString(mapName, sizeof(mapName), len);
        mapName[len] = '\0';

        // Skip mapFileSize, ip, timestamp (3x Int32)
        file.Seek(12, SEEK_CUR);

        // Skip alias
        file.ReadInt8(len);
        file.Seek(len, SEEK_CUR);

        // Skip steamid (Int32), mode (Int8), style (Int8), sens (Int32), yaw (Int32), tickrate (Int32)
        file.Seek(4 + 1 + 1 + 4 + 4 + 4, SEEK_CUR);

        // Read tick count
        file.ReadInt32(tickCount);

        // Skip weapon, knife
        file.Seek(8, SEEK_CUR);

        // If it's a run, read time and course
        file.Seek(4, SEEK_CUR);

            // Read course
        file.ReadInt8(course);

    }
    else
    {
        delete file;
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

    DirectoryListing files = OpenDirectory(dir);
    if (files == null) return false;

    int bestTicks = -1;
    char bestPath[PLATFORM_MAX_PATH];
    char fileName[PLATFORM_MAX_PATH];
    FileType type;

    while (files.GetNext(fileName, sizeof(fileName), type))
    {
        if (type != FileType_File || !StrContains(fileName, ".replay", false))
            continue;

        char fullPath[PLATFORM_MAX_PATH];
        Format(fullPath, sizeof(fullPath), "%s%s", dir, fileName);

        int tickCount, course;
        char mapName[64];
        ReadReplayHeader2(fullPath, tickCount, mapName, sizeof(mapName), course);

        // Must be current map & course 0
        if (!StrEqual(mapName, map, false) || course != 0)
            continue;

        if (bestTicks == -1 || tickCount < bestTicks)
        {
            bestTicks = tickCount;
            strcopy(bestPath, sizeof(bestPath), fullPath);
        }
    }

    delete files;

    if (bestTicks <= 30 * 60 * 128 && bestTicks > 0)
    {
        strcopy(outPath, maxlen, bestPath);
        LogMessage("Best replay path: %s (tickCount = %d)", bestPath, bestTicks);
        return true;
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
