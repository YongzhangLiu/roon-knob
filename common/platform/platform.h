#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if !defined(TARGET_PC)
#error "TARGET_PC must be defined (0 for device, 1 for PC simulator)"
#endif

#if TARGET_PC
#define PLATFORM_PC 1
#else
#define PLATFORM_PC 0
#endif

#if PLATFORM_PC
#define PLATFORM_DEVICE 0
#else
#define PLATFORM_DEVICE 1
#endif
