#ifndef PLUTO_ABI_H_
#define PLUTO_ABI_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PLUTO_ABI_VERSION 2

uint32_t pluto_abi_version(void);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // PLUTO_ABI_H_
