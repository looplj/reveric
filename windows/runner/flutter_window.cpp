#include "flutter_window.h"

#include <windows.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "crash_handler.h"
#include "utils.h"

namespace {

DWORD WINAPI ForceTrayExitAfterDeadline(LPVOID) {
  Sleep(5000);
  // Do not run destructors or wait for the Flutter/UI thread during forced exit.
  TerminateProcess(GetCurrentProcess(), 1);
  return 0;
}

int CALLBACK CollectFontFamily(
    const LOGFONTW* log_font,
    const TEXTMETRICW* text_metric,
    DWORD font_type,
    LPARAM lparam) {
  auto* fonts = reinterpret_cast<std::set<std::wstring>*>(lparam);
  const std::wstring family(log_font->lfFaceName);
  if (!family.empty() && family[0] != L'@') {
    fonts->insert(family);
  }
  return 1;
}

std::string WideStringToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return {};
  }

  int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, nullptr, 0,
                                nullptr, nullptr);
  if (size <= 0) {
    return {};
  }

  std::string result(size - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(), -1, result.data(), size,
                      nullptr, nullptr);
  return result;
}

std::vector<flutter::EncodableValue> ListSystemFontFamilies() {
  std::set<std::wstring> font_names;
  HDC hdc = GetDC(nullptr);
  if (!hdc) {
    return {};
  }

  LOGFONTW log_font = {};
  log_font.lfCharSet = DEFAULT_CHARSET;
  EnumFontFamiliesExW(
      hdc, &log_font, CollectFontFamily,
      reinterpret_cast<LPARAM>(&font_names), 0);
  ReleaseDC(nullptr, hdc);

  std::vector<flutter::EncodableValue> fonts;
  fonts.reserve(font_names.size());
  for (const auto& font_name : font_names) {
    const std::string utf8_font_name = WideStringToUtf8(font_name);
    if (!utf8_font_name.empty()) {
      fonts.emplace_back(utf8_font_name);
    }
  }
  return fonts;
}

const flutter::EncodableValue* FindArgument(
    const flutter::EncodableMap& arguments,
    const std::string& name) {
  const auto iterator = arguments.find(flutter::EncodableValue(name));
  return iterator == arguments.end() ? nullptr : &iterator->second;
}

std::optional<int64_t> GetInt64Argument(
    const flutter::EncodableMap& arguments,
    const std::string& name) {
  const auto* value = FindArgument(arguments, name);
  if (!value) {
    return std::nullopt;
  }
  if (const auto* int64_value = std::get_if<int64_t>(value)) {
    return *int64_value;
  }
  if (const auto* int32_value = std::get_if<int32_t>(value)) {
    return static_cast<int64_t>(*int32_value);
  }
  return std::nullopt;
}

std::optional<double> GetDoubleArgument(
    const flutter::EncodableMap& arguments,
    const std::string& name) {
  const auto* value = FindArgument(arguments, name);
  if (!value) {
    return std::nullopt;
  }
  if (const auto* double_value = std::get_if<double>(value)) {
    return *double_value;
  }
  if (const auto* int64_value = std::get_if<int64_t>(value)) {
    return static_cast<double>(*int64_value);
  }
  if (const auto* int32_value = std::get_if<int32_t>(value)) {
    return static_cast<double>(*int32_value);
  }
  return std::nullopt;
}

std::optional<POINT> ClampWindowPositionToVisibleWorkArea(
    HWND window,
    double requested_x,
    double requested_y) {
  RECT window_rect;
  if (!GetWindowRect(window, &window_rect)) {
    return std::nullopt;
  }

  const LONG width = window_rect.right - window_rect.left;
  const LONG height = window_rect.bottom - window_rect.top;
  const LONG requested_left = static_cast<LONG>(std::lround(requested_x));
  const LONG requested_top = static_cast<LONG>(std::lround(requested_y));
  RECT requested_rect = {
      requested_left,
      requested_top,
      requested_left + width,
      requested_top + height,
  };
  const HMONITOR monitor =
      MonitorFromRect(&requested_rect, MONITOR_DEFAULTTONEAREST);
  MONITORINFO monitor_info = {};
  monitor_info.cbSize = sizeof(monitor_info);
  if (!monitor || !GetMonitorInfo(monitor, &monitor_info)) {
    return std::nullopt;
  }

  const RECT& work_area = monitor_info.rcWork;
  const LONG maximum_left =
      std::max(work_area.left, work_area.right - width);
  const LONG maximum_top =
      std::max(work_area.top, work_area.bottom - height);
  return POINT{
      std::clamp(requested_left, work_area.left, maximum_left),
      std::clamp(requested_top, work_area.top, maximum_top),
  };
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

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
  process_exit_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "reveric/process_exit",
          &flutter::StandardMethodCodec::GetInstance());
  process_exit_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "arm") {
          result->NotImplemented();
          return;
        }
        // Handlers run on the platform thread. Repeated requests never reset
        // the deadline; the worker outlives the window and Flutter engine.
        static bool armed = false;
        if (!armed) {
          HANDLE worker = CreateThread(nullptr, 0, ForceTrayExitAfterDeadline,
                                       nullptr, 0, nullptr);
          if (!worker) {
            result->Error("exit_watchdog_failed", "Unable to arm exit deadline");
            return;
          }
          CloseHandle(worker);
          armed = true;
        }
        result->Success();
      });
  director_storage_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(flutter_controller_->engine()->messenger(), "ai.reveric.director/storage", &flutter::StandardMethodCodec::GetInstance());
  director_storage_channel_->SetMethodCallHandler([](const flutter::MethodCall<flutter::EncodableValue>& call, std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
    if (call.method_name() != "availableBytes") { result->NotImplemented(); return; }
    const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
    if (!args) { result->Error("storage_probe_failed"); return; }
    const auto* value = FindArgument(*args, "path");
    if (!value || !std::holds_alternative<std::string>(*value)) { result->Error("storage_probe_failed"); return; }
    const auto wide = Utf16FromUtf8(std::get<std::string>(*value));
    ULARGE_INTEGER bytes;
    if (!GetDiskFreeSpaceExW(wide.c_str(), &bytes, nullptr, nullptr)) { result->Error("storage_probe_failed"); return; }
    result->Success(flutter::EncodableValue(static_cast<int64_t>(bytes.QuadPart)));
  });
  system_fonts_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "reveric/system_fonts",
          &flutter::StandardMethodCodec::GetInstance());
  system_fonts_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() != "listFontFamilies") {
          result->NotImplemented();
          return;
        }
        result->Success(flutter::EncodableValue(ListSystemFontFamilies()));
      });
  window_position_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "reveric/window_position",
          &flutter::StandardMethodCodec::GetInstance());
  window_position_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const auto* arguments =
            std::get_if<flutter::EncodableMap>(call.arguments());
        if (!arguments) {
          result->Error("bad_args", "Missing native window arguments.");
          return;
        }
        const auto handle = GetInt64Argument(*arguments, "windowHandle");
        if (!handle) {
          result->Error("bad_args", "Missing native window handle.");
          return;
        }
        const HWND window =
            reinterpret_cast<HWND>(static_cast<intptr_t>(*handle));
        if (!IsWindow(window)) {
          result->Error("invalid_window", "Native window handle is invalid.");
          return;
        }

        if (call.method_name() == "getPosition") {
          RECT window_rect;
          if (!GetWindowRect(window, &window_rect)) {
            result->Error("get_position_failed",
                          "Failed to read native window position.");
            return;
          }
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("x"),
               flutter::EncodableValue(static_cast<double>(window_rect.left))},
              {flutter::EncodableValue("y"),
               flutter::EncodableValue(static_cast<double>(window_rect.top))},
          }));
          return;
        }

        if (call.method_name() == "setPosition") {
          const auto x = GetDoubleArgument(*arguments, "x");
          const auto y = GetDoubleArgument(*arguments, "y");
          if (!x || !y) {
            result->Error("bad_args", "Missing native window position.");
            return;
          }
          const auto position =
              ClampWindowPositionToVisibleWorkArea(window, *x, *y);
          if (!position ||
              !SetWindowPos(window, nullptr, position->x, position->y, 0, 0,
                            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE)) {
            result->Error("set_position_failed",
                          "Failed to restore native window position.");
            return;
          }
          result->Success();
          return;
        }

        if (call.method_name() == "setAlwaysOnTop") {
          const auto* raw_value = FindArgument(*arguments, "value");
          const bool* value =
              raw_value ? std::get_if<bool>(raw_value) : nullptr;
          if (!value) {
            result->Error("bad_args", "Missing always-on-top value.");
            return;
          }
          if (!SetWindowPos(window, *value ? HWND_TOPMOST : HWND_NOTOPMOST, 0,
                            0, 0, 0,
                            SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE)) {
            result->Error("set_always_on_top_failed",
                          "Failed to change native window z-order.");
            return;
          }
          result->Success();
          return;
        }

        result->NotImplemented();
      });
  crash_reporting_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "reveric/crash_reporting",
          &flutter::StandardMethodCodec::GetInstance());
  crash_reporting_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        if (call.method_name() == "configure") {
          // Dart 侧传入会话哨兵文件路径；正常退出（消息循环结束）时原生侧删除它，
          // 残留即表示上次会话异常终止。
          const auto* arguments =
              std::get_if<flutter::EncodableMap>(call.arguments());
          if (arguments) {
            const auto* value = FindArgument(*arguments, "sessionMarkerPath");
            if (value) {
              if (const auto* path = std::get_if<std::string>(value)) {
                const auto* token_value = FindArgument(*arguments, "sessionToken");
                if (token_value) {
                  if (const auto* token = std::get_if<std::string>(token_value)) {
                    crash_handler::SetSessionMarkerPath(Utf16FromUtf8(*path), *token);
                  }
                }
              }
            }
          }
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("crashDumpDir"),
               flutter::EncodableValue(
                   Utf8FromUtf16(crash_handler::GetCrashDumpDirectory()
                                     .c_str()))},
          }));
          return;
        }
        if (call.method_name() == "getCrashDumpDir") {
          result->Success(flutter::EncodableValue(
              Utf8FromUtf16(crash_handler::GetCrashDumpDirectory().c_str())));
          return;
        }
        result->NotImplemented();
      });
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
  process_exit_channel_.reset();
  director_storage_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // 查询关机不等于退出已发生；系统取消时撤销诊断状态。
  if (message == WM_QUERYENDSESSION) {
    crash_handler::RecordExitRequested("system");
  } else if (message == WM_ENDSESSION) {
    if (wparam) {
      crash_handler::RecordExitRequested("system");
      crash_handler::DeleteSessionMarker();
    } else {
      crash_handler::CancelSystemExit();
    }
  } else if (message == WM_DESTROY) {
    crash_handler::RecordExitRequested("window");
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
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
