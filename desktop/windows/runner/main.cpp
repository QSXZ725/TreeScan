#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "crash_log.h"
#include "flutter_window.h"
#include "scan_notifications.h"
#include "utils.h"

namespace {

bool RequiresReadOnlyScan() {
  HANDLE token = nullptr;
  if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return true;
  TOKEN_ELEVATION elevation{};
  DWORD bytes = 0;
  const BOOL queried = GetTokenInformation(token, TokenElevation, &elevation,
                                           sizeof(elevation), &bytes);
  CloseHandle(token);
  return !queried || elevation.TokenIsElevated != 0;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  std::vector<std::string> command_line_arguments = GetCommandLineArguments();
  const bool requested_read_only = !command_line_arguments.empty() &&
      command_line_arguments.front() == "--read-only-scan";
  const bool read_only_scan = requested_read_only || RequiresReadOnlyScan();
  if (!read_only_scan) InstallNativeCrashLog();
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (!read_only_scan) SetScanNotificationIdentity();

  flutter::DartProject project(L"data");
  const auto graphics = read_only_scan ? std::string() : ReadGraphicsPreference();
  if (graphics == "powerSaving") {
    project.set_gpu_preference(flutter::GpuPreference::LowPowerPreference);
  } else if (graphics == "highPerformance") {
    project.set_gpu_preference(flutter::GpuPreference::HighPerformancePreference);
  }

  if (read_only_scan && !requested_read_only) {
    command_line_arguments.insert(command_line_arguments.begin(),
                                  "--read-only-scan");
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project, read_only_scan);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1180, 760);
  if (!window.Create(L"TreeScan", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
