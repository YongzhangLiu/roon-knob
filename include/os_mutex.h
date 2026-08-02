#pragma once

#ifdef ESP_PLATFORM
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"

typedef SemaphoreHandle_t os_mutex_t;

#define OS_MUTEX_INITIALIZER NULL

static inline int os_mutex_init(os_mutex_t *mutex) {
    *mutex = xSemaphoreCreateMutex();
    return (*mutex != NULL) ? 0 : -1;
}

static inline int os_mutex_lock(os_mutex_t *mutex) {
    if (*mutex == NULL) {
        os_mutex_init(mutex);
    }
    return xSemaphoreTake(*mutex, portMAX_DELAY) == pdTRUE ? 0 : -1;
}

static inline int os_mutex_unlock(os_mutex_t *mutex) {
    return xSemaphoreGive(*mutex) == pdTRUE ? 0 : -1;
}

static inline int os_mutex_destroy(os_mutex_t *mutex) {
    if (*mutex != NULL) {
        vSemaphoreDelete(*mutex);
        *mutex = NULL;
    }
    return 0;
}

#else
#include <pthread.h>

typedef pthread_mutex_t os_mutex_t;

#define OS_MUTEX_INITIALIZER PTHREAD_MUTEX_INITIALIZER

static inline int os_mutex_init(os_mutex_t *mutex) {
    return pthread_mutex_init(mutex, NULL);
}

static inline int os_mutex_lock(os_mutex_t *mutex) {
    return pthread_mutex_lock(mutex);
}

static inline int os_mutex_unlock(os_mutex_t *mutex) {
    return pthread_mutex_unlock(mutex);
}

static inline int os_mutex_destroy(os_mutex_t *mutex) {
    return pthread_mutex_destroy(mutex);
}

#endif
