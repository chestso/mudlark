/* Session management implementation for mudlark */

#include "session.h"
#include "logging.h"
#include <gc/gc.h>
#include <string.h>

#define MAX_SESSIONS 32

/* Session manager state */
static Environment *base_env = NULL;
static Session *sessions[MAX_SESSIONS];
static int session_count_val = 0;
static Session *current_session = NULL;
static int next_session_id = 1;

int session_manager_init(Environment *env)
{
    if (base_env) {
        return 0; /* Already initialized */
    }

    if (!env) {
        bloom_log(LOG_ERROR, "session",
                  "NULL environment passed to session_manager_init");
        return -1;
    }

    base_env = env;

    memset(sessions, 0, sizeof(sessions));
    session_count_val = 0;
    current_session = NULL;
    next_session_id = 1;

    return 0;
}

void session_manager_cleanup(void)
{
    /* Destroy all sessions */
    for (int i = 0; i < session_count_val; i++) {
        if (sessions[i]) {
            if (sessions[i]->telnet && sessions[i]->connected) {
                telnet_disconnect(sessions[i]->telnet);
            }
            sessions[i] = NULL;
        }
    }
    session_count_val = 0;
    current_session = NULL;

    base_env = NULL; /* Owned by caller */
}

Environment *session_get_base_env(void) { return base_env; }

Session *session_create(const char *name)
{
    if (!base_env) {
        bloom_log(LOG_ERROR, "session", "Session manager not initialized");
        return NULL;
    }

    if (session_count_val >= MAX_SESSIONS) {
        bloom_log(LOG_ERROR, "session", "Maximum session count reached (%d)",
                  MAX_SESSIONS);
        return NULL;
    }

    Session *s = GC_malloc(sizeof(Session));
    if (!s) {
        return NULL;
    }

    s->id = next_session_id++;
    s->name = GC_strdup(name ? name : "unnamed");
    s->hooks = lisp_make_hash_table();
    s->telnet = NULL;
    s->connected = 0;

    sessions[session_count_val++] = s;

    bloom_log(LOG_INFO, "session", "Created session %d: \"%s\"", s->id, s->name);

    return s;
}

int session_destroy(int id)
{
    if (current_session && current_session->id == id) {
        bloom_log(LOG_ERROR, "session", "Cannot destroy current session %d", id);
        return -1;
    }

    for (int i = 0; i < session_count_val; i++) {
        if (sessions[i] && sessions[i]->id == id) {
            Session *s = sessions[i];

            if (s->telnet && s->connected) {
                telnet_disconnect(s->telnet);
            }
            bloom_log(LOG_INFO, "session", "Destroyed session %d: \"%s\"", s->id,
                      s->name);

            /* Compact the array — GC handles memory deallocation */
            for (int j = i; j < session_count_val - 1; j++) {
                sessions[j] = sessions[j + 1];
            }
            sessions[--session_count_val] = NULL;

            return 0;
        }
    }

    return -1; /* Not found */
}

Session *session_get_current(void) { return current_session; }

void session_set_current(Session *session) { current_session = session; }

Session *session_find_by_id(int id)
{
    for (int i = 0; i < session_count_val; i++) {
        if (sessions[i] && sessions[i]->id == id) {
            return sessions[i];
        }
    }
    return NULL;
}

Session *session_find_by_name(const char *name)
{
    if (!name) {
        return NULL;
    }
    for (int i = 0; i < session_count_val; i++) {
        if (sessions[i] && strcmp(sessions[i]->name, name) == 0) {
            return sessions[i];
        }
    }
    return NULL;
}

int session_count(void) { return session_count_val; }

Session **session_get_all(int *out_count)
{
    if (out_count) {
        *out_count = session_count_val;
    }
    return sessions;
}
