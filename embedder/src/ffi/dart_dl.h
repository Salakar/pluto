#ifndef PLUTO_FFI_DART_DL_H_
#define PLUTO_FFI_DART_DL_H_

#include <cstdint>

extern "C" {

intptr_t pluto_dart_initialize_api_dl(void* data);
void pluto_pen_ring_set_wakeup_port(int64_t dart_native_port);
int64_t pluto_engine_time_us(void);

}  // extern "C"

#endif  // PLUTO_FFI_DART_DL_H_
