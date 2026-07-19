#ifndef PLUTO_PRESENTER_PRESENTER_CONTRACT_H_
#define PLUTO_PRESENTER_PRESENTER_CONTRACT_H_

#include "pluto/presenter.h"

namespace pluto {

// Pluto owns and builds both sides of this unpublished interface. Accept only
// the one operation table compiled into the current release: no prefix tables
// and no nullable tail hooks.
inline bool presenter_ops_are_current(const PlutoPresenterOps *ops) {
  return ops != nullptr && ops->struct_size == sizeof(PlutoPresenterOps) &&
         ops->name != nullptr && ops->open != nullptr &&
         ops->close != nullptr && ops->info != nullptr &&
         ops->present != nullptr && ops->ready != nullptr &&
         ops->wait_idle != nullptr && ops->snapshot != nullptr &&
         ops->set_pen_focus != nullptr && ops->stage_handoff != nullptr &&
         ops->get_handoff != nullptr && ops->confirm_handoff != nullptr;
}

} // namespace pluto

#endif // PLUTO_PRESENTER_PRESENTER_CONTRACT_H_
