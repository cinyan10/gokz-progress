
public void SetScore(int client, float progress)
{
    if (!IsClientInGame(client))
        return;

    int score = RoundToFloor(progress * 100.0);

    // Use SetEntProp on the *networked property* for frags (scoreboard)
    SetEntProp(client, Prop_Send, "m_iFrags", score, /*size*/ 4, /*element*/ 0);

    // Optionally: keep death count untouched or explicitly clear it if needed
    // SetEntProp(client, Prop_Send, "m_iDeaths", existingOrZeroValue, 4, 0);
}


float Clamp(float value, float min, float max)
{
    if (value < min)
        return min;
    if (value > max)
        return max;
    return value;
}

float CalculateRefreshInterval()
{
    int tickCount = GetBestReplayTickCount();
    if (tickCount <= 0)
        tickCount = 17000;

    float baseTick = 17000.0;
    float baseInterval = 0.2;

    float ratio = float(tickCount) / baseTick;
    float interval = baseInterval * ratio;

    float result = Clamp(interval, 0.1, 1.0)
    return result;

}
