#include "flutter_window.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <propkey.h>
#include <propsys.h>
#include <shlwapi.h>
#include <shobjidl.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <algorithm>
#include <cctype>
#include <cstdint>
#include <cwctype>
#include <filesystem>
#include <optional>
#include <vector>

#include "flutter/generated_plugin_registrant.h"
#include "utils.h"

namespace {

using Microsoft::WRL::ComPtr;

const char kMediaOpenChannel[] = "c2pa_viewer/media_open";
const char kMediaProbeChannel[] = "c2pa_viewer/media_probe";

std::optional<std::string> GetPath(const flutter::MethodCall<>& call) {
  const auto* arguments = std::get_if<flutter::EncodableMap>(call.arguments());
  if (!arguments) return std::nullopt;
  const auto iterator = arguments->find(flutter::EncodableValue("path"));
  if (iterator == arguments->end()) return std::nullopt;
  const auto* path = std::get_if<std::string>(&iterator->second);
  return path ? std::optional<std::string>(*path) : std::nullopt;
}

bool IsPhoto(const std::wstring& path) {
  std::wstring extension = std::filesystem::path(path).extension().wstring();
  std::transform(extension.begin(), extension.end(), extension.begin(),
                 [](wchar_t character) {
                   return static_cast<wchar_t>(std::towlower(character));
                 });
  return extension == L".jpg" || extension == L".jpeg" ||
         extension == L".png" || extension == L".webp" ||
         extension == L".heic" || extension == L".heif";
}

uint64_t UnsignedProperty(IPropertyStore* store, REFPROPERTYKEY key) {
  PROPVARIANT value;
  PropVariantInit(&value);
  uint64_t result = 0;
  if (SUCCEEDED(store->GetValue(key, &value))) {
    if (value.vt == VT_UI8) result = value.uhVal.QuadPart;
    if (value.vt == VT_UI4) result = value.ulVal;
    if (value.vt == VT_I8 && value.hVal.QuadPart > 0) {
      result = static_cast<uint64_t>(value.hVal.QuadPart);
    }
    if (value.vt == VT_I4 && value.lVal > 0) {
      result = static_cast<uint64_t>(value.lVal);
    }
  }
  PropVariantClear(&value);
  return result;
}

std::optional<flutter::EncodableMap> ProbeMedia(const std::wstring& path) {
  std::error_code file_error;
  if (!std::filesystem::is_regular_file(path, file_error)) return std::nullopt;

  uint64_t width = 0;
  uint64_t height = 0;
  uint64_t duration_100ns = 0;
  uint64_t audio_channels = 0;
  const bool is_photo = IsPhoto(path);

  if (is_photo) {
    ComPtr<IWICImagingFactory> factory;
    ComPtr<IWICBitmapDecoder> decoder;
    ComPtr<IWICBitmapFrameDecode> frame;
    if (SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                                   CLSCTX_INPROC_SERVER,
                                   IID_PPV_ARGS(&factory))) &&
        SUCCEEDED(factory->CreateDecoderFromFilename(
            path.c_str(), nullptr, GENERIC_READ, WICDecodeMetadataCacheOnLoad,
            &decoder)) &&
        SUCCEEDED(decoder->GetFrame(0, &frame))) {
      UINT image_width = 0;
      UINT image_height = 0;
      if (SUCCEEDED(frame->GetSize(&image_width, &image_height))) {
        width = image_width;
        height = image_height;
      }
    }
  } else {
    ComPtr<IPropertyStore> properties;
    if (SUCCEEDED(SHGetPropertyStoreFromParsingName(
            path.c_str(), nullptr, GPS_BESTEFFORT, IID_PPV_ARGS(&properties)))) {
      width = UnsignedProperty(properties.Get(), PKEY_Video_FrameWidth);
      height = UnsignedProperty(properties.Get(), PKEY_Video_FrameHeight);
      duration_100ns = UnsignedProperty(properties.Get(), PKEY_Media_Duration);
      audio_channels = UnsignedProperty(properties.Get(), PKEY_Audio_ChannelCount);
    }
  }

  flutter::EncodableMap media;
  media[flutter::EncodableValue("width")] =
      flutter::EncodableValue(static_cast<int64_t>(width));
  media[flutter::EncodableValue("height")] =
      flutter::EncodableValue(static_cast<int64_t>(height));
  media[flutter::EncodableValue("durationSeconds")] =
      flutter::EncodableValue(static_cast<double>(duration_100ns) / 10000000.0);
  media[flutter::EncodableValue("hasAudio")] =
      flutter::EncodableValue(audio_channels > 0);
  media[flutter::EncodableValue("isPhoto")] = flutter::EncodableValue(is_photo);
  return media;
}

std::vector<uint8_t> EncodeThumbnail(HBITMAP bitmap) {
  ComPtr<IWICImagingFactory> factory;
  ComPtr<IWICBitmap> wic_bitmap;
  ComPtr<IStream> stream;
  ComPtr<IWICStream> wic_stream;
  ComPtr<IWICBitmapEncoder> encoder;
  ComPtr<IWICBitmapFrameEncode> frame;
  if (FAILED(CoCreateInstance(CLSID_WICImagingFactory, nullptr,
                              CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory))) ||
      FAILED(factory->CreateBitmapFromHBITMAP(bitmap, nullptr,
                                              WICBitmapUsePremultipliedAlpha,
                                              &wic_bitmap))) {
    return {};
  }

  stream.Attach(SHCreateMemStream(nullptr, 0));
  if (!stream || FAILED(factory->CreateStream(&wic_stream)) ||
      FAILED(wic_stream->InitializeFromIStream(stream.Get())) ||
      FAILED(factory->CreateEncoder(GUID_ContainerFormatPng, nullptr,
                                    &encoder)) ||
      FAILED(encoder->Initialize(wic_stream.Get(), WICBitmapEncoderNoCache)) ||
      FAILED(encoder->CreateNewFrame(&frame, nullptr)) ||
      FAILED(frame->Initialize(nullptr)) ||
      FAILED(frame->WriteSource(wic_bitmap.Get(), nullptr)) ||
      FAILED(frame->Commit()) || FAILED(encoder->Commit())) {
    return {};
  }

  STATSTG stat = {};
  LARGE_INTEGER start = {};
  if (FAILED(stream->Stat(&stat, STATFLAG_NONAME)) ||
      stat.cbSize.QuadPart <= 0 ||
      FAILED(stream->Seek(start, STREAM_SEEK_SET, nullptr))) {
    return {};
  }
  std::vector<uint8_t> bytes(static_cast<size_t>(stat.cbSize.QuadPart));
  ULONG bytes_read = 0;
  if (FAILED(stream->Read(bytes.data(), static_cast<ULONG>(bytes.size()),
                          &bytes_read))) {
    return {};
  }
  bytes.resize(bytes_read);
  return bytes;
}

std::vector<uint8_t> ThumbnailForMedia(const std::wstring& path) {
  ComPtr<IShellItemImageFactory> image_factory;
  if (FAILED(SHCreateItemFromParsingName(path.c_str(), nullptr,
                                         IID_PPV_ARGS(&image_factory)))) {
    return {};
  }
  HBITMAP bitmap = nullptr;
  const SIZE size = {512, 512};
  const HRESULT result = image_factory->GetImage(
      size, static_cast<SIIGBF>(SIIGBF_BIGGERSIZEOK | SIIGBF_THUMBNAILONLY),
      &bitmap);
  if (FAILED(result) || bitmap == nullptr) return {};
  const auto bytes = EncodeThumbnail(bitmap);
  DeleteObject(bitmap);
  return bytes;
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

  media_open_channel_ = std::make_unique<flutter::MethodChannel<>>(
      flutter_controller_->engine()->messenger(), kMediaOpenChannel,
      &flutter::StandardMethodCodec::GetInstance());
  media_open_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<>& call,
         std::unique_ptr<flutter::MethodResult<>> result) {
        if (call.method_name() == "consumePendingMediaFiles") {
          result->Success(flutter::EncodableValue(flutter::EncodableList{}));
        } else {
          result->NotImplemented();
        }
      });

  media_probe_channel_ = std::make_unique<flutter::MethodChannel<>>(
      flutter_controller_->engine()->messenger(), kMediaProbeChannel,
      &flutter::StandardMethodCodec::GetInstance());
  media_probe_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<>& call,
         std::unique_ptr<flutter::MethodResult<>> result) {
        const auto path_utf8 = GetPath(call);
        if (!path_utf8) {
          result->Error("invalid-arguments", "Expected a media file path.");
          return;
        }
        const std::wstring path = Utf16FromUtf8(*path_utf8);
        if (call.method_name() == "beginAccessingMedia") {
          result->Success(flutter::EncodableValue(false));
        } else if (call.method_name() == "endAccessingMedia") {
          result->Success();
        } else if (call.method_name() == "probeMedia") {
          const auto media = ProbeMedia(path);
          if (media) {
            result->Success(flutter::EncodableValue(*media));
          } else {
            result->Error("probe-failed", "Unable to inspect the media file.");
          }
        } else if (call.method_name() == "thumbnailForMedia") {
          const auto thumbnail = ThumbnailForMedia(path);
          if (thumbnail.empty()) {
            result->Success();
          } else {
            result->Success(flutter::EncodableValue(thumbnail));
          }
        } else {
          result->NotImplemented();
        }
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
  media_probe_channel_.reset();
  media_open_channel_.reset();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
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
