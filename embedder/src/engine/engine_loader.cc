#include "engine/engine_loader.h"

#include <dlfcn.h>

#include <array>
#include <cstring>
#include <string>

namespace pluto {
namespace {

using GetProcAddressesFn = FlutterEngineResult (*)(FlutterEngineProcTable*);

std::string dl_error_string() {
  const char* message = dlerror();
  return message == nullptr ? std::string("unknown dlopen/dlsym error")
                            : std::string(message);
}

bool required_procs_present(const FlutterEngineProcTable& procs,
                            std::string* error) {
  struct Required {
    const char* name;
    const void* ptr;
  };
  const std::array<Required, 25> required{{
      {"CreateAOTData", reinterpret_cast<const void*>(procs.CreateAOTData)},
      {"CollectAOTData", reinterpret_cast<const void*>(procs.CollectAOTData)},
      {"Run", reinterpret_cast<const void*>(procs.Run)},
      {"Shutdown", reinterpret_cast<const void*>(procs.Shutdown)},
      {"Initialize", reinterpret_cast<const void*>(procs.Initialize)},
      {"Deinitialize", reinterpret_cast<const void*>(procs.Deinitialize)},
      {"RunInitialized", reinterpret_cast<const void*>(procs.RunInitialized)},
      {"SendWindowMetricsEvent",
       reinterpret_cast<const void*>(procs.SendWindowMetricsEvent)},
      {"SendPointerEvent", reinterpret_cast<const void*>(procs.SendPointerEvent)},
      {"SendKeyEvent", reinterpret_cast<const void*>(procs.SendKeyEvent)},
      {"SendPlatformMessage",
       reinterpret_cast<const void*>(procs.SendPlatformMessage)},
      {"PlatformMessageCreateResponseHandle",
       reinterpret_cast<const void*>(procs.PlatformMessageCreateResponseHandle)},
      {"PlatformMessageReleaseResponseHandle",
       reinterpret_cast<const void*>(procs.PlatformMessageReleaseResponseHandle)},
      {"SendPlatformMessageResponse",
       reinterpret_cast<const void*>(procs.SendPlatformMessageResponse)},
      {"OnVsync", reinterpret_cast<const void*>(procs.OnVsync)},
      {"GetCurrentTime", reinterpret_cast<const void*>(procs.GetCurrentTime)},
      {"RunTask", reinterpret_cast<const void*>(procs.RunTask)},
      {"UpdateLocales", reinterpret_cast<const void*>(procs.UpdateLocales)},
      {"RunsAOTCompiledDartCode",
       reinterpret_cast<const void*>(procs.RunsAOTCompiledDartCode)},
      {"NotifyDisplayUpdate",
       reinterpret_cast<const void*>(procs.NotifyDisplayUpdate)},
      {"ScheduleFrame", reinterpret_cast<const void*>(procs.ScheduleFrame)},
      {"SetNextFrameCallback",
       reinterpret_cast<const void*>(procs.SetNextFrameCallback)},
      {"AddView", reinterpret_cast<const void*>(procs.AddView)},
      {"RemoveView", reinterpret_cast<const void*>(procs.RemoveView)},
      {"SendViewFocusEvent",
       reinterpret_cast<const void*>(procs.SendViewFocusEvent)},
  }};

  for (const Required& item : required) {
    if (item.ptr == nullptr) {
      if (error != nullptr) {
        *error = std::string("engine proc table missing FlutterEngine") +
                 item.name;
      }
      return false;
    }
  }
  return true;
}

}  // namespace

EngineLibrary::~EngineLibrary() {
  unload();
}

bool EngineLibrary::load(const std::string& path, std::string* error) {
  unload();
  if (FLUTTER_ENGINE_VERSION != 1) {
    if (error != nullptr) {
      *error = "unsupported compile-time FLUTTER_ENGINE_VERSION";
    }
    return false;
  }

  dlerror();
  void* handle = dlopen(path.c_str(), RTLD_NOW | RTLD_LOCAL);
  if (handle == nullptr) {
    if (error != nullptr) {
      *error = "dlopen failed for " + path + ": " + dl_error_string();
    }
    return false;
  }

  dlerror();
  void* symbol = dlsym(handle, "FlutterEngineGetProcAddresses");
  if (symbol == nullptr) {
    if (error != nullptr) {
      *error = "dlsym FlutterEngineGetProcAddresses failed for " + path + ": " +
               dl_error_string();
    }
    dlclose(handle);
    return false;
  }

  FlutterEngineProcTable table{};
  table.struct_size = sizeof(table);
  const FlutterEngineResult result =
      reinterpret_cast<GetProcAddressesFn>(symbol)(&table);
  if (result != kSuccess) {
    if (error != nullptr) {
      *error = "FlutterEngineGetProcAddresses rejected " + path +
               " with result " + std::to_string(static_cast<int>(result));
    }
    dlclose(handle);
    return false;
  }

  if (!required_procs_present(table, error)) {
    dlclose(handle);
    return false;
  }

  handle_ = handle;
  path_ = path;
  procs_ = table;
  return true;
}

void EngineLibrary::unload() {
  if (handle_ != nullptr) {
    dlclose(handle_);
  }
  handle_ = nullptr;
  path_.clear();
  std::memset(&procs_, 0, sizeof(procs_));
}

}  // namespace pluto
