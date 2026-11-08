// GetPrivateProfile*: the documented reading of .ini files (sections and keys without case, ';' comments, quoted values,
// the enumeration forms, a missing file or key giving the default), with a made-up file in C:\vxini.
#include <windows.h>
#include <stdio.h>
#include <string.h>
static int failures;
#define CHECK(cond) do { if (!(cond)) { printf("check failed (line %d): %s\n", __LINE__, #cond); failures++; } } while (0)

static void write_file(const char *path, const char *text) {
    HANDLE f = CreateFileA(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    DWORD n;
    CHECK(f != INVALID_HANDLE_VALUE && WriteFile(f, text, (DWORD)strlen(text), &n, NULL) && n == strlen(text));
    CloseHandle(f);
}

int main(void) {
    CreateDirectoryA("C:\\vxini", NULL);
    // CRLF lines, a byte-order mark, a comment, spacing around '=', quotes, an empty value, a key in two sections.
    write_file("C:\\vxini\\game.ini",
               "\xef\xbb\xbf; settings\r\n"
               "[General]\r\n"
               "sLanguage = ENGLISH \r\n"
               "uCount=42\r\n"
               "sQuoted=\"two words\"\r\n"
               ";sHidden=no\r\n"
               "sEmpty=\r\n"
               "[Archive]\r\n"
               "sResourceArchiveList=Skyrim - Misc.bsa, Skyrim - Meshes0.bsa\r\n"
               "sLanguage=other\r\n"
               "iNegative=-7\r\n"
               "sText=abc\r\n");
    char out[256];
    DWORD n;

    n = GetPrivateProfileStringA("General", "sLanguage", "def", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(n == 7 && !strcmp(out, "ENGLISH"));                                        // trimmed
    n = GetPrivateProfileStringA("general", "SLANGUAGE", "def", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(n == 7 && !strcmp(out, "ENGLISH"));                                        // names without case
    n = GetPrivateProfileStringA("Archive", "sLanguage", "def", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(n == 5 && !strcmp(out, "other"));                                          // the right section's key
    n = GetPrivateProfileStringA("Archive", "sResourceArchiveList", "", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(!strcmp(out, "Skyrim - Misc.bsa, Skyrim - Meshes0.bsa") && n == strlen(out));
    n = GetPrivateProfileStringA("General", "sQuoted", "", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(n == 9 && !strcmp(out, "two words"));                                      // the quotes around a value are dropped
    n = GetPrivateProfileStringA("General", "sHidden", "def", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(n == 3 && !strcmp(out, "def"));                                            // a comment line is not a key
    n = GetPrivateProfileStringA("General", "sEmpty", "def", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(n == 0 && out[0] == 0);                                                    // present and empty: not the default
    n = GetPrivateProfileStringA("General", "sMissing", "def", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(n == 3 && !strcmp(out, "def"));
    n = GetPrivateProfileStringA("Nope", "sLanguage", "def", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(n == 3 && !strcmp(out, "def"));
    n = GetPrivateProfileStringA("General", "sLanguage", "def", out, sizeof out, "C:\\vxini\\absent.ini");
    CHECK(n == 3 && !strcmp(out, "def"));                                            // no such file
    char small[4];
    n = GetPrivateProfileStringA("General", "sLanguage", "def", small, sizeof small, "C:\\vxini\\game.ini");
    CHECK(n == 3 && !strcmp(small, "ENG"));                                          // cut to the buffer

    CHECK(GetPrivateProfileIntA("General", "uCount", 5, "C:\\vxini\\game.ini") == 42);
    CHECK(GetPrivateProfileIntA("General", "uMissing", 5, "C:\\vxini\\game.ini") == 5);
    CHECK((int)GetPrivateProfileIntA("Archive", "iNegative", 5, "C:\\vxini\\game.ini") == -7);
    CHECK(GetPrivateProfileIntA("Archive", "sText", 5, "C:\\vxini\\game.ini") == 0);  // text that is not a number
    CHECK(GetPrivateProfileIntW(L"General", L"uCount", 5, L"C:\\vxini\\game.ini") == 42);

    // Enumerations: "name\0name\0\0".
    n = GetPrivateProfileStringA(NULL, NULL, "", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(n == 16 && !memcmp(out, "General\0Archive\0\0", n + 1));                  // (the length counts the last name's terminator)
    n = GetPrivateProfileStringA("General", NULL, "", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(n == 10 + 7 + 8 + 7 && !memcmp(out, "sLanguage\0uCount\0sQuoted\0sEmpty\0\0", n + 1));
    n = GetPrivateProfileSectionA("General", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(n == 18 + 10 + 18 + 8 && !memcmp(out, "sLanguage=ENGLISH\0uCount=42\0sQuoted=two words\0sEmpty=\0\0", n + 1));
    n = GetPrivateProfileSectionA("Nope", out, sizeof out, "C:\\vxini\\game.ini");
    CHECK(n == 0 && out[0] == 0 && out[1] == 0);

    WCHAR wout[256];
    n = GetPrivateProfileStringW(L"General", L"sLanguage", L"def", wout, 256, L"C:\\vxini\\game.ini");
    CHECK(n == 7 && !wcscmp(wout, L"ENGLISH"));
    n = GetPrivateProfileStringW(NULL, NULL, L"", wout, 256, L"C:\\vxini\\game.ini");
    CHECK(n == 16 && !memcmp(wout, L"General\0Archive\0\0", (n + 1) * 2));

    if (failures) { printf("%d failures\n", failures); return 1; }
    printf("ini ok\n");
    return 0;
}
