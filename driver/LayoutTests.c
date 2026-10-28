#include "Layout.h"
__declspec(dllimport) void __stdcall ExitProcess(unsigned int);
__declspec(dllimport) void * __stdcall GetStdHandle(unsigned int);
__declspec(dllimport) int __stdcall WriteFile(void *, const void *, unsigned int, unsigned int *, void *);

static void Check(int passed, unsigned int line)
{
    if (!passed) {
        char message[] = "Layout test failed at line 0000\r\n";
        unsigned int written;
        message[26] = (char)('0' + line / 1000u % 10u);
        message[27] = (char)('0' + line / 100u % 10u);
        message[28] = (char)('0' + line / 10u % 10u);
        message[29] = (char)('0' + line % 10u);
        WriteFile(GetStdHandle((unsigned int)-11), message, sizeof(message) - 1, &written, 0);
        ExitProcess(1);
    }
}
#define CHECK(condition) Check(!!(condition), __LINE__)

void mainCRTStartup(void)
{
    PB_PLANE p = { 0, 0, 0x84000000u, 120, (1079u << 16) | 1919u, 0, 0, 0 };
    PB_PLANE q;
    PB_FRAME f = { 1, 1920, 1080, 7680, 8294400 };
    unsigned int pitch = 0, i, seed = 1, written;
    unsigned long long offset = 0, length = 0;
    const char ok[] = "Layout tests passed (20000 randomized bounds checks).\r\n";
    CHECK(sizeof(PB_INFO) == 968);
    CHECK(sizeof(PB_FRAME) == 20);
    CHECK(PbValidateLayout(&p, 0x10000000ull, &pitch, &offset, &length) == PB_READY);
    CHECK(pitch == 7680 && offset == 0 && length == 8294400);
    CHECK(PbValidateLayout(&p, length, &pitch, &offset, &length) == PB_READY);
    CHECK(PbValidateLayout(&p, length - 1, &pitch, &offset, &length) == PB_OUT_OF_APERTURE);
    q = p; q.Control |= 1u << 10;
    CHECK(PbValidateLayout(&q, 0x10000000ull, &pitch, &offset, &length) == PB_UNSUPPORTED_LAYOUT);
    q = p; q.Control |= 1u << 15;
    CHECK(PbValidateLayout(&q, 0x10000000ull, &pitch, &offset, &length) == PB_UNSUPPORTED_LAYOUT);
    q = p; q.Control |= 1u << 20;
    CHECK(PbValidateLayout(&q, 0x10000000ull, &pitch, &offset, &length) == PB_UNSUPPORTED_LAYOUT);
    q = p; q.Control |= 1u;
    CHECK(PbValidateLayout(&q, 0x10000000ull, &pitch, &offset, &length) == PB_UNSUPPORTED_LAYOUT);
    q = p; q.Control &= ~0x80000000u;
    CHECK(PbValidateLayout(&q, 0x10000000ull, &pitch, &offset, &length) == PB_UNSUPPORTED_LAYOUT);
    q = p; q.Stride = 119;
    CHECK(PbValidateLayout(&q, 0x10000000ull, &pitch, &offset, &length) == PB_UNSUPPORTED_LAYOUT);
    q = p; q.Surface = 0x1000;
    CHECK(PbValidateLayout(&q, 0x10000000ull, &pitch, &offset, &length) == PB_UNSUPPORTED_LAYOUT);
    q = p; q.Surface = q.Live = 0xfffff000u;
    CHECK(PbValidateLayout(&q, 0x10000000ull, &pitch, &offset, &length) == PB_OUT_OF_APERTURE);
    q = p; q.Offset = (2u << 16) | 16u; q.Stride = 128;
    CHECK(PbValidateLayout(&q, 0x10000000ull, &pitch, &offset, &length) == PB_READY);
    CHECK(offset == 2 * 8192 + 16 * 4 && length == 1079 * 8192 + 1920 * 4);
    CHECK(PbValidateFrame(&f, f.Bytes));
    CHECK(!PbValidateFrame(&f, f.Bytes - 1));
    f.Pitch = 0xffffffffu; CHECK(!PbValidateFrame(&f, 0xffffffffffffffffull));
    f.Pitch = 7680; f.Width = 0xffffffffu; CHECK(!PbValidateFrame(&f, 8294400));
    f.Width = 1920; f.Version = 0; CHECK(!PbValidateFrame(&f, 8294400));
    f.Version = 1; f.Bytes--; CHECK(!PbValidateFrame(&f, 8294400));
    for (i = 0; i < 20000; ++i) {
        unsigned int state;
        unsigned long long aperture;
        seed = seed * 1664525u + 1013904223u;
        q = p; q.Stride = seed & 0xfffu;
        q.Offset = (seed >> 8) ^ seed;
        q.Surface = q.Live = seed & 0xfffff000u;
        aperture = (unsigned long long)(seed ^ 0xa5a5a5a5u);
        state = PbValidateLayout(&q, aperture, &pitch, &offset, &length);
        if (state == PB_READY) {
            CHECK(offset <= aperture && length <= aperture - offset);
            CHECK(pitch >= 1920 * 4 && pitch <= 32768);
            CHECK(length == (unsigned long long)1079 * pitch + 1920 * 4);
        }
    }
    WriteFile(GetStdHandle((unsigned int)-11), ok, sizeof(ok) - 1, &written, 0);
    ExitProcess(0);
}
