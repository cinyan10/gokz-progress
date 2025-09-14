ConVar gCvarIncludeBots;

float gProgressValues[MAXPLAYERS + 1];
bool gValidReplayAvailable = true;

int g_ProgressClients[MAXPLAYERS + 1];
int g_ProgressClientCount = 0;
int g_ProgressClientIndex = 0;
Handle g_ProgressGlobalTimer = null;
bool g_IsProcessing[MAXPLAYERS + 1];

Cookie gRankDisplayCookie;
Cookie gProgressDisplayCookie;

enum ProgressStatus
{
    Progress_None = 0,
    Progress_Running,
    Progress_DNF,
    Progress_Finished
};

ProgressStatus gProgressStatus[MAXPLAYERS + 1];
