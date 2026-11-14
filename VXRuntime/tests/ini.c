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


    // WritePrivateProfileString: a missing file is created, a missing section appended, a key replaced or added in place
    // (other lines, comments and CRLF kept), a key or a whole section removed; the reads see it.
    DeleteFileA("C:\\vxini\\w.ini");
    CHECK(WritePrivateProfileStringA("VR", "bOneTimeCalibrationCompleted", "1", "C:\\vxini\\w.ini"));
    CHECK(GetPrivateProfileIntA("VR", "bOneTimeCalibrationCompleted", 0, "C:\\vxini\\w.ini") == 1);
    write_file("C:\\vxini\\w2.ini", "; head\r\n[General]\r\nsA=1\r\n\r\n[VR]\r\nfX=2\r\n; note\r\n\r\n[Last]\r\nz=9");
    CHECK(WritePrivateProfileStringA("vr", "BONETIMECALIBRATIONCOMPLETED", "1", "C:\\vxini\\w2.ini"));    // new key, section found without case
    CHECK(WritePrivateProfileStringA("VR", "fX", "3", "C:\\vxini\\w2.ini"));                               // replaced
    CHECK(WritePrivateProfileStringW(L"New", L"k", L"v", L"C:\\vxini\\w2.ini"));                           // new section (after a last line without an ending)
    CHECK(WritePrivateProfileStringA("Last", "y", "8", "C:\\vxini\\w2.ini"));                              // added to the section that had no ending
    CHECK(WritePrivateProfileStringA("General", "sA", NULL, "C:\\vxini\\w2.ini"));                         // key removed
    {
        char buf[512]; HANDLE f = CreateFileA("C:\\vxini\\w2.ini", GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
        DWORD got = 0; memset(buf, 0, sizeof buf);
        CHECK(f != INVALID_HANDLE_VALUE && ReadFile(f, buf, sizeof buf - 1, &got, NULL));
        CloseHandle(f);
        CHECK(!strcmp(buf, "; head\r\n[General]\r\n\r\n[VR]\r\nfX=3\r\nBONETIMECALIBRATIONCOMPLETED=1\r\n; note\r\n\r\n[Last]\r\nz=9\r\ny=8\r\n[New]\r\nk=v\r\n"));
        if (strcmp(buf, "; head\r\n[General]\r\n\r\n[VR]\r\nfX=3\r\nBONETIMECALIBRATIONCOMPLETED=1\r\n; note\r\n\r\n[Last]\r\nz=9\r\ny=8\r\n[New]\r\nk=v\r\n")) printf("got: %s\n", buf);
    }
    CHECK(WritePrivateProfileStringA("VR", NULL, NULL, "C:\\vxini\\w2.ini"));                              // section removed
    CHECK(GetPrivateProfileIntA("VR", "fX", 7, "C:\\vxini\\w2.ini") == 7);
    CHECK(GetPrivateProfileIntA("Last", "y", 7, "C:\\vxini\\w2.ini") == 8);
    CHECK(!WritePrivateProfileStringA(NULL, "k", "v", "C:\\vxini\\w2.ini"));

    if (failures) { printf("%d failures\n", failures); return 1; }
    printf("ini ok\n");
    return 0;
}
