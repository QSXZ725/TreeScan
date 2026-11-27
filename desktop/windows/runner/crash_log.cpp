#include "crash_log.h"

#include <windows.h>

#include <cstdio>

#include "utils.h"

namespace {

wchar_t report_path[32768]{};
LPTOP_LEVEL_EXCEPTION_FILTER previous_filter = nullptr;

unsigned long long UnixMillis() {
  FILETIME value{};
  GetSystemTimeAsFileTime(&value);
  ULARGE_INTEGER combined{};
  combined.LowPart = value.dwLowDateTime;
  combined.HighPart = value.dwHighDateTime;
  return (combined.QuadPart - 116444736000000000ULL) / 10000;
}

LONG WINAPI RecordUnhandledException(EXCEPTION_POINTERS* exception) {
  // The path was prepared at startup. Save only the native exception code.
  const HANDLE file = CreateFileW(report_path, GENERIC_WRITE, FILE_SHARE_READ,
                                  nullptr, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file != INVALID_HANDLE_VALUE) {
    char event[512]{};
    const int length = sprintf_s(
        event, "{\"schemaVersion\":1,\"timestampMs\":%llu,"
               "\"platform\":\"windows\",\"version\":\"%d.%d.%d+%d\","
               "\"source\":\"windows-native\",\"type\":\"0x%08lX\"}\n",
        UnixMillis(), FLUTTER_VERSION_MAJOR, FLUTTER_VERSION_MINOR,
        FLUTTER_VERSION_PATCH, FLUTTER_VERSION_BUILD,
        exception->ExceptionRecord->ExceptionCode);
    if (length > 0) {
      DWORD written = 0;
      WriteFile(file, event, static_cast<DWORD>(length), &written, nullptr);
    }
    CloseHandle(file);
  }
  return previous_filter ? previous_filter(exception) : EXCEPTION_CONTINUE_SEARCH;
}

}  // namespace

void InstallNativeCrashLog() {
  const auto settings = AppSettingsDirectory();
  if (settings.empty()) return;
  const auto folder = settings / L"crash-reports";
  std::error_code error;
  std::filesystem::create_directories(folder, error);
  if (error) return;
  const auto path = folder / (
      L"native-" + std::to_wstring(UnixMillis()) + L"-" +
      std::to_wstring(GetCurrentProcessId()) + L".json");
  if (wcsncpy_s(report_path, path.c_str(), ARRAYSIZE(report_path) - 1) != 0) return;
  previous_filter = SetUnhandledExceptionFilter(RecordUnhandledException);
}
