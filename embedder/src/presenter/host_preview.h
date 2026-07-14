#ifndef PLUTO_PRESENTER_HOST_PREVIEW_H_
#define PLUTO_PRESENTER_HOST_PREVIEW_H_

#include "pluto/presenter.h"

#ifdef __cplusplus
extern "C" {
#endif

const PlutoPresenterOps* pluto_host_preview_presenter_ops(void);
const PlutoPresenterOps* pluto_null_presenter_ops(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // PLUTO_PRESENTER_HOST_PREVIEW_H_
