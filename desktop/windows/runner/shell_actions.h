#ifndef RUNNER_SHELL_ACTIONS_H_
#define RUNNER_SHELL_ACTIONS_H_

#include <windows.h>

#include <string>
#include <vector>

struct WslDisk {
  std::wstring name;
  std::wstring location;
  std::wstring image;
};

std::vector<WslDisk> RegisteredWslDisks();
bool HasClipboardFiles();
HRESULT FileAction(HWND window, const std::string& action,
                   const std::wstring& path,
                   std::vector<std::wstring>* changed_locations);

#endif  // RUNNER_SHELL_ACTIONS_H_
