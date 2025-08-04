#if defined _gokz_progress_included
  #endinput
#endif
#define _gokz_progress_included

#pragma semicolon 1

/**
 * 加载 .replay 文件，只提取 tick 坐标
 *
 * @param path 相对路径，例如 "addons/sourcemod/data/gokz-replays/_runs/..."
 * @return 成功返回 true
 */
native bool LoadReplayTickPositions(const char[] path);

/**
 * 获取 tick 总数
 */
native int GetReplayTickCount();

/**
 * 获取某一 tick 的坐标
 *
 * @param tick Tick 索引
 * @param pos 输出 float[3] 数组
 * @return 成功返回 true
 */
native bool GetReplayTickPos(int tick, float pos[3]);

native bool FindBestReplayFile(char[] pathOut, int maxlen);

native void GetOnePlayerProgressStats(int client, float &progress, int &rank, int &total);

/**
 * Get a formatted string representing a player's rank and progress.
 *
 * @param client        Client index.
 * @param buffer        Destination buffer to store formatted text.
 * @param maxlen        Maximum length of the buffer.
 *
 * Example output: "Rank: 3 / 12\nProgress: 78.5%"
 */
native int GetProgressText(int client, char[] buffer, int maxlen);
