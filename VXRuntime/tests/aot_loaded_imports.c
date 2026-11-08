// The ordinary imports already bound on the DLLs a Skyrim probe loaded. Each one is resolved and called.
#include <stdarg.h>
#include <stdint.h>
#include <windows.h>

static void fail(int code, const char *text) {
    DWORD wrote = 0;
    HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE);
    WriteFile(out, text, lstrlenA(text), &wrote, NULL);
    WriteFile(out, "\n", 1, &wrote, NULL);
    ExitProcess((UINT)code);
}
static void *need(HMODULE mod, const char *name) {
    FARPROC fn = GetProcAddress(mod, name);
    if (!mod || !fn) fail(1, name);
    return (void *)fn;
}
static void *need_ord(HMODULE mod, int ordinal, void *named) {
    FARPROC fn = GetProcAddress(mod, (const char *)(uintptr_t)ordinal);
    if (!fn || fn != (FARPROC)named) fail(1, "ordinal");
    return (void *)fn;
}
static int call_file(void *fn, void *file, const void *fmt, ...) {
    typedef int (WINAPI *t)(uint64_t, void *, const void *, void *, va_list);
    va_list ap;
    va_start(ap, fmt);
    int r = ((t)fn)(0, file, fmt, NULL, ap);
    va_end(ap);
    return r;
}
static int call_buf(void *fn, void *buf, size_t count, const void *fmt, ...) {
    typedef int (WINAPI *t)(uint64_t, void *, size_t, const void *, void *, va_list);
    va_list ap;
    va_start(ap, fmt);
    int r = ((t)fn)(0, buf, count, fmt, NULL, ap);
    va_end(ap);
    return r;
}
static int wsame(const wchar_t *a, const wchar_t *b) {
    while (*a && *a == *b) { a++; b++; }
    return *a == *b;
}

void mainCRTStartup(void) {
    HMODULE k32 = GetModuleHandleW(L"kernel32.dll");
    HMODULE crt = GetModuleHandleW(L"ucrtbase.dll");
    HMODULE winmm = GetModuleHandleW(L"winmm.dll");
    HMODULE ws2 = GetModuleHandleW(L"ws2_32.dll");
    HMODULE xinput = GetModuleHandleW(L"xinput1_3.dll");
    typedef int (WINAPI *cmp_fn)(const uint32_t *, const uint32_t *);
    typedef int (WINAPI *prof_fn)(const char *, const char *, const char *, const char *);
    typedef DWORD (WINAPI *xget_fn)(DWORD, void *);
    typedef int (WINAPI *async_fn)(uint64_t, void *, uint32_t, int32_t);
    typedef int (WINAPI *wsaerr_fn)(void);
    typedef void (WINAPI *wsaerrset_fn)(int);
    typedef int (WINAPI *wsastart_fn)(uint16_t, void *);
    typedef uint64_t (WINAPI *sock_fn)(int, int, int);
    typedef int (WINAPI *recv_fn)(uint64_t, char *, int, int);
    typedef int (WINAPI *close_fn)(uint64_t);
    typedef int (WINAPI *bind_fn)(uint64_t, const void *, int);
    typedef int (WINAPI *listen_fn)(uint64_t, int);
    typedef int (WINAPI *connect_fn)(uint64_t, const void *, int);
    typedef uint64_t (WINAPI *accept_fn)(uint64_t, void *, int *);
    typedef int (WINAPI *name_fn)(uint64_t, void *, int *);
    typedef uint32_t (WINAPI *wave_fn)(void *, DWORD);
    typedef int (WINAPI *str_fn)(char *, size_t);
    typedef int (WINAPI *coll_fn)(const wchar_t *, const wchar_t *);
    typedef int (WINAPI *itow_fn)(int, wchar_t *, size_t, int);
    typedef int (WINAPI *make_fn)(char *, size_t, const char *, const char *, const char *, const char *);
    typedef int (WINAPI *mb_fn)(size_t *, wchar_t *, size_t, const char *, size_t);
    typedef int (WINAPI *wc_fn)(size_t *, char *, size_t, const wchar_t *, size_t);
    typedef int (WINAPI *mbr_fn)(size_t *, wchar_t *, size_t, const char **, size_t, void *);
    typedef int (WINAPI *wcr_fn)(size_t *, char *, size_t, const wchar_t **, size_t, void *);
    typedef void *(WINAPI *fopen_fn)(const char *, const char *);
    typedef int (WINAPI *fclose_fn)(void *);

    cmp_fn compare = need(k32, "CompareFileTime");
    prof_fn profile = need(k32, "WritePrivateProfileStringA");
    xget_fn xget = need(xinput, "XInputGetState");
    need_ord(xinput, 2, (void *)xget);
    async_fn async = need(ws2, "WSAAsyncSelect");
    need_ord(ws2, 101, (void *)async);
    wsaerr_fn last = need(ws2, "WSAGetLastError");
    wsaerrset_fn setlast = need(ws2, "WSASetLastError");
    wsastart_fn startup = need(ws2, "WSAStartup");
    sock_fn open_socket = need(ws2, "socket");
    recv_fn read_socket = need(ws2, "recv");
    close_fn close_socket = need(ws2, "closesocket");
    bind_fn bind_socket = need(ws2, "bind");
    listen_fn listen_socket = need(ws2, "listen");
    connect_fn connect_socket = need(ws2, "connect");
    accept_fn accept_socket = need(ws2, "accept");
    name_fn socket_name = need(ws2, "getsockname");
    wave_fn wave = need(winmm, "waveOutSetVolume");
    str_fn lower = need(crt, "_strlwr_s");
    str_fn upper = need(crt, "_strupr_s");
    coll_fn coll = need(crt, "_wcsicoll");
    itow_fn itow = need(crt, "_itow_s");
    make_fn make = need(crt, "_makepath_s");
    mb_fn mbtow = need(crt, "mbstowcs_s");
    wc_fn wctomb = need(crt, "wcstombs_s");
    mbr_fn mbrtow = need(crt, "mbsrtowcs_s");
    wcr_fn wcrtom = need(crt, "wcsrtombs_s");
    void *vfprintf_p = need(crt, "__stdio_common_vfprintf_p");
    void *vfscanf = need(crt, "__stdio_common_vfscanf");
    void *vfwprintf_p = need(crt, "__stdio_common_vfwprintf_p");
    void *vfwprintf_s = need(crt, "__stdio_common_vfwprintf_s");
    void *vfwscanf = need(crt, "__stdio_common_vfwscanf");
    void *vswprintf_p = need(crt, "__stdio_common_vswprintf_p");
    void *vswscanf = need(crt, "__stdio_common_vswscanf");
    fopen_fn open_file = need(crt, "fopen");
    fclose_fn close_file = need(crt, "fclose");

    uint32_t early[2] = { 1, 0 }, later[2] = { 2, 0 }, high[2] = { 0, 1 };
    if (compare(early, later) != -1 || compare(later, early) != 1 || compare(early, early) != 0 || compare(later, high) != -1)
        fail(2, "CompareFileTime");
    if (!profile("Skyrim", "Volume", "1", "C:\\windows\\temp\\loaded.ini")) fail(3, "WritePrivateProfileStringA");

    uint8_t state[16];
    DWORD xr = xget(99, state);
    if (xr != 87) fail(4, "XInputGetState");
    xr = xget(0, state);
    if (xr != 0 && xr != 1167) fail(4, "XInputGetState user0");

    uint8_t wsa[512];
    if (startup(0x0202, wsa)) fail(5, "WSAStartup");
    setlast(1);
    if (async(~(uint64_t)0, NULL, 0, 0) != -1 || last() != 10038) fail(5, "WSAAsyncSelect invalid");
    uint8_t addr[16] = { 2, 0, 0, 0, 127, 0, 0, 1 };
    uint64_t listener = open_socket(2, 1, 0);
    if (listener == ~(uint64_t)0 || bind_socket(listener, addr, 16) || listen_socket(listener, 1)) fail(5, "listen");
    int addr_len = 16;
    if (socket_name(listener, addr, &addr_len)) fail(5, "getsockname");
    uint64_t client = open_socket(2, 1, 0);
    if (client == ~(uint64_t)0 || connect_socket(client, addr, 16)) fail(5, "connect");
    uint64_t peer = accept_socket(listener, NULL, NULL);
    if (peer == ~(uint64_t)0) fail(5, "accept");
    if (async(peer, NULL, 0, 1)) fail(5, "WSAAsyncSelect");
    char one;
    setlast(1);
    if (read_socket(peer, &one, 1, 0) != -1 || last() != 10035) fail(5, "nonblocking recv");
    close_socket(peer);
    close_socket(client);
    close_socket(listener);

    if (wave(NULL, 0x80008000) != 6 || wave((void *)(uintptr_t)1, 0) != 5) fail(6, "waveOutSetVolume");

    char text[8] = "AbC";
    if (lower(text, 8) || lstrcmpA(text, "abc")) fail(7, "_strlwr_s");
    if (upper(text, 8) || lstrcmpA(text, "ABC")) fail(7, "_strupr_s");
    if (lower(NULL, 4) != 22) fail(7, "_strlwr_s null");
    char bare[2] = { 'A', 'B' };
    if (lower(bare, 2) != 22 || bare[0]) fail(7, "_strlwr_s range");
    if (coll(L"AbC", L"abc") || coll(L"a", L"b") >= 0 || coll(L"b", L"a") <= 0) fail(7, "_wcsicoll");

    wchar_t wide[32];
    int wr = call_buf(vswprintf_p, wide, 32, L"n=%d", 7);
    if (wr != 3 || !wsame(wide, L"n=7")) fail(8, "vswprintf_p");
    void *out = open_file("C:\\windows\\temp\\loaded-imports.txt", "wb");
    if (!out) fail(8, "fopen");
    if (call_file(vfprintf_p, out, "42 hi\n") != 6) fail(8, "vfprintf_p");
    close_file(out);
    out = open_file("C:\\windows\\temp\\loaded-imports-w.txt", "wb");
    if (!out || call_file(vfwprintf_p, out, L"9 word\n") != 7) fail(8, "vfwprintf_p");
    close_file(out);
    out = open_file("C:\\windows\\temp\\loaded-imports-s.txt", "wb");
    if (!out || call_file(vfwprintf_s, out, L"8 zz\n") != 5) fail(8, "vfwprintf_s");
    close_file(out);

    int num = -1;
    char word[16];
    word[0] = 0;
    out = open_file("C:\\windows\\temp\\loaded-imports.txt", "rb");
    if (!out || call_file(vfscanf, out, "%d %s", &num, word) != 2 || num != 42 || lstrcmpA(word, "hi")) fail(9, "vfscanf");
    close_file(out);
    wchar_t wword[16];
    num = -1;
    wword[0] = 0;
    out = open_file("C:\\windows\\temp\\loaded-imports-w.txt", "rb");
    if (!out || call_file(vfwscanf, out, L"%d %s", &num, wword) != 2 || num != 9 || !wsame(wword, L"word")) fail(9, "vfwscanf");
    close_file(out);
    num = -1;
    wword[0] = 1;
    if (call_buf(vswscanf, (void *)L"3 abc", (size_t)-1, L"%d %s", &num, wword) != 2 || num != 3 || !wsame(wword, L"abc"))
        fail(9, "vswscanf");

    size_t got = 0;
    wchar_t chars[8];
    if (mbtow(&got, NULL, 0, "Ab", (size_t)-1) || got != 3) fail(10, "mbstowcs_s size");
    got = 0;
    if (mbtow(&got, chars, 8, "Ab", (size_t)-1) || got != 3 || !wsame(chars, L"Ab")) fail(10, "mbstowcs_s");
    if (mbtow(&got, chars, 2, "Ab", (size_t)-1) != 34) fail(10, "mbstowcs_s range");
    if (mbtow(&got, chars, 8, NULL, (size_t)-1) != 22) fail(10, "mbstowcs_s null");
    char narrow[8];
    got = 0;
    if (wctomb(&got, narrow, 8, L"Ab", (size_t)-1) || got != 3 || lstrcmpA(narrow, "Ab")) fail(10, "wcstombs_s");
    const char *src = "Ab";
    got = 0;
    chars[0] = 0;
    if (mbrtow(&got, chars, 8, &src, (size_t)-1, NULL) || src || got != 3 || !wsame(chars, L"Ab")) fail(10, "mbsrtowcs_s");
    const wchar_t *wsrc = L"Ab";
    got = 0;
    narrow[0] = 0;
    if (wcrtom(&got, narrow, 8, &wsrc, (size_t)-1, NULL) || wsrc || got != 3 || lstrcmpA(narrow, "Ab")) fail(10, "wcsrtombs_s");

    wchar_t digits[8];
    if (itow(-42, digits, 8, 10) || !wsame(digits, L"-42")) fail(11, "_itow_s");
    if (itow(255, digits, 8, 16) || !wsame(digits, L"ff")) fail(11, "_itow_s hex");
    if (itow(1, digits, 1, 10) != 34) fail(11, "_itow_s range");
    if (itow(1, digits, 8, 1) != 22) fail(11, "_itow_s radix");
    char path[64];
    if (make(path, 64, "C:", "Data", "Skyrim", ".ini") || lstrcmpA(path, "C:Data\\Skyrim.ini")) fail(11, "_makepath_s");
    if (make(path, 64, "C:", "Data\\", "Skyrim", "ini") || lstrcmpA(path, "C:Data\\Skyrim.ini")) fail(11, "_makepath_s slash");
    if (make(path, 4, "C:", "Data", "Skyrim", ".ini") != 34) fail(11, "_makepath_s range");

    const char verdict[] = "aot_loaded_imports: 21 bound imports, owned results -> ok\n";
    DWORD wrote = 0;
    if (!WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), verdict, sizeof verdict - 1, &wrote, NULL) || wrote != sizeof verdict - 1)
        fail(12, "verdict");
    ExitProcess(0);
}
