#pragma once

#include <stdint.h>

uint64_t platform_millis(void);
void platform_sleep_ms(uint32_t ms);
void platform_sleep_us(uint32_t us);
