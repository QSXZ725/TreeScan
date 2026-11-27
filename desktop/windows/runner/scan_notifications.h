#ifndef RUNNER_SCAN_NOTIFICATIONS_H_
#define RUNNER_SCAN_NOTIFICATIONS_H_

#include <windows.h>

#include <string>

inline constexpr UINT kActivateScanNotification = WM_APP + 1;

void SetScanNotificationIdentity();
DWORD RegisterScanNotificationActivator(HWND window);

struct ScanNotificationResult {
  HRESULT status;
  const char* step;
  bool disabled = false;
};

ScanNotificationResult ShowScanNotification(HWND window,
                                            const std::wstring& message,
                                            bool test);

#endif  // RUNNER_SCAN_NOTIFICATIONS_H_
