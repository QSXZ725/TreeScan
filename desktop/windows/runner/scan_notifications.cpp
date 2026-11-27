#include "scan_notifications.h"

#include <NotificationActivationCallback.h>
#include <propkey.h>
#include <shlobj.h>
#include <windows.data.xml.dom.h>
#include <windows.ui.notifications.h>
#include <wrl.h>
#include <wrl/wrappers/corewrappers.h>

#include <filesystem>

namespace {

using Microsoft::WRL::ClassicCom;
using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Make;
using Microsoft::WRL::RuntimeClass;
using Microsoft::WRL::RuntimeClassFlags;
using Microsoft::WRL::Wrappers::HStringReference;
using Microsoft::WRL::Wrappers::RoInitializeWrapper;
namespace XML = ABI::Windows::Data::Xml::Dom;
namespace Toast = ABI::Windows::UI::Notifications;

// The installed app and the movable bundle use different shell identities.
constexpr CLSID kInstalledActivator = {
    0xcef39dad, 0xbbc2, 0x4e53, {0x9e, 0xba, 0x44, 0x9b, 0x2d, 0x1f, 0x2e, 0x52}};
constexpr CLSID kPortableActivator = {
    0xd597583c, 0x7d17, 0x497e, {0x91, 0xaf, 0x26, 0xe7, 0x14, 0x5d, 0xcb, 0x13}};

struct Identity {
  std::filesystem::path executable;
  bool portable = false;

  const wchar_t* AppId() const {
    return portable ? L"TreeScan.Desktop.Portable" : L"TreeScan.Desktop";
  }
  const wchar_t* Name() const {
    return portable ? L"TreeScan (Portable)" : L"TreeScan";
  }
  const CLSID& Activator() const {
    return portable ? kPortableActivator : kInstalledActivator;
  }
};

const Identity& AppIdentity() {
  static const auto identity = [] {
    std::wstring path(32768, L'\0');
    const DWORD length = GetModuleFileNameW(nullptr, path.data(),
                                           static_cast<DWORD>(path.size()));
    if (!length || length >= path.size()) return Identity{};
    path.resize(length);
    std::filesystem::path executable(path);
    std::error_code error;
    const bool portable = std::filesystem::exists(
        executable.parent_path() / L"TreeScan.portable", error);
    return Identity{std::move(executable), portable};
  }();
  return identity;
}

class NotificationCallback final
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>,
                          INotificationActivationCallback> {
 public:
  explicit NotificationCallback(HWND window) : window_(window) {}

  HRESULT STDMETHODCALLTYPE Activate(LPCWSTR app_id, LPCWSTR,
                                     const NOTIFICATION_USER_INPUT_DATA*,
                                     ULONG) override {
    if (!app_id || wcscmp(app_id, AppIdentity().AppId()) != 0) return E_INVALIDARG;
    return PostMessageW(window_, kActivateScanNotification, 0, 0)
               ? S_OK
               : HRESULT_FROM_WIN32(GetLastError());
  }

 private:
  HWND window_;
};

class NotificationFactory final
    : public RuntimeClass<RuntimeClassFlags<ClassicCom>, IClassFactory> {
 public:
  explicit NotificationFactory(HWND window) : window_(window) {}

  HRESULT STDMETHODCALLTYPE CreateInstance(IUnknown* outer, REFIID iid,
                                           void** object) override {
    *object = nullptr;
    if (outer) return CLASS_E_NOAGGREGATION;
    const auto callback = Make<NotificationCallback>(window_);
    return callback ? callback.CopyTo(iid, object) : E_OUTOFMEMORY;
  }

  HRESULT STDMETHODCALLTYPE LockServer(BOOL) override { return S_OK; }

 private:
  HWND window_;
};

HRESULT WriteRegistration(const std::wstring& key, const wchar_t* name,
                          const std::wstring& value) {
  return HRESULT_FROM_WIN32(RegSetKeyValueW(
      HKEY_CURRENT_USER, key.c_str(), name, REG_SZ, value.c_str(),
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))));
}

HRESULT RegisterIdentity(const Identity& identity) {
  if (identity.executable.empty()) return E_FAIL;
  wchar_t guid[39]{};
  if (!StringFromGUID2(identity.Activator(), guid, ARRAYSIZE(guid))) return E_FAIL;
  const std::wstring activator =
      std::wstring(L"Software\\Classes\\CLSID\\") + guid + L"\\LocalServer32";
  HRESULT status = WriteRegistration(
      activator, nullptr, L"\"" + identity.executable.wstring() + L"\" -Embedding");
  if (FAILED(status)) return status;
  const std::wstring app = std::wstring(L"Software\\Classes\\AppUserModelId\\") +
                           identity.AppId();
  status = WriteRegistration(app, L"DisplayName", identity.Name());
  if (FAILED(status)) return status;
  status = WriteRegistration(app, L"IconUri", (identity.executable.parent_path() /
      L"data/flutter_assets/assets/treescan-logo.png").wstring());
  if (FAILED(status)) return status;
  return WriteRegistration(app, L"CustomActivator", guid);
}

bool ShortcutMatches(const std::filesystem::path& shortcut,
                     const Identity& identity) {
  ComPtr<IShellLinkW> link;
  ComPtr<IPersistFile> file;
  ComPtr<IPropertyStore> properties;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&link))) ||
      FAILED(link.As(&file)) || FAILED(file->Load(shortcut.c_str(), STGM_READ)) ||
      FAILED(link.As(&properties))) {
    return false;
  }
  wchar_t target[MAX_PATH]{};
  PROPVARIANT id{}, activator{};
  const bool matches =
      SUCCEEDED(link->GetPath(target, ARRAYSIZE(target), nullptr, SLGP_RAWPATH)) &&
      _wcsicmp(target, identity.executable.c_str()) == 0 &&
      SUCCEEDED(properties->GetValue(PKEY_AppUserModel_ID, &id)) &&
      id.vt == VT_LPWSTR && id.pwszVal &&
      wcscmp(id.pwszVal, identity.AppId()) == 0 &&
      SUCCEEDED(properties->GetValue(PKEY_AppUserModel_ToastActivatorCLSID, &activator)) &&
      activator.vt == VT_CLSID && activator.puuid &&
      IsEqualCLSID(*activator.puuid, identity.Activator());
  PropVariantClear(&id);
  PropVariantClear(&activator);
  return matches;
}

ScanNotificationResult EnsureShortcut(const std::filesystem::path& shortcut,
                                      const Identity& identity) {
  if (ShortcutMatches(shortcut, identity)) return {S_OK, "start-menu"};
  const bool replacing = GetFileAttributesW(shortcut.c_str()) != INVALID_FILE_ATTRIBUTES;
  // A link loaded with STGM_READ has a read-only property store. Persist a
  // fresh link so an older MSI shortcut can be repaired without modifying it in place.
  ComPtr<IShellLinkW> link;
  HRESULT status = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                    IID_PPV_ARGS(&link));
  if (FAILED(status)) return {status, "start-menu-link"};
  status = link->SetPath(identity.executable.c_str());
  if (FAILED(status)) return {status, "start-menu-target"};
  status = link->SetWorkingDirectory(identity.executable.parent_path().c_str());
  if (FAILED(status)) return {status, "start-menu-target"};
  status = link->SetDescription(identity.Name());
  if (FAILED(status)) return {status, "start-menu-target"};
  ComPtr<IPropertyStore> properties;
  status = link.As(&properties);
  if (FAILED(status)) return {status, "start-menu-properties"};
  PROPVARIANT id{};
  id.vt = VT_LPWSTR;
  id.pwszVal = const_cast<PWSTR>(identity.AppId());
  status = properties->SetValue(PKEY_AppUserModel_ID, id);
  if (FAILED(status)) return {status, "start-menu-properties"};
  CLSID guid = identity.Activator();
  PROPVARIANT activator{};
  activator.vt = VT_CLSID;
  activator.puuid = &guid;
  status = properties->SetValue(PKEY_AppUserModel_ToastActivatorCLSID, activator);
  if (FAILED(status)) return {status, "start-menu-properties"};
  ComPtr<IPersistFile> file;
  status = link.As(&file);
  if (FAILED(status)) return {status, "start-menu-save"};
  const auto pending = shortcut.parent_path() /
      (L".TreeScan-" + std::to_wstring(GetCurrentProcessId()) + L"-" +
       std::to_wstring(GetTickCount64()) + L".lnk");
  status = file->Save(pending.c_str(), FALSE);
  if (SUCCEEDED(status) &&
      !MoveFileExW(pending.c_str(), shortcut.c_str(),
                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
    status = HRESULT_FROM_WIN32(GetLastError());
  }
  if (FAILED(status)) {
    DeleteFileW(pending.c_str());
    return {status, "start-menu-save"};
  }
  SHChangeNotify(replacing ? SHCNE_UPDATEITEM : SHCNE_CREATE,
                 SHCNF_PATHW | SHCNF_FLUSHNOWAIT, shortcut.c_str(), nullptr);
  return {S_OK, "start-menu"};
}

ScanNotificationResult RegisterShortcut(const Identity& identity) {
  PWSTR folder = nullptr;
  const HRESULT status = SHGetKnownFolderPath(
      FOLDERID_Programs, KF_FLAG_CREATE, nullptr, &folder);
  if (FAILED(status)) return {status, "start-menu-folder"};
  const auto shortcut = std::filesystem::path(folder) /
                        (std::wstring(identity.Name()) + L".lnk");
  CoTaskMemFree(folder);
  return EnsureShortcut(shortcut, identity);
}

std::wstring EscapeText(const std::wstring& text) {
  std::wstring escaped;
  for (const wchar_t character : text) {
    switch (character) {
      case L'&': escaped += L"&amp;"; break;
      case L'<': escaped += L"&lt;"; break;
      case L'>': escaped += L"&gt;"; break;
      default: escaped += character; break;
    }
  }
  return escaped;
}

ScanNotificationResult SubmitToast(Toast::IToastNotifier& notifier,
                                   Toast::IToastNotification* toast) {
  // A desktop identity can return ERROR_NOT_FOUND before its first toast.
  // Use the submission result when Windows cannot read the setting.
  Toast::NotificationSetting setting{};
  if (SUCCEEDED(notifier.get_Setting(&setting)) &&
      setting != Toast::NotificationSetting_Enabled) {
    return {HRESULT_FROM_WIN32(ERROR_ACCESS_DISABLED_BY_POLICY),
            "notification-setting", true};
  }
  return {notifier.Show(toast), "toast-show"};
}

}  // namespace

void SetScanNotificationIdentity() {
  SetCurrentProcessExplicitAppUserModelID(AppIdentity().AppId());
}

DWORD RegisterScanNotificationActivator(HWND window) {
  const auto factory = Make<NotificationFactory>(window);
  DWORD cookie = 0;
  if (factory) {
    CoRegisterClassObject(AppIdentity().Activator(), factory.Get(),
                          CLSCTX_LOCAL_SERVER, REGCLS_MULTIPLEUSE, &cookie);
  }
  return cookie;
}

ScanNotificationResult ShowScanNotification(HWND window,
                                            const std::wstring& message,
                                            bool test) {
  if (message.empty()) return {E_INVALIDARG, "message"};
  DWORD foreground_process = 0;
  if (const HWND foreground = GetForegroundWindow()) {
    GetWindowThreadProcessId(foreground, &foreground_process);
  }
  if (!test && !IsIconic(window) && foreground_process == GetCurrentProcessId()) {
    return {S_FALSE, "foreground"};
  }

  RoInitializeWrapper apartment(RO_INIT_SINGLETHREADED);
  HRESULT status = apartment;
  if (FAILED(status)) return {status, "WinRT"};
  const auto& identity = AppIdentity();
  status = RegisterIdentity(identity);
  if (FAILED(status)) return {status, "app-identity"};
  const auto shortcut = RegisterShortcut(identity);
  if (FAILED(shortcut.status)) return shortcut;

  ComPtr<Toast::IToastNotificationManagerStatics> manager;
  status = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotificationManager).Get(),
      IID_PPV_ARGS(&manager));
  if (FAILED(status)) return {status, "toast-manager"};
  ComPtr<Toast::IToastNotifier> notifier;
  status = manager->CreateToastNotifierWithId(HStringReference(identity.AppId()).Get(),
                                             &notifier);
  if (FAILED(status)) return {status, "toast-notifier"};

  ComPtr<IInspectable> document;
  status = RoActivateInstance(
      HStringReference(RuntimeClass_Windows_Data_Xml_Dom_XmlDocument).Get(),
      &document);
  if (FAILED(status)) return {status, "toast-xml"};
  ComPtr<XML::IXmlDocumentIO> loader;
  status = document.As(&loader);
  if (FAILED(status)) return {status, "toast-xml"};
  const auto xml = std::wstring(L"<toast launch='scan'><visual><binding template='ToastGeneric'>"
                               L"<text>TreeScan</text><text>") +
                   EscapeText(message) + L"</text></binding></visual></toast>";
  status = loader->LoadXml(HStringReference(xml.c_str()).Get());
  if (FAILED(status)) return {status, "toast-xml"};
  ComPtr<XML::IXmlDocument> content;
  status = document.As(&content);
  if (FAILED(status)) return {status, "toast-xml"};
  ComPtr<Toast::IToastNotificationFactory> factory;
  status = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_UI_Notifications_ToastNotification).Get(),
      IID_PPV_ARGS(&factory));
  if (FAILED(status)) return {status, "toast-factory"};
  ComPtr<Toast::IToastNotification> toast;
  status = factory->CreateToastNotification(content.Get(), &toast);
  if (FAILED(status)) return {status, "toast-create"};
  return SubmitToast(*notifier.Get(), toast.Get());
}
