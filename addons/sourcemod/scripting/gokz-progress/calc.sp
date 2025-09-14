#if defined _GOKZ_PROGRESS_CALC_SP_
#endinput
#endif
#define _GOKZ_PROGRESS_CALC_SP_

/**
 * NOTE:
 * - This file assumes you already have:
 *     - ArrayList gTickPositions;  // each entry is float[3] route position
 *     - float gProgressValues[MAXPLAYERS + 1];
 * - Include this file AFTER those globals are declared, or just anywhere
 *   in the same .sp where those are visible (textual include).
 */

/**
 * Returns the index of the nearest replay tick to a world position.
 * -1 if gTickPositions is empty.
 */
stock int GP_NearestTickToPos(const float pos[3])
{
    if (gTickPositions == null || gTickPositions.Length <= 0)
        return -1;

    float tickPos[3];
    int   nearest = -1;
    float bestDist = 0.0;

    for (int i = 0; i < gTickPositions.Length; i++)
    {
        gTickPositions.GetArray(i, tickPos, 3);
        float d = GetVectorDistance(pos, tickPos);
        if (nearest == -1 || d < bestDist)
        {
            nearest = i;
            bestDist = d;
        }
    }
    return nearest;
}

/**
 * Progress (0.0–1.0) for an arbitrary world position.
 */
stock float GP_ProgressFromPos(const float pos[3])
{
    int idx = GP_NearestTickToPos(pos);
    if (idx < 0) return 0.0;
    return float(idx) / float(gTickPositions.Length);
}

/**
 * Progress (0.0–1.0) for a client’s current origin.
 */
stock float GP_GetClientProgress(int client)
{
    float pos[3];
    GetClientAbsOrigin(client, pos);
    return GP_ProgressFromPos(pos);
}

/**
 * Updates gProgressValues[client] and contribution score based on current origin.
 */
stock void GP_UpdateClientProgressAndScore(int client)
{
    float prog = GP_GetClientProgress(client);
    gProgressValues[client] = prog;

    int score = RoundToNearest(prog * 1000.0);
    CS_SetClientContributionScore(client, score);
}
