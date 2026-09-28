#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdio.h>

__attribute__((used)) static const char kMarker[] = "SCWRAP1";

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE prev, PWSTR cmd, int show)
{
    wchar_t self[MAX_PATH];
    wchar_t valve[MAX_PATH];
    wchar_t cmdline[32768];
    STARTUPINFOW si;
    PROCESS_INFORMATION pi;
    DWORD code = 1;
    wchar_t *slash;
    int inject;

    (void)instance;
    (void)prev;
    (void)show;
    (void)kMarker;

    if (!GetModuleFileNameW(NULL, self, MAX_PATH))
        return 1;
    lstrcpynW(valve, self, MAX_PATH);
    slash = wcsrchr(valve, L'\\');
    if (slash)
        lstrcpyW(slash + 1, L"steamwebhelper-valve.exe");

    /* Inject only for the main CEF browser process. */
    inject = !cmd || (!wcsstr(cmd, L"--type=") && !wcsstr(cmd, L"--single-process"));
    if (inject)
        _snwprintf(cmdline, 32768, L"\"%s\" %s --disable-gpu --single-process", valve, cmd ? cmd : L"");
    else
        _snwprintf(cmdline, 32768, L"\"%s\" %s", valve, cmd ? cmd : L"");

    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));
    if (!CreateProcessW(valve, cmdline, NULL, NULL, FALSE, 0, NULL, NULL, &si, &pi))
        return 1;
    WaitForSingleObject(pi.hProcess, INFINITE);
    GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return (int)code;
}
