#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <dxgi.h>
#include <shellapi.h>
#include <shlobj.h>
#include <wrl/client.h>

#include <iterator>
#include <limits>
#include <mutex>
#include <optional>
#include <string>
#include <type_traits>
#include <utility>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "scan_notifications.h"
#include "shell_actions.h"
#include "utils.h"

namespace {

using flutter::EncodableList;
using flutter::EncodableValue;
using flutter::MethodCall;
using flutter::MethodResult;

constexpr UINT kRunOnUiThread = WM_APP + 2;

struct UiClosure {
  virtual ~UiClosure() = default;
  virtual void Run() = 0;
};

template <typename Fn>
struct UiClosureImpl final : UiClosure {
  explicit UiClosureImpl(Fn&& fn) : fn_(std::move(fn)) {}
  void Run() override { fn_(); }
  Fn fn_;
};

}  // namespace

class UiTaskQueue {
 public:
  void Post(HWND window, std::unique_ptr<UiClosure> task) {
    const std::lock_guard lock(mutex_);
    if (closed_) return;
    pending_.push_back(std::move(task));
    // The message only wakes the UI thread. Its parameters are untrusted.
    if (!PostMessageW(window, kRunOnUiThread, 0, 0)) pending_.pop_back();
  }

  void Dispatch() {
    std::vector<std::unique_ptr<UiClosure>> tasks;
    {
      const std::lock_guard lock(mutex_);
      tasks.swap(pending_);
    }
    for (auto& task : tasks) {
      {
        const std::lock_guard lock(mutex_);
        if (closed_) return;
      }
      task->Run();
    }
  }

  void Close() {
    std::vector<std::unique_ptr<UiClosure>> dropped;
    const std::lock_guard lock(mutex_);
    closed_ = true;
    dropped.swap(pending_);
  }

 private:
  std::mutex mutex_;
  bool closed_ = false;
  std::vector<std::unique_ptr<UiClosure>> pending_;
};

namespace {

struct PoolTask {
  virtual ~PoolTask() = default;
  virtual void Run() = 0;
};

template <typename Fn>
struct PoolTaskImpl final : PoolTask {
  explicit PoolTaskImpl(Fn&& fn) : fn_(std::move(fn)) {}
  void Run() override { fn_(); }
  Fn fn_;
};

template <typename Fn>
PoolTask* MakePoolTask(Fn&& fn) {
  return new PoolTaskImpl<std::decay_t<Fn>>(std::forward<Fn>(fn));
}

VOID CALLBACK RunPoolTask(PTP_CALLBACK_INSTANCE, PVOID context) {
  std::unique_ptr<PoolTask> task(static_cast<PoolTask*>(context));
  task->Run();
}

template <typename Work, typename Reply>
void RunAsync(HWND hwnd, std::shared_ptr<UiTaskQueue> ui_tasks,
              std::unique_ptr<MethodResult<EncodableValue>> result,
              Work&& work, Reply&& reply) {
  auto* pool_task = MakePoolTask(
      [hwnd, queue = std::move(ui_tasks), out = std::move(result),
       fn_work = std::move(work), fn_reply = std::move(reply)]() mutable {
        auto complete = [out_ptr = std::move(out), reply_fn = std::move(fn_reply),
                         value = fn_work()]() mutable {
          reply_fn(*out_ptr, std::move(value));
        };
        queue->Post(hwnd, std::make_unique<UiClosureImpl<decltype(complete)>>(
                              std::move(complete)));
      });
  if (!TrySubmitThreadpoolCallback(RunPoolTask, pool_task, nullptr)) {
    std::unique_ptr<PoolTask> fallback(pool_task);
    fallback->Run();
  }
}

template <typename Visitor>
void ForEachLocalVolume(Visitor&& visit) {
  const DWORD drives = GetLogicalDrives();
  wchar_t root[] = L"A:\\";
  for (DWORD index = 0; index < 26; ++index) {
    if (!(drives & (1UL << index))) continue;
    root[0] = static_cast<wchar_t>(L'A' + index);
    const UINT type = GetDriveTypeW(root);
    if (type != DRIVE_FIXED && type != DRIVE_REMOVABLE) continue;
    wchar_t label[MAX_PATH + 1]{};
    if (GetVolumeInformationW(root, label, static_cast<DWORD>(std::size(label)),
                              nullptr, nullptr, nullptr, nullptr, 0)) {
      visit(root, label);
    }
  }
}

EncodableList LocalVolumes() {
  EncodableList volumes;
  ForEachLocalVolume([&volumes](const wchar_t* root, const wchar_t*) {
    volumes.emplace_back(Utf8FromUtf16(root));
  });
  return volumes;
}

EncodableList LocalVolumeDetails() {
  EncodableList volumes;
  ForEachLocalVolume([&volumes](const wchar_t* root, const wchar_t* label) {
    ULARGE_INTEGER available{}, total{}, free_bytes{};
    const BOOL has_space =
        GetDiskFreeSpaceExW(root, &available, &total, &free_bytes);
    flutter::EncodableMap entry{
        {EncodableValue("path"), EncodableValue(Utf8FromUtf16(root))},
        {EncodableValue("label"), EncodableValue(Utf8FromUtf16(label))},
    };
    const ULONGLONG max_i64 =
        static_cast<ULONGLONG>((std::numeric_limits<int64_t>::max)());
    if (has_space && total.QuadPart <= max_i64 &&
        available.QuadPart <= max_i64) {
      entry.emplace(EncodableValue("total"),
                    EncodableValue(static_cast<int64_t>(total.QuadPart)));
      entry.emplace(EncodableValue("free"),
                    EncodableValue(static_cast<int64_t>(available.QuadPart)));
    }
    volumes.emplace_back(std::move(entry));
  });
  return volumes;
}

std::optional<int64_t> WslHostAllocation(const std::wstring& path) {
  const HANDLE image = CreateFileW(path.c_str(), FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
      OPEN_EXISTING, FILE_FLAG_OPEN_NO_RECALL | FILE_FLAG_OPEN_REPARSE_POINT,
      nullptr);
  if (image == INVALID_HANDLE_VALUE) return std::nullopt;
  std::optional<int64_t> allocated;
  FILE_ATTRIBUTE_TAG_INFO attributes{};
  if (GetFileInformationByHandleEx(image, FileAttributeTagInfo, &attributes,
                                   sizeof(attributes))) {
    if (attributes.FileAttributes & (FILE_ATTRIBUTE_SPARSE_FILE | FILE_ATTRIBUTE_COMPRESSED)) {
      FILE_COMPRESSION_INFO info{};
      if (GetFileInformationByHandleEx(image, FileCompressionInfo, &info, sizeof(info)) &&
          info.CompressedFileSize.QuadPart >= 0) allocated = info.CompressedFileSize.QuadPart;
    } else {
      FILE_STANDARD_INFO info{};
      if (GetFileInformationByHandleEx(image, FileStandardInfo, &info, sizeof(info)) &&
          !info.Directory && info.AllocationSize.QuadPart >= 0) allocated = info.AllocationSize.QuadPart;
    }
  }
  CloseHandle(image);
  return allocated;
}

std::wstring WideFromUtf8(const std::string& text) {
  if (text.empty() || text.find('\0') != std::string::npos ||
      text.size() > 32767) return {};
  const int length = MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
      static_cast<int>(text.size()), nullptr, 0);
  if (length == 0) return {};
  std::wstring value(length, L'\0');
  if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                           static_cast<int>(text.size()), value.data(),
                           length)) return {};
  return value;
}

HRESULT Reveal(const std::wstring& path) {
  PIDLIST_ABSOLUTE item = nullptr;
  HRESULT status = SHParseDisplayName(path.c_str(), nullptr, &item, 0, nullptr);
  if (SUCCEEDED(status)) {
    status = SHOpenFolderAndSelectItems(item, 0, nullptr, 0);
  }
  CoTaskMemFree(item);
  return status;
}

std::wstring QuoteArgument(const std::wstring& text) {
  std::wstring out = L"\"";
  size_t slashes = 0;
  for (wchar_t character : text) {
    if (character == L'\\') {
      ++slashes;
      continue;
    }
    out.append(character == L'"' ? 2 * slashes + 1 : slashes, L'\\');
    out.push_back(character);
    slashes = 0;
  }
  out.append(2 * slashes, L'\\');
  return out + L"\"";
}

HRESULT Elevate(HWND window, const std::wstring& path) {
  std::wstring executable(32768, L'\0');
  const DWORD count = GetModuleFileNameW(
      nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (count == 0 || count >= executable.size()) {
    return HRESULT_FROM_WIN32(GetLastError());
  }
  executable.resize(count);
  const std::wstring parameters = L"--scan " + QuoteArgument(path);
  SHELLEXECUTEINFOW launch{};
  launch.cbSize = sizeof(launch);
  launch.hwnd = window;
  launch.lpVerb = L"runas";
  launch.lpFile = executable.c_str();
  launch.lpParameters = parameters.c_str();
  launch.nShow = SW_SHOWNORMAL;
  return ShellExecuteExW(&launch) ? S_OK : HRESULT_FROM_WIN32(GetLastError());
}

void HandleShell(HWND window, std::shared_ptr<UiTaskQueue> ui_tasks,
                 bool read_only_scan,
                 const MethodCall<EncodableValue>& call,
                 std::unique_ptr<MethodResult<EncodableValue>> result) {
  if (call.method_name() == "volumes") {
    RunAsync(
        window, std::move(ui_tasks), std::move(result),
        []() { return LocalVolumes(); },
        [](MethodResult<EncodableValue>& res, EncodableList volumes) {
          res.Success(EncodableValue(std::move(volumes)));
        });
    return;
  }
  if (call.method_name() == "volumeInfo") {
    RunAsync(
        window, std::move(ui_tasks), std::move(result),
        []() { return LocalVolumeDetails(); },
        [](MethodResult<EncodableValue>& res, EncodableList volumes) {
          res.Success(EncodableValue(std::move(volumes)));
        });
    return;
  }
  if (call.method_name() == "wslDisks") {
    RunAsync(
        window, std::move(ui_tasks), std::move(result),
        []() {
          EncodableList disks;
          for (const auto& disk : RegisteredWslDisks()) {
            disks.emplace_back(flutter::EncodableMap{
                {EncodableValue("name"),
                 EncodableValue(Utf8FromUtf16(disk.name.c_str()))},
                {EncodableValue("path"),
                 EncodableValue(Utf8FromUtf16(disk.location.c_str()))},
                {EncodableValue("image"),
                 EncodableValue(Utf8FromUtf16(disk.image.c_str()))},
            });
          }
          return disks;
        },
        [](MethodResult<EncodableValue>& res, EncodableList disks) {
          res.Success(EncodableValue(std::move(disks)));
        });
    return;
  }
  if (call.method_name() == "wslHostAllocation") {
    const auto* argument = call.arguments() ?
        std::get_if<std::string>(call.arguments()) : nullptr;
    std::wstring distro = argument ? WideFromUtf8(*argument) : L"";
    if (distro.empty()) {
      result->Success();
      return;
    }
    RunAsync(
        window, std::move(ui_tasks), std::move(result),
        [target = std::move(distro)]() -> std::optional<int64_t> {
          for (const auto& disk : RegisteredWslDisks()) {
            if (!disk.image.empty() &&
                _wcsicmp(disk.name.c_str(), target.c_str()) == 0) {
              return WslHostAllocation(disk.image);
            }
          }
          return std::nullopt;
        },
        [](MethodResult<EncodableValue>& res,
           std::optional<int64_t> allocated) {
          if (allocated) {
            res.Success(EncodableValue(*allocated));
          } else {
            res.Success();
          }
        });
    return;
  }
  if (call.method_name() == "hasClipboardFiles") {
    result->Success(EncodableValue(HasClipboardFiles()));
    return;
  }
  if (call.method_name() == "appVersion") {
    result->Success(EncodableValue(flutter::EncodableMap{
        {EncodableValue("version"), EncodableValue(FLUTTER_VERSION)},
        {EncodableValue("build"), EncodableValue(FLUTTER_VERSION_BUILD)},
    }));
    return;
  }
  const bool elevate = call.method_name() == "elevate";
  const bool reveal = call.method_name() == "reveal";
  const bool file_action = call.method_name() == "copy" || call.method_name() == "cut" ||
      call.method_name() == "paste" || call.method_name() == "delete" || call.method_name() == "open";
  if (!elevate && !reveal && !file_action) {
    result->NotImplemented();
    return;
  }
  if (read_only_scan) {
    result->Error("read-only-scan", "File and shell actions require the standard window");
    return;
  }
  const auto* argument = call.arguments() ?
      std::get_if<std::string>(call.arguments()) : nullptr;
  const std::wstring path = argument ? WideFromUtf8(*argument) : L"";
  if (path.empty()) {
    result->Error("path", "The file path is invalid");
    return;
  }
  std::vector<std::wstring> changed;
  const HRESULT status = file_action ? FileAction(window, call.method_name(), path, &changed)
      : elevate ? Elevate(window, path) : Reveal(path);
  const bool succeeded = SUCCEEDED(status) || status == HRESULT_FROM_WIN32(ERROR_CANCELLED);
  if (file_action) {
    EncodableList locations;
    for (const auto& value : changed) locations.emplace_back(Utf8FromUtf16(value.c_str()));
    flutter::EncodableMap response{
        {EncodableValue("changed"), EncodableValue(locations)},
    };
    if (!succeeded) {
      response.emplace(EncodableValue("error"), EncodableValue(static_cast<int32_t>(status)));
    }
    result->Success(EncodableValue(response));
  } else if (succeeded) {
    result->Success();
  } else {
    result->Error("shell", "Windows could not complete the action",
                  EncodableValue(static_cast<int32_t>(status)));
  }
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool read_only_scan)
    : project_(project), read_only_scan_(read_only_scan) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  ui_tasks_ = std::make_shared<UiTaskQueue>();
  if (!read_only_scan_) {
    notification_activator_ = RegisterScanNotificationActivator(GetHandle());
  }
  shell_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      flutter_controller_->engine()->messenger(), "org.treescan/windows",
      &flutter::StandardMethodCodec::GetInstance());
  shell_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const bool test = call.method_name() == "testScanNotification";
        if (test || call.method_name() == "scanCompleteNotification") {
          if (read_only_scan_) {
            result->Error("read-only-scan", "Notifications require the standard window");
            return;
          }
          const auto* message = call.arguments() ?
              std::get_if<std::string>(call.arguments()) : nullptr;
          std::wstring wide_message = message ? WideFromUtf8(*message) : L"";
          HWND hwnd = GetHandle();
          RunAsync(
              hwnd, ui_tasks_, std::move(result),
              [hwnd, text = std::move(wide_message), test]() {
                return ShowScanNotification(hwnd, text, test);
              },
              [test](MethodResult<EncodableValue>& res,
                     ScanNotificationResult notification) {
                if (test && FAILED(notification.status)) {
                  char details[96]{};
                  sprintf_s(details, "%s, 0x%08lX", notification.step,
                            static_cast<unsigned long>(notification.status));
                  res.Error(notification.disabled ? "notifications-disabled" :
                                                    "notification",
                            "Windows could not send the notification",
                            EncodableValue(details));
                } else if (test) {
                  res.Success();
                } else {
                  res.Success(EncodableValue(notification.status == S_OK));
                }
              });
          return;
        }
        if (call.method_name() == "titleTheme") {
          const auto* dark = call.arguments() ? std::get_if<bool>(call.arguments()) : nullptr;
          SetDarkTitle(dark ? std::optional<bool>(*dark) : std::nullopt);
          result->Success();
          return;
        }
        if (call.method_name() == "graphicsAdapter") {
          Microsoft::WRL::ComPtr<IDXGIAdapter> adapter;
          DXGI_ADAPTER_DESC info{};
          if (flutter_controller_->engine()->GetGraphicsAdapter(adapter.GetAddressOf()) &&
              adapter && SUCCEEDED(adapter->GetDesc(&info))) {
            result->Success(EncodableValue(Utf8FromUtf16(info.Description)));
          } else {
            result->Success();
          }
          return;
        }
        HandleShell(GetHandle(), ui_tasks_, read_only_scan_, call,
                    std::move(result));
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (ui_tasks_) ui_tasks_->Close();
  if (notification_activator_) {
    CoRevokeClassObject(notification_activator_);
    notification_activator_ = 0;
  }
  shell_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  if (message == kRunOnUiThread) {
    if (ui_tasks_) ui_tasks_->Dispatch();
    return 0;
  }
  if (message == kActivateScanNotification) {
    ShowWindow(hwnd, IsIconic(hwnd) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(hwnd);
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_GETMINMAXINFO: {
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      const UINT dpi = GetDpiForWindow(hwnd);
      info->ptMinTrackSize.x = MulDiv(920, dpi, USER_DEFAULT_SCREEN_DPI);
      info->ptMinTrackSize.y = MulDiv(560, dpi, USER_DEFAULT_SCREEN_DPI);
      return 0;
    }
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
