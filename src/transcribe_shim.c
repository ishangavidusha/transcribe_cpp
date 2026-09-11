#include "transcribe_shim.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

struct tcshim_cancel {
    atomic_bool requested;
};

struct tcshim_cancel * tcshim_cancel_create(void) {
    struct tcshim_cancel * c = (struct tcshim_cancel *) malloc(sizeof(struct tcshim_cancel));
    if (c == NULL) {
        return NULL;
    }
    atomic_init(&c->requested, false);
    return c;
}

void tcshim_cancel_free(struct tcshim_cancel * c) {
    free(c);
}

void tcshim_cancel_request(struct tcshim_cancel * c) {
    if (c != NULL) {
        atomic_store_explicit(&c->requested, true, memory_order_release);
    }
}

void tcshim_cancel_reset(struct tcshim_cancel * c) {
    if (c != NULL) {
        atomic_store_explicit(&c->requested, false, memory_order_release);
    }
}

bool tcshim_cancel_is_requested(const struct tcshim_cancel * c) {
    if (c == NULL) {
        return false;
    }
    return atomic_load_explicit(&c->requested, memory_order_acquire);
}

bool tcshim_abort_cb(void * user_data) {
    return tcshim_cancel_is_requested((const struct tcshim_cancel *) user_data);
}

/*
 * Whether the previous message made it through.
 *
 * TRANSCRIBE_LOG_LEVEL_CONT means "continuation of the line before", so it
 * carries no level of its own and must inherit the decision made about that
 * line. Dropping an INFO line and then printing its continuation produces a
 * fragment attached to nothing, which is worse than either keeping or dropping
 * both. Relaxed ordering: this is a display heuristic on a single logical
 * stream, not a synchronisation point.
 */
static atomic_bool tcshim_log_passed_last = ATOMIC_VAR_INIT(false);

void tcshim_log_cb(unsigned int level, const char * msg, void * user_data) {
    const uint32_t mask = (uint32_t) (uintptr_t) user_data;

    bool pass;
    if (level == TCSHIM_LOG_CONT) {
        pass = atomic_load_explicit(&tcshim_log_passed_last, memory_order_relaxed);
    } else {
        pass = level < 32u && (mask & (1u << level)) != 0u;
        atomic_store_explicit(&tcshim_log_passed_last, pass, memory_order_relaxed);
    }

    if (!pass || msg == NULL) {
        return;
    }

    if (level == TCSHIM_LOG_CONT) {
        fputs(msg, stderr);
        return;
    }

    const char * tag;
    switch (level) {
        case TCSHIM_LOG_WARN:  tag = "warn";  break;
        case TCSHIM_LOG_ERROR: tag = "error"; break;
        case TCSHIM_LOG_DEBUG: tag = "debug"; break;
        default:               tag = "info";  break;
    }
    fprintf(stderr, "[transcribe.cpp %s] %s", tag, msg);
}
