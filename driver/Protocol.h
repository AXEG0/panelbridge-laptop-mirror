#pragma once

/* All fields have fixed widths. Keep in sync with FramebufferSink.cs. */
#define PB_VERSION 1u
#define PB_MAX_PLANES 28u
#define PB_IOCTL_INFO CTL_CODE(FILE_DEVICE_UNKNOWN, 0x800, METHOD_BUFFERED, FILE_READ_ACCESS)
#define PB_IOCTL_FRAME CTL_CODE(FILE_DEVICE_UNKNOWN, 0x801, METHOD_IN_DIRECT, FILE_WRITE_ACCESS)

typedef struct PB_PLANE {
    unsigned int Pipe, Plane, Control, Stride, Size, Surface, Offset, Live;
} PB_PLANE;

typedef struct PB_INFO {
    unsigned int Version, Bytes, State, ActivePlanes;
    unsigned int Width, Height, Pitch, Reserved;
    unsigned long long MmioPhysical, AperturePhysical, ApertureLength;
    unsigned long long FrameOffset, FrameLength;
    PB_PLANE Planes[PB_MAX_PLANES];
} PB_INFO;

typedef struct PB_FRAME {
    unsigned int Version, Width, Height, Pitch, Bytes;
} PB_FRAME;

enum {
    PB_OFFLINE = 0, PB_READY = 1, PB_NO_PLANE = 2, PB_MULTIPLE_PLANES = 3,
    PB_UNSUPPORTED_LAYOUT = 4, PB_OUT_OF_APERTURE = 5, PB_MAP_FAILED = 6,
    PB_LAYOUT_CHANGED = 7
};
