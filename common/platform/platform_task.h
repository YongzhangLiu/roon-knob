#pragma once

#include "os_thread.h"

typedef void (*platform_task_fn_t)(void *arg);

void platform_task_init(void);
int platform_task_start(platform_task_fn_t fn, void *arg);
void platform_task_post_to_ui(platform_task_fn_t fn, void *arg);
void platform_task_run_pending(void);
