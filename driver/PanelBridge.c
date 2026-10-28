#include <ntddk.h>
#include <wdf.h>
#include <initguid.h>
#include <wdmguid.h>
#include "Layout.h"

typedef struct DEVICE_CONTEXT {
    PUCHAR Registers, Frame;
    SIZE_T RegisterLength, MappedLength;
    PHYSICAL_ADDRESS Aperture;
    ULONGLONG ApertureLength;
    PB_INFO Info;
    PB_PLANE Selected;
} DEVICE_CONTEXT;
WDF_DECLARE_CONTEXT_TYPE_WITH_NAME(DEVICE_CONTEXT, GetContext)

DRIVER_INITIALIZE DriverEntry;
EVT_WDF_DRIVER_DEVICE_ADD PbDeviceAdd;
EVT_WDF_DEVICE_PREPARE_HARDWARE PbPrepare;
EVT_WDF_DEVICE_RELEASE_HARDWARE PbRelease;
EVT_WDF_DEVICE_D0_ENTRY PbD0Entry;
EVT_WDF_DEVICE_D0_EXIT PbD0Exit;
EVT_WDF_IO_QUEUE_IO_DEVICE_CONTROL PbIoctl;

C_ASSERT(sizeof(PB_PLANE) == 32);
C_ASSERT(sizeof(PB_INFO) == 968);
C_ASSERT(sizeof(PB_FRAME) == 20);

static ULONG ReadReg(DEVICE_CONTEXT *c, ULONG offset)
{
    return READ_REGISTER_ULONG((PULONG)(c->Registers + offset));
}

static PB_PLANE ReadPlane(DEVICE_CONTEXT *c, ULONG pipe, ULONG plane)
{
    PB_PLANE p;
    ULONG reg = 0x70180u + pipe * 0x1000u + plane * 0x100u;
    p.Pipe = pipe; p.Plane = plane;
    p.Control = ReadReg(c, reg);
    p.Stride = ReadReg(c, reg + 8u);
    p.Size = ReadReg(c, reg + 0x10u);
    p.Surface = ReadReg(c, reg + 0x1cu);
    p.Offset = ReadReg(c, reg + 0x24u);
    p.Live = ReadReg(c, reg + 0x2cu);
    return p;
}

static BOOLEAN SamePlane(const PB_PLANE *a, const PB_PLANE *b)
{
    return a->Control == b->Control && a->Stride == b->Stride &&
        a->Size == b->Size && a->Surface == b->Surface &&
        a->Offset == b->Offset && a->Live == b->Live;
}

NTSTATUS DriverEntry(PDRIVER_OBJECT driver, PUNICODE_STRING path)
{
    WDF_DRIVER_CONFIG config;
    WDF_DRIVER_CONFIG_INIT(&config, PbDeviceAdd);
    return WdfDriverCreate(driver, path, WDF_NO_OBJECT_ATTRIBUTES, &config, WDF_NO_HANDLE);
}

NTSTATUS PbDeviceAdd(WDFDRIVER driver, PWDFDEVICE_INIT init)
{
    WDF_PNPPOWER_EVENT_CALLBACKS pnp;
    WDF_OBJECT_ATTRIBUTES attrs;
    WDF_IO_QUEUE_CONFIG queue;
    WDFDEVICE device;
    NTSTATUS status;
    DECLARE_CONST_UNICODE_STRING(name, L"\\Device\\PanelBridge");
    DECLARE_CONST_UNICODE_STRING(link, L"\\DosDevices\\PanelBridge");
    DECLARE_CONST_UNICODE_STRING(security, L"D:P(A;;GA;;;SY)(A;;GA;;;BA)");
    UNREFERENCED_PARAMETER(driver);
    WdfDeviceInitSetDeviceType(init, FILE_DEVICE_UNKNOWN);
    WdfDeviceInitSetCharacteristics(init, FILE_DEVICE_SECURE_OPEN, FALSE);
    WdfDeviceInitSetExclusive(init, TRUE);
    status = WdfDeviceInitAssignName(init, &name);
    if (!NT_SUCCESS(status)) return status;
    status = WdfDeviceInitAssignSDDLString(init, &security);
    if (!NT_SUCCESS(status)) return status;

    WDF_PNPPOWER_EVENT_CALLBACKS_INIT(&pnp);
    pnp.EvtDevicePrepareHardware = PbPrepare;
    pnp.EvtDeviceReleaseHardware = PbRelease;
    pnp.EvtDeviceD0Entry = PbD0Entry;
    pnp.EvtDeviceD0Exit = PbD0Exit;
    WdfDeviceInitSetPnpPowerEventCallbacks(init, &pnp);
    WDF_OBJECT_ATTRIBUTES_INIT_CONTEXT_TYPE(&attrs, DEVICE_CONTEXT);
    attrs.ExecutionLevel = WdfExecutionLevelPassive;
    attrs.SynchronizationScope = WdfSynchronizationScopeDevice;
    status = WdfDeviceCreate(&init, &attrs, &device);
    if (!NT_SUCCESS(status)) return status;
    status = WdfDeviceCreateSymbolicLink(device, &link);
    if (!NT_SUCCESS(status)) return status;
    WDF_IO_QUEUE_CONFIG_INIT_DEFAULT_QUEUE(&queue, WdfIoQueueDispatchSequential);
    queue.EvtIoDeviceControl = PbIoctl;
    return WdfIoQueueCreate(device, &queue, WDF_NO_OBJECT_ATTRIBUTES, WDF_NO_HANDLE);
}

NTSTATUS PbPrepare(WDFDEVICE device, WDFCMRESLIST raw, WDFCMRESLIST translated)
{
    DEVICE_CONTEXT *c = GetContext(device);
    BUS_INTERFACE_STANDARD bus;
    PCI_COMMON_CONFIG pci;
    NTSTATUS status;
    ULONG i, read;
    PCM_PARTIAL_RESOURCE_DESCRIPTOR mmio = NULL, aperture = NULL;
    UNREFERENCED_PARAMETER(raw);
    RtlZeroMemory(&bus, sizeof(bus));
    status = WdfFdoQueryForInterface(device, &GUID_BUS_INTERFACE_STANDARD,
        (PINTERFACE)&bus, sizeof(bus), 1, NULL);
    if (!NT_SUCCESS(status)) return status;
    RtlZeroMemory(&pci, sizeof(pci));
    read = bus.GetBusData(bus.Context, PCI_WHICHSPACE_CONFIG, &pci, 0, PCI_COMMON_HDR_LENGTH);
    bus.InterfaceDereference(bus.Context);
    if (read != PCI_COMMON_HDR_LENGTH || pci.VendorID != 0x8086 || pci.DeviceID != 0x9a49 ||
        (pci.HeaderType & 0x7fu) != PCI_DEVICE_TYPE ||
        pci.u.type0.SubVendorID != 0x1043 || pci.u.type0.SubSystemID != 0x160c)
        return STATUS_NOT_SUPPORTED;

    for (i = 0; i < WdfCmResourceListGetCount(translated); ++i) {
        PCM_PARTIAL_RESOURCE_DESCRIPTOR r = WdfCmResourceListGetDescriptor(translated, i);
        if (!r || r->Type != CmResourceTypeMemory) continue;
        if (!(r->Flags & CM_RESOURCE_MEMORY_PREFETCHABLE) &&
            r->u.Memory.Length >= 0x80000u && r->u.Memory.Length <= 0x4000000u) {
            if (mmio) return STATUS_DEVICE_CONFIGURATION_ERROR;
            mmio = r;
        } else if ((r->Flags & CM_RESOURCE_MEMORY_PREFETCHABLE) &&
            r->u.Memory.Length >= 0x4000000u) {
            if (aperture) return STATUS_DEVICE_CONFIGURATION_ERROR;
            aperture = r;
        }
    }
    if (!mmio || !aperture) return STATUS_DEVICE_CONFIGURATION_ERROR;
    c->RegisterLength = 0x80000u; /* Only documented display registers, mapped read-only. */
    c->Registers = MmMapIoSpaceEx(mmio->u.Memory.Start, c->RegisterLength, PAGE_READONLY | PAGE_NOCACHE);
    if (!c->Registers) return STATUS_INSUFFICIENT_RESOURCES;
    c->Aperture = aperture->u.Memory.Start;
    c->ApertureLength = aperture->u.Memory.Length;
    c->Info.Version = PB_VERSION;
    c->Info.Bytes = sizeof(PB_INFO);
    c->Info.MmioPhysical = (ULONGLONG)mmio->u.Memory.Start.QuadPart;
    c->Info.AperturePhysical = (ULONGLONG)c->Aperture.QuadPart;
    c->Info.ApertureLength = c->ApertureLength;
    return STATUS_SUCCESS;
}

NTSTATUS PbD0Entry(WDFDEVICE device, WDF_POWER_DEVICE_STATE previous)
{
    DEVICE_CONTEXT *c = GetContext(device);
    PHYSICAL_ADDRESS physical;
    ULONG i;
    UNREFERENCED_PARAMETER(previous);
    c->Info.ActivePlanes = 0;
    c->Info.Width = c->Info.Height = c->Info.Pitch = 0;
    c->Info.FrameOffset = c->Info.FrameLength = 0;
    for (i = 0; i < PB_MAX_PLANES; ++i) {
        PB_PLANE p = ReadPlane(c, i / 7u, i % 7u);
        c->Info.Planes[i] = p;
        if (p.Control & 0x80000000u) {
            c->Selected = p;
            ++c->Info.ActivePlanes;
        }
    }
    c->Info.State = c->Info.ActivePlanes == 0 ? PB_NO_PLANE :
        c->Info.ActivePlanes > 1 ? PB_MULTIPLE_PLANES :
        PbValidateLayout(&c->Selected, c->ApertureLength, &c->Info.Pitch,
            &c->Info.FrameOffset, &c->Info.FrameLength);
    /* Diagnostics remain accessible when the firmware layout is unsupported. */
    if (c->Info.State != PB_READY) return STATUS_SUCCESS;
    physical.QuadPart = c->Aperture.QuadPart + (LONGLONG)c->Info.FrameOffset;
    if (physical.QuadPart < c->Aperture.QuadPart) {
        c->Info.State = PB_OUT_OF_APERTURE;
        return STATUS_SUCCESS;
    }
    c->MappedLength = (SIZE_T)c->Info.FrameLength;
    c->Frame = MmMapIoSpaceEx(physical, c->MappedLength, PAGE_READWRITE | PAGE_WRITECOMBINE);
    if (!c->Frame) { c->Info.State = PB_MAP_FAILED; return STATUS_SUCCESS; }
    c->Info.Width = 1920; c->Info.Height = 1080;
    return STATUS_SUCCESS;
}

NTSTATUS PbD0Exit(WDFDEVICE device, WDF_POWER_DEVICE_STATE target)
{
    DEVICE_CONTEXT *c = GetContext(device);
    UNREFERENCED_PARAMETER(target);
    c->Info.State = PB_OFFLINE;
    if (c->Frame) { MmUnmapIoSpace(c->Frame, c->MappedLength); c->Frame = NULL; }
    return STATUS_SUCCESS;
}

NTSTATUS PbRelease(WDFDEVICE device, WDFCMRESLIST translated)
{
    DEVICE_CONTEXT *c = GetContext(device);
    UNREFERENCED_PARAMETER(translated);
    /* Also handles prepare failures, where D0Exit may never have run. */
    if (c->Frame) { MmUnmapIoSpace(c->Frame, c->MappedLength); c->Frame = NULL; }
    if (c->Registers) { MmUnmapIoSpace(c->Registers, c->RegisterLength); c->Registers = NULL; }
    c->Info.State = PB_OFFLINE;
    return STATUS_SUCCESS;
}

VOID PbIoctl(WDFQUEUE queue, WDFREQUEST request, size_t outLength, size_t inLength, ULONG code)
{
    DEVICE_CONTEXT *c = GetContext(WdfIoQueueGetDevice(queue));
    NTSTATUS status = STATUS_INVALID_DEVICE_REQUEST;
    size_t returned = 0;
    if (code == PB_IOCTL_INFO) {
        PB_INFO *out;
        status = WdfRequestRetrieveOutputBuffer(request, sizeof(*out), (PVOID *)&out, NULL);
        if (NT_SUCCESS(status)) { *out = c->Info; returned = sizeof(*out); }
    } else if (code == PB_IOCTL_FRAME) {
        PB_FRAME *frame;
        PMDL mdl;
        PUCHAR source;
        PB_PLANE current;
        ULONG i, y;
        if (!c->Frame || c->Info.State != PB_READY) {
            status = STATUS_DEVICE_NOT_READY; goto done;
        }
        if (inLength != sizeof(PB_FRAME)) { status = STATUS_INVALID_PARAMETER; goto done; }
        status = WdfRequestRetrieveInputBuffer(request, sizeof(*frame), (PVOID *)&frame, NULL);
        if (!NT_SUCCESS(status)) goto done;
        status = WdfRequestRetrieveOutputWdmMdl(request, &mdl);
        if (!NT_SUCCESS(status)) goto done;
        if (!PbValidateFrame(frame, MmGetMdlByteCount(mdl)) || frame->Bytes > outLength) {
            status = STATUS_INVALID_BUFFER_SIZE; goto done;
        }
        /* Detect a modeset or additional enabled plane before touching aperture memory. */
        for (i = 0; i < PB_MAX_PLANES; ++i) {
            current = ReadPlane(c, i / 7u, i % 7u);
            if (!SamePlane(&current, &c->Info.Planes[i])) {
                c->Info.State = PB_LAYOUT_CHANGED;
                status = STATUS_DEVICE_NOT_READY; goto done;
            }
        }
        source = MmGetSystemAddressForMdlSafe(mdl, NormalPagePriority | MdlMappingNoExecute);
        if (!source) { status = STATUS_INSUFFICIENT_RESOURCES; goto done; }
        for (y = 0; y < frame->Height; ++y)
            RtlCopyMemory(c->Frame + (SIZE_T)y * c->Info.Pitch,
                source + (SIZE_T)y * frame->Pitch, frame->Width * 4u);
        KeMemoryBarrier();
        status = STATUS_SUCCESS;
    }
done:
    WdfRequestCompleteWithInformation(request, status, returned);
}
