#ifndef PLUTO_PRESENTER_QTFB_QTFB_PRESENTER_H_
#define PLUTO_PRESENTER_QTFB_QTFB_PRESENTER_H_

#include "pluto/presenter.h"

#ifdef __cplusplus
extern "C" {
#endif

const PlutoPresenterOps *pluto_qtfb_presenter_ops(void);

#ifdef __cplusplus
} // extern "C"

#include "presenter/qtfb/qtfb_proto.h"

namespace pluto {

// Polls one input packet from a presenter returned by
// pluto_qtfb_presenter_ops(). This is an internal EngineHost integration hook,
// not part of the stable PlutoPresenterOps ABI.
PlutoStatus qtfb_receive_user_input(PlutoPresenter *presenter,
                                    qtfb::UserInputContents *out_input);

} // namespace pluto
#endif

#endif // PLUTO_PRESENTER_QTFB_QTFB_PRESENTER_H_
