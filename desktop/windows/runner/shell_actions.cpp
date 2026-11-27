#include "shell_actions.h"

#include <shellapi.h>
#include <shlobj.h>
#include <wrl/client.h>

#include <cstring>
#include <filesystem>
#include <iterator>
#include <limits>
#include <utility>

namespace {

using Microsoft::WRL::ComPtr;

std::wstring RegistryString(HKEY key, const wchar_t* name) {
  DWORD length = 0;
  const DWORD flags = RRF_RT_REG_SZ;
  if (RegGetValueW(key, nullptr, name, flags, nullptr, nullptr, &length)
      != ERROR_SUCCESS || length < sizeof(wchar_t)) return {};
  std::wstring value(length / sizeof(wchar_t), L'\0');
  if (RegGetValueW(key, nullptr, name, flags, nullptr, value.data(), &length)
      != ERROR_SUCCESS) return {};
  value.resize(length / sizeof(wchar_t) - 1);
  return value;
}

UINT DropEffectFormat() {
  static const UINT format = RegisterClipboardFormatW(CFSTR_PREFERREDDROPEFFECT);
  return format;
}

class Clipboard {
 public:
  explicit Clipboard(HWND window) : opened_(OpenClipboard(window) != FALSE) {}
  ~Clipboard() { if (opened_) CloseClipboard(); }
  bool opened() const { return opened_; }

 private:
  bool opened_;
};

HRESULT ClipboardError() {
  const DWORD error = GetLastError();
  return HRESULT_FROM_WIN32(error == 0 ? ERROR_ACCESS_DENIED : error);
}

HRESULT CopyFilePath(HWND window, const std::wstring& path, bool move) {
  Clipboard clipboard(window);
  if (!clipboard.opened()) return ClipboardError();
  const size_t path_bytes = (path.size() + 2) * sizeof(wchar_t);
  HGLOBAL files = GlobalAlloc(GMEM_MOVEABLE | GMEM_ZEROINIT,
                               sizeof(DROPFILES) + path_bytes);
  HGLOBAL effect = GlobalAlloc(GMEM_MOVEABLE, sizeof(DWORD));
  if (!files || !effect) {
    if (files) GlobalFree(files);
    if (effect) GlobalFree(effect);
    return E_OUTOFMEMORY;
  }
  auto* drop = static_cast<DROPFILES*>(GlobalLock(files));
  auto* preference = static_cast<DWORD*>(GlobalLock(effect));
  if (!drop || !preference) {
    if (drop) GlobalUnlock(files);
    if (preference) GlobalUnlock(effect);
    GlobalFree(files);
    GlobalFree(effect);
    return E_OUTOFMEMORY;
  }
  drop->pFiles = sizeof(DROPFILES);
  drop->fWide = TRUE;
  std::memcpy(drop + 1, path.c_str(), (path.size() + 1) * sizeof(wchar_t));
  *preference = move ? DROPEFFECT_MOVE : DROPEFFECT_COPY;
  GlobalUnlock(files);
  GlobalUnlock(effect);

  if (!EmptyClipboard() || !SetClipboardData(CF_HDROP, files)) {
    const HRESULT status = ClipboardError();
    GlobalFree(files);
    GlobalFree(effect);
    return status;
  }
  if (!SetClipboardData(DropEffectFormat(), effect)) {
    const HRESULT status = ClipboardError();
    GlobalFree(effect);
    EmptyClipboard();
    return status;
  }
  return S_OK;
}

HRESULT ReadClipboardFiles(HWND window, std::vector<std::wstring>* paths,
                          bool* move, DWORD* clipboard_version) {
  Clipboard clipboard(window);
  if (!clipboard.opened()) return ClipboardError();
  const auto drop = static_cast<HDROP>(GetClipboardData(CF_HDROP));
  if (!drop) return HRESULT_FROM_WIN32(ERROR_NOT_FOUND);
  const UINT count = DragQueryFileW(drop, std::numeric_limits<UINT>::max(), nullptr, 0);
  for (UINT index = 0; index < count; ++index) {
    const UINT length = DragQueryFileW(drop, index, nullptr, 0);
    std::wstring path(static_cast<size_t>(length) + 1, L'\0');
    if (length == 0 || DragQueryFileW(drop, index, path.data(), length + 1) != length) {
      return E_INVALIDARG;
    }
    path.resize(length);
    paths->push_back(std::move(path));
  }
  *move = false;
  HGLOBAL format = GetClipboardData(DropEffectFormat());
  if (format && GlobalSize(format) >= sizeof(DWORD)) {
    const auto* value = static_cast<const DWORD*>(GlobalLock(format));
    if (value) {
      *move = (*value & DROPEFFECT_MOVE) != 0 && (*value & DROPEFFECT_COPY) == 0;
      GlobalUnlock(format);
    }
  }
  *clipboard_version = GetClipboardSequenceNumber();
  return paths->empty() ? HRESULT_FROM_WIN32(ERROR_NOT_FOUND) : S_OK;
}

HRESULT Item(const std::wstring& path, ComPtr<IShellItem>* item) {
  return SHCreateItemFromParsingName(path.c_str(), nullptr,
                                     IID_PPV_ARGS(item->ReleaseAndGetAddressOf()));
}

HRESULT Operation(HWND window, DWORD flags, ComPtr<IFileOperation>* operation) {
  HRESULT status = CoCreateInstance(CLSID_FileOperation, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(operation->ReleaseAndGetAddressOf()));
  if (FAILED(status)) return status;
  status = (*operation)->SetOwnerWindow(window);
  if (FAILED(status)) return status;
  return (*operation)->SetOperationFlags(flags | FOF_ALLOWUNDO | FOF_NOCONFIRMMKDIR);
}

HRESULT Perform(IFileOperation* operation, bool* aborted) {
  const HRESULT status = operation->PerformOperations();
  if (FAILED(status)) return status;
  BOOL any_aborted = FALSE;
  const HRESULT queried = operation->GetAnyOperationsAborted(&any_aborted);
  *aborted = any_aborted != FALSE;
  return queried;
}

HRESULT PasteFiles(HWND window, const std::wstring& destination,
                   std::vector<std::wstring>* changed) {
  std::vector<std::wstring> sources;
  DWORD clipboard_version = 0;
  bool move = false;
  HRESULT status = ReadClipboardFiles(window, &sources, &move, &clipboard_version);
  if (FAILED(status)) return status;
  ComPtr<IShellItem> folder;
  status = Item(destination, &folder);
  if (FAILED(status)) return status;
  SFGAOF attributes = 0;
  status = folder->GetAttributes(SFGAO_FOLDER | SFGAO_FILESYSTEM, &attributes);
  if (FAILED(status)) return status;
  if ((attributes & (SFGAO_FOLDER | SFGAO_FILESYSTEM)) != (SFGAO_FOLDER | SFGAO_FILESYSTEM)) {
    return HRESULT_FROM_WIN32(ERROR_DIRECTORY);
  }
  ComPtr<IFileOperation> operation;
  status = Operation(window, 0, &operation);
  if (FAILED(status)) return status;
  for (const auto& path : sources) {
    ComPtr<IShellItem> item;
    status = Item(path, &item);
    if (FAILED(status)) return status;
    status = move
        ? operation->MoveItem(item.Get(), folder.Get(), nullptr, nullptr)
        : operation->CopyItem(item.Get(), folder.Get(), nullptr, nullptr);
    if (FAILED(status)) return status;
  }
  bool aborted = false;
  status = Perform(operation.Get(), &aborted);
  changed->push_back(destination);
  if (move) {
    for (const auto& source : sources) {
      const size_t last = source.find_last_of(L"\\/");
      if (last != std::wstring::npos) changed->push_back(source.substr(0, last + 1));
    }
    if (SUCCEEDED(status) && !aborted) {
      Clipboard clipboard(window);
      if (clipboard.opened() && GetClipboardSequenceNumber() == clipboard_version) {
        EmptyClipboard();
      }
    }
  }
  return status;
}

HRESULT DeleteItem(HWND window, const std::wstring& path,
                   std::vector<std::wstring>* changed) {
  ComPtr<IShellItem> item;
  HRESULT status = Item(path, &item);
  if (FAILED(status)) return status;
  ComPtr<IFileOperation> operation;
  const bool unc = path.rfind(L"\\\\", 0) == 0 &&
                   path.rfind(L"\\\\?\\", 0) != 0;
  status = Operation(window, FOF_WANTNUKEWARNING | (unc ? 0 : FOFX_RECYCLEONDELETE), &operation);
  if (FAILED(status)) return status;
  status = operation->DeleteItem(item.Get(), nullptr);
  if (FAILED(status)) return status;
  bool aborted = false;
  status = Perform(operation.Get(), &aborted);
  const size_t last = path.find_last_of(L"\\/");
  if (last != std::wstring::npos) changed->push_back(path.substr(0, last + 1));
  return status;
}

}  // namespace

std::vector<WslDisk> RegisteredWslDisks() {
  std::vector<WslDisk> disks;
  HKEY registrations = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER,
      L"Software\\Microsoft\\Windows\\CurrentVersion\\Lxss", 0, KEY_READ,
      &registrations) != ERROR_SUCCESS) {
    return disks;
  }
  for (DWORD index = 0;; ++index) {
    wchar_t id[256];
    DWORD length = static_cast<DWORD>(std::size(id));
    const LSTATUS next = RegEnumKeyExW(registrations, index, id, &length,
                                      nullptr, nullptr, nullptr, nullptr);
    if (next != ERROR_SUCCESS) break;
    HKEY registration = nullptr;
    if (RegOpenKeyExW(registrations, id, 0, KEY_READ, &registration) != ERROR_SUCCESS) continue;
    DWORD version = 0;
    DWORD bytes = sizeof(version);
    if (RegGetValueW(registration, nullptr, L"Version", RRF_RT_REG_DWORD,
        nullptr, &version, &bytes) == ERROR_SUCCESS && version == 2) {
      const std::wstring name = RegistryString(registration, L"DistributionName");
      std::wstring base = RegistryString(registration, L"BasePath");
      std::wstring image = RegistryString(registration, L"VhdFileName");
      if (image.empty()) image = L"ext4.vhdx";
      if (!name.empty()) {
        disks.push_back({name, L"\\\\wsl.localhost\\" + name + L"\\",
                         base.empty() ? L"" : (std::filesystem::path(base) / image).wstring()});
      }
    }
    RegCloseKey(registration);
  }
  RegCloseKey(registrations);
  return disks;
}

bool HasClipboardFiles() { return IsClipboardFormatAvailable(CF_HDROP) != FALSE; }

HRESULT FileAction(HWND window, const std::string& action, const std::wstring& path,
                   std::vector<std::wstring>* changed_locations) {
  if (action == "copy" || action == "cut") return CopyFilePath(window, path, action == "cut");
  if (action == "paste") return PasteFiles(window, path, changed_locations);
  if (action == "delete") return DeleteItem(window, path, changed_locations);
  if (action == "open") {
    SHELLEXECUTEINFOW info{};
    info.cbSize = sizeof(info);
    info.hwnd = window;
    info.lpVerb = L"open";
    info.lpFile = path.c_str();
    info.nShow = SW_SHOWNORMAL;
    return ShellExecuteExW(&info) ? S_OK : HRESULT_FROM_WIN32(GetLastError());
  }
  return E_INVALIDARG;
}
