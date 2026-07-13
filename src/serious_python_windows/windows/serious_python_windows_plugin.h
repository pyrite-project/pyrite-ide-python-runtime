#ifndef FLUTTER_PLUGIN_SERIOUS_PYTHON_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_SERIOUS_PYTHON_WINDOWS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>

namespace serious_python_windows {

class SeriousPythonWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(
      flutter::PluginRegistrarWindows* registrar);

  SeriousPythonWindowsPlugin();
  virtual ~SeriousPythonWindowsPlugin();

  SeriousPythonWindowsPlugin(const SeriousPythonWindowsPlugin&) = delete;
  SeriousPythonWindowsPlugin& operator=(
      const SeriousPythonWindowsPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
};

}  // namespace serious_python_windows

#endif  // FLUTTER_PLUGIN_SERIOUS_PYTHON_WINDOWS_PLUGIN_H_
