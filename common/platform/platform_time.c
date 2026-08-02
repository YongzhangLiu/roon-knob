#include "platform/platform_time.h"
#include "os_time.h"

#include <time.h>

#ifdef ESP_PLATFORM
extern int64_t esp_timer_get_time(void);
#endif

uint64_t platform_millis(void) {
#ifdef ESP_PLATFORM
    return (uint64_t)(esp_timer_get_time() / 1000);
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)(ts.tv_nsec / 1000000);
#endif
}

void platform_sleep_ms(uint32_t ms) {
    os_sleep_ms(ms);
}

void platform_sleep_us(uint32_t us) {
    os_sleep_us(us);
}
