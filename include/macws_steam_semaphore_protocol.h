#ifndef MACWS_STEAM_SEMAPHORE_PROTOCOL_H
#define MACWS_STEAM_SEMAPHORE_PROTOCOL_H

#include <stdint.h>

#define MACWS_STEAM_SEM_MAGIC 0x4d575345u /* MWSE */
#define MACWS_STEAM_SEM_VERSION 4u
#define MACWS_STEAM_SEM_VALUE_MAX 0x7fffffffu

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint32_t value;
    uint32_t revision;
    uint64_t brokerGeneration;
    char name[112];
} MacWSSteamSemaphoreState;

#define MACWS_STEAM_SEM_OP_OPEN "steam-sem-open"
#define MACWS_STEAM_SEM_OP_CLOSE "steam-sem-close"
#define MACWS_STEAM_SEM_OP_UNLINK "steam-sem-unlink"
#define MACWS_STEAM_SEM_OP_RESET "steam-sem-reset"

#define MACWS_STEAM_SEM_KEY_NAME "steam_sem_name"
#define MACWS_STEAM_SEM_KEY_FLAGS "steam_sem_flags"
#define MACWS_STEAM_SEM_KEY_VALUE "steam_sem_value"
#define MACWS_STEAM_SEM_KEY_GENERATION "steam_sem_generation"
#define MACWS_STEAM_SEM_KEY_CREATED "steam_sem_created"
#define MACWS_STEAM_SEM_KEY_EPOCH "steam_sem_epoch"
#define MACWS_STEAM_SEM_KEY_ERROR "steam_sem_error"

#endif
