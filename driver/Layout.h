#pragma once
#include "Protocol.h"

/* Tiger Lake linear XRGB8888 only. No caller-supplied physical addresses.
 * Register definitions: Intel Tiger Lake PRM vol. 12 and Intel's MIT-licensed
 * skl_universal_plane_regs.h in Linux v6.16. */
static unsigned int PbValidateLayout(const PB_PLANE *p,
    unsigned long long apertureLength, unsigned int *pitch,
    unsigned long long *offset, unsigned long long *length)
{
    unsigned int width = (p->Size & 0xffffu) + 1u;
    unsigned int height = (p->Size >> 16) + 1u;
    unsigned int x = p->Offset & 0xffffu, y = p->Offset >> 16;
    unsigned int stride = (p->Stride & 0xfffu) * 64u;
    unsigned long long start, span;
    /* Enabled, 32-bit BGRX, no tiling, compression, rotation or mirroring. */
    if (!(p->Control & 0x80000000u) ||
        (p->Control & 0x0f800000u) != 0x04000000u ||
        (p->Control & (0x00100000u | 0x8000u | 0x1c00u | 0x100u | 0x10u | 3u)) ||
        width != 1920u || height != 1080u ||
        stride < (x + width) * 4u || stride > 32768u ||
        (p->Surface & 0xfffff000u) != (p->Live & 0xfffff000u))
        return PB_UNSUPPORTED_LAYOUT;

    start = (unsigned long long)(p->Live & 0xfffff000u) +
        (unsigned long long)y * stride + (unsigned long long)x * 4u;
    span = (unsigned long long)(height - 1u) * stride + width * 4u;
    if (start > apertureLength || span > apertureLength - start)
        return PB_OUT_OF_APERTURE;
    *pitch = stride;
    *offset = start;
    *length = span;
    return PB_READY;
}

static int PbValidateFrame(const PB_FRAME *f, unsigned long long mdlLength)
{
    unsigned long long bytes;
    if (f->Version != PB_VERSION || f->Width != 1920u || f->Height != 1080u ||
        f->Pitch < f->Width * 4u || f->Pitch > 32768u)
        return 0;
    bytes = (unsigned long long)(f->Height - 1u) * f->Pitch + f->Width * 4u;
    return bytes == f->Bytes && bytes <= mdlLength;
}
