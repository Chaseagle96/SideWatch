//
//  native_bridge_common.h
//  AltSign
//
//  Created by Magesh K on 25/02/26.
//

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifndef NATIVE_BRIDGE_EXPORT
#define NATIVE_BRIDGE_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// frees strdup / char* returned across bridge
NATIVE_BRIDGE_EXPORT void native_bridge_free_string(char *ptr);

// frees arbitrary buffers allocated by NativeBridge (malloc/new → malloc-backed)
NATIVE_BRIDGE_EXPORT void native_bridge_free(void *ptr);

#ifdef __cplusplus
}
#endif
