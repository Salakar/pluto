#ifndef PLUTO_ENGINE_ENGINE_LOADER_H_
#define PLUTO_ENGINE_ENGINE_LOADER_H_

#include <string>

#include "flutter/embedder.h"

namespace pluto {

class EngineLibrary {
 public:
  EngineLibrary() = default;
  EngineLibrary(const EngineLibrary&) = delete;
  EngineLibrary& operator=(const EngineLibrary&) = delete;
  ~EngineLibrary();

  bool load(const std::string& path, std::string* error);
  void unload();

  bool loaded() const { return handle_ != nullptr; }
  const std::string& path() const { return path_; }
  const FlutterEngineProcTable& procs() const { return procs_; }

 private:
  void* handle_ = nullptr;
  std::string path_;
  FlutterEngineProcTable procs_{};
};

}  // namespace pluto

#endif  // PLUTO_ENGINE_ENGINE_LOADER_H_
