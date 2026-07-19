#ifndef PLUTO_TEST_COMPOSITOR_PRESENTER_OPS_TEST_SUPPORT_H_
#define PLUTO_TEST_COMPOSITOR_PRESENTER_OPS_TEST_SUPPORT_H_

#include "pluto/presenter.h"

namespace pluto::test {

inline PlutoPresenterOps current_test_presenter_ops(const char *name) {
  PlutoPresenterOps ops{};
  ops.struct_size = sizeof(ops);
  ops.name = name;
  ops.open = [](const PlutoPresenterConfig *, PlutoPresenter **) {
    return kPlutoStatusUnsupported;
  };
  ops.close = [](PlutoPresenter *) {};
  ops.info = [](PlutoPresenter *, PlutoDisplayInfo *) {
    return kPlutoStatusUnsupported;
  };
  ops.present = [](PlutoPresenter *, const PlutoPresentRequest *) {
    return kPlutoStatusUnsupported;
  };
  ops.ready = [](PlutoPresenter *, PlutoRefreshClass) { return false; };
  ops.wait_idle = [](PlutoPresenter *, uint32_t) { return kPlutoStatusOk; };
  ops.snapshot = [](PlutoPresenter *, PlutoSurface *) {
    return kPlutoStatusUnsupported;
  };
  ops.set_pen_focus = [](PlutoPresenter *, const PlutoPenFocus *focus) {
    return focus != nullptr && focus->struct_size == sizeof(PlutoPenFocus)
               ? kPlutoStatusUnsupported
               : kPlutoStatusInvalidArgument;
  };
  ops.stage_handoff = [](PlutoPresenter *, const PlutoHandoffPayload *payload,
                         uint32_t) {
    return payload != nullptr &&
                   payload->struct_size == sizeof(PlutoHandoffPayload)
               ? kPlutoStatusUnsupported
               : kPlutoStatusInvalidArgument;
  };
  ops.get_handoff = [](PlutoPresenter *, PlutoHandoffPayload *payload) {
    return payload != nullptr &&
                   payload->struct_size == sizeof(PlutoHandoffPayload)
               ? kPlutoStatusUnsupported
               : kPlutoStatusInvalidArgument;
  };
  ops.confirm_handoff = [](PlutoPresenter *, bool) {
    return kPlutoStatusUnsupported;
  };
  return ops;
}

} // namespace pluto::test

#endif // PLUTO_TEST_COMPOSITOR_PRESENTER_OPS_TEST_SUPPORT_H_
