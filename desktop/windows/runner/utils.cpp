#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <filesystem>
#include <fstream>
#include <iostream>
#include <regex>

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::filesystem::path AppSettingsDirectory() {
  std::wstring path(32768, L'\0');
  const DWORD length = GetModuleFileNameW(nullptr, path.data(),
                                          static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) return {};
  path.resize(length);
  const auto folder = std::filesystem::path(path).parent_path();
  std::error_code error;
  if (std::filesystem::exists(folder / L"TreeScan.portable", error)) return folder;
  const auto environment = [](const wchar_t* key) -> std::filesystem::path {
    std::wstring value(32768, L'\0');
    const DWORD count = GetEnvironmentVariableW(key, value.data(),
                                               static_cast<DWORD>(value.size()));
    if (count == 0 || count >= value.size()) return {};
    value.resize(count);
    return value;
  };
  auto base = environment(L"LOCALAPPDATA");
  if (base.empty()) base = environment(L"XDG_CONFIG_HOME");
  if (!base.empty()) return base / L"TreeScan";
  auto home_dir = environment(L"HOME");
  if (home_dir.empty()) home_dir = environment(L"USERPROFILE");
  if (home_dir.empty()) home_dir = std::filesystem::temp_directory_path(error);
  return home_dir.empty() ? std::filesystem::path{} :
      home_dir / L".config" / L"TreeScan";
}

std::string ReadGraphicsPreference() {
  const auto folder = AppSettingsDirectory();
  if (folder.empty()) return {};
  std::ifstream settings(folder / L"settings.json", std::ios::binary);
  if (!settings) return {};
  std::string contents(4096, '\0');
  settings.read(contents.data(), static_cast<std::streamsize>(contents.size()));
  contents.resize(static_cast<size_t>(settings.gcount()));
  const std::regex key(R"json("graphics"\s*:\s*"(powerSaving|highPerformance)")json");
  std::smatch match;
  return std::regex_search(contents, match, key) ? match[1].str() : std::string();
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  unsigned int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      -1, nullptr, 0, nullptr, nullptr)
    -1; // remove the trailing null character
  int input_length = (int)wcslen(utf16_string);
  std::string utf8_string;
  if (target_length == 0 || target_length > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
