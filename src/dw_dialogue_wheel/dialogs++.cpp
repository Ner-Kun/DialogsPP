#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstdarg>
#include <cstdio>
#include <string>

#define DIALOGS_PP_VERSION "1.0.0"

constexpr LONG kModeNone = 0;     // no dialogue
constexpr LONG kModeDialogue = 1; // dialogue open, plain line
constexpr LONG kModeOptions = 2;  // reply options on screen

// log
namespace diag {

HANDLE g_file = nullptr;
bool   g_enabled = false;

void line(const char* fmt, ...);

bool fileExists(const std::wstring& path) {
    return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

std::wstring moduleFolder(HINSTANCE self) {
    wchar_t path[MAX_PATH] = {};
    DWORD n = GetModuleFileNameW(self, path, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return L"";
    std::wstring p(path, n);
    size_t slash = p.find_last_of(L"\\/");
    if (slash == std::wstring::npos) return L"";
    return p.substr(0, slash);
}
// Diagnostics. Off unless "debug.enable" sits next to this DLL.
void init(HINSTANCE self) {
    std::wstring folder = moduleFolder(self);
    if (folder.empty()) return;
    if (!fileExists(folder + L"\\debug.enable")) return;  // default: off
    g_file = CreateFileW((folder + L"\\dialogs++.log").c_str(), GENERIC_WRITE,
                         FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, CREATE_ALWAYS,
                         FILE_ATTRIBUTE_NORMAL, nullptr);
    if (g_file == INVALID_HANDLE_VALUE) { g_file = nullptr; return; }
    g_enabled = true;
    line("=== dialogs++ %s, diagnostics on ===", DIALOGS_PP_VERSION);
    line("game pid %lu", GetCurrentProcessId());
}

void line(const char* fmt, ...) {
    if (!g_enabled) return;
    char buf[1024] = {};
    va_list ap;
    va_start(ap, fmt);
    int n = _vsnprintf_s(buf, sizeof(buf), _TRUNCATE, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    DWORD written = 0;
    WriteFile(g_file, buf, static_cast<DWORD>(n), &written, nullptr);
}

}  // namespace diag

// mod
namespace {
DWORD   g_processId = 0;
HWND    g_hwnd = nullptr;
WNDPROC g_original = nullptr;
volatile LONG g_mode = kModeNone;
long    g_wheelSeen = 0;

std::wstring windowClass(HWND hwnd) {
    wchar_t cls[256] = {};
    GetClassNameW(hwnd, cls, 256);
    return cls;
}

void pressKey(WORD vk) {
    INPUT in[2] = {};
    in[0].type = INPUT_KEYBOARD;
    in[0].ki.wVk = vk;
    in[1].type = INPUT_KEYBOARD;
    in[1].ki.wVk = vk;
    in[1].ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(2, in, sizeof(INPUT));
}

void setMode(LONG mode) {
    LONG prev = InterlockedExchange(&g_mode, mode);
    if (prev != mode) diag::line("mode %ld -> %ld", prev, mode);
}

LRESULT CALLBACK hookedProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (hwnd != g_hwnd || g_original == nullptr) return DefWindowProcW(hwnd, msg, wParam, lParam);
    if (g_mode == kModeNone) return CallWindowProcW(g_original, hwnd, msg, wParam, lParam);

#ifdef NULL_BUILD
    return CallWindowProcW(g_original, hwnd, msg, wParam, lParam);
#else
    if (msg == WM_MOUSEWHEEL && g_mode == kModeOptions) {
        ++g_wheelSeen;
        short delta = GET_WHEEL_DELTA_WPARAM(wParam);
        diag::line("wheel #%ld delta=%d", g_wheelSeen, delta);
        if (delta != 0) pressKey(delta > 0 ? VK_UP : VK_DOWN);
    }
    return CallWindowProcW(g_original, hwnd, msg, wParam, lParam);
#endif
}

void hookWindow(HWND hwnd) {
    if (g_hwnd != nullptr) return;
    WNDPROC prev = reinterpret_cast<WNDPROC>(
        SetWindowLongPtrW(hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(hookedProc)));
    if (prev == nullptr) {
        diag::line("SetWindowLongPtrW failed on class=%ls error=%lu",
                   windowClass(hwnd).c_str(), GetLastError());
        return;
    }
    wchar_t title[256] = {};
    GetWindowTextW(hwnd, title, 256);
    diag::line("hooked window class=%ls title=%ls", windowClass(hwnd).c_str(), title);
    g_hwnd = hwnd;
    g_original = prev;
}

BOOL CALLBACK collectWindowProc(HWND hwnd, LPARAM) {
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != g_processId) return TRUE;
    if (!IsWindowVisible(hwnd)) return TRUE;
    if (windowClass(hwnd) == L"ConsoleWindowClass") return TRUE;
    hookWindow(hwnd);
    return TRUE;
}

DWORD WINAPI hookThread(LPVOID) {
    g_processId = GetCurrentProcessId();

    for (int attempt = 0; attempt < 60 && g_hwnd == nullptr; ++attempt) {
        EnumWindows(collectWindowProc, 0);
        if (g_hwnd != nullptr) break;
        Sleep(500);
    }

    if (g_hwnd == nullptr) {
        diag::line("FAILED: no game window appeared");
        return 0;
    }

    diag::line("ready, window hooked");
    return 0;
}

}  // namespace

// Lua entry points
extern "C" {

__declspec(dllexport) int dialogs_mode_0(void*) { setMode(kModeNone); return 0; }
__declspec(dllexport) int dialogs_mode_1(void*) { setMode(kModeDialogue); return 0; }
__declspec(dllexport) int dialogs_mode_2(void*) { setMode(kModeOptions); return 0; }
/// Re-hover the primed option via SendInput UP through Slate to repaint the highlight.
/// At hover 0, UP cannot change the selection.
__declspec(dllexport) int dialogs_prime_arrow(void*) {
    diag::line("prime-arrow");
    pressKey(VK_UP);
    return 0;
}
/// Keyboard navigation (W/S): send DOWN via SendInput, paired with dialogs_prime_arrow (UP)
/// Called by Lua keybinds to navigate reply lists without mouse or wheel
__declspec(dllexport) int dialogs_arrow_down(void*) {
    diag::line("arrow-down");
    pressKey(VK_DOWN);
    return 0;
}

}  // extern "C"

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        DisableThreadLibraryCalls(instance);
        // Keep loaded: unloading with the WndProc hook active causes an AV on the next window message.
        {
            HMODULE self = nullptr;
            GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_PIN, L"dialogs++.dll", &self);
            (void)self;
        }
        diag::init(instance);
        CreateThread(nullptr, 0, hookThread, nullptr, 0, nullptr);
    } else if (reason == DLL_PROCESS_DETACH) {
        // Restore the original proc before unloading to prevent calls into dead code.
        if (g_hwnd != nullptr && g_original != nullptr) {
            SetWindowLongPtrW(g_hwnd, GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(g_original));
            g_hwnd = nullptr;
            g_original = nullptr;
        }
        if (diag::g_file != nullptr) {
            CloseHandle(diag::g_file);
            diag::g_file = nullptr;
        }
    }
    return TRUE;
}
