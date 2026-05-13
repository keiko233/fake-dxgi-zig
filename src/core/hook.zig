// core/hook.zig 鈥?GPU name faker via IDXGIAdapter vtable patching
//
// Strategy: Instead of binary detour patching, we replace the vtable function
// pointers in the adapter object's vtable in-place using VirtualProtect.
//
// IDXGIAdapter vtable layout (indices):
//   IUnknown:      0 QueryInterface  1 AddRef  2 Release
//   IDXGIObject:   3 SetPrivateData  4 SetPrivateDataInterface
//                  5 GetPrivateData  6 GetParent
//   IDXGIAdapter:  7 EnumOutputs     8 GetDesc  9 CheckInterfaceSupport
//   IDXGIAdapter1: 10 GetDesc1

pub const HRESULT = i32;
pub const S_OK: HRESULT = 0;
pub const E_FAIL: HRESULT = @bitCast(@as(u32, 0x80004005));

const PAGE_EXECUTE_READWRITE: u32 = 0x40;

// Win32 imports
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn VirtualProtect(lpAddress: *anyopaque, dwSize: usize, flNewProtect: u32, lpflOldProtect: *u32) callconv(.winapi) i32;

// GUID layout
pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

// DXGI_ADAPTER_DESC
pub const DXGI_ADAPTER_DESC = extern struct {
    Description: [128]u16,
    VendorId: u32,
    DeviceId: u32,
    SubSysId: u32,
    Revision: u32,
    DedicatedVideoMemory: usize,
    DedicatedSystemMemory: usize,
    SharedSystemMemory: usize,
    AdapterLuid: i64,
};

// DXGI_ADAPTER_DESC1 adds Flags at the end
pub const DXGI_ADAPTER_DESC1 = extern struct {
    Description: [128]u16,
    VendorId: u32,
    DeviceId: u32,
    SubSysId: u32,
    Revision: u32,
    DedicatedVideoMemory: usize,
    DedicatedSystemMemory: usize,
    SharedSystemMemory: usize,
    AdapterLuid: i64,
    Flags: u32,
};

pub const GetDescFn = *const fn (this: *anyopaque, desc: *DXGI_ADAPTER_DESC) callconv(.winapi) HRESULT;
pub const GetDesc1Fn = *const fn (this: *anyopaque, desc: *DXGI_ADAPTER_DESC1) callconv(.winapi) HRESULT;

/// The fake GPU name string (ASCII, provided via build options).
pub const fake_gpu_name_str = @import("build_options").fake_gpu_name;

/// Original vtable pointers saved before patching
var orig_get_desc: ?GetDescFn = null;
var orig_get_desc1: ?GetDesc1Fn = null;
var hook_installed: bool = false;

fn hooked_get_desc(this: *anyopaque, desc: *DXGI_ADAPTER_DESC) callconv(.winapi) HRESULT {
    const hr = orig_get_desc.?(this, desc);
    if (hr == S_OK) {
        writeFakeName(&desc.Description);
    }
    return hr;
}

fn hooked_get_desc1(this: *anyopaque, desc: *DXGI_ADAPTER_DESC1) callconv(.winapi) HRESULT {
    const hr = orig_get_desc1.?(this, desc);
    if (hr == S_OK) {
        writeFakeName(&desc.Description);
    }
    return hr;
}

fn writeFakeName(buf: *[128]u16) void {
    const src = fake_gpu_name_str;
    var i: usize = 0;
    while (i < src.len and i < 127) : (i += 1) {
        buf[i] = @as(u16, src[i]);
    }
    buf[i] = 0;
}

/// Patch the vtable of the adapter COM object in-place.
fn patchVtable(adapter: *anyopaque) void {
    const vtable_ptr: *[*]usize = @ptrCast(@alignCast(adapter));
    const vtable: [*]usize = vtable_ptr.*;

    orig_get_desc = @ptrFromInt(vtable[8]);
    orig_get_desc1 = @ptrFromInt(vtable[10]);

    var old_protect: u32 = 0;
    const page_size = 11 * @sizeOf(usize);
    _ = VirtualProtect(@ptrCast(vtable), page_size, PAGE_EXECUTE_READWRITE, &old_protect);

    vtable[8] = @intFromPtr(&hooked_get_desc);
    vtable[10] = @intFromPtr(&hooked_get_desc1);

    _ = VirtualProtect(@ptrCast(vtable), page_size, old_protect, &old_protect);
}

/// Called after CreateDXGIFactory* succeeds.
pub fn tryInstallHook(pp_factory: *?*anyopaque) void {
    if (hook_installed) return;

    const factory = pp_factory.* orelse return;

    const EnumAdaptersFn = *const fn (this: *anyopaque, adapter_idx: u32, pp_adapter: *?*anyopaque) callconv(.winapi) HRESULT;
    const vtable_ptr: *[*]usize = @ptrCast(@alignCast(factory));
    const vtable: [*]usize = vtable_ptr.*;
    const enum_adapters: EnumAdaptersFn = @ptrFromInt(vtable[7]);

    var adapter: ?*anyopaque = null;
    const hr = enum_adapters(factory, 0, &adapter);
    if (hr != S_OK or adapter == null) return;

    patchVtable(adapter.?);

    const ReleaseFn = *const fn (this: *anyopaque) callconv(.winapi) u32;
    const adp_vtable_ptr: *[*]usize = @ptrCast(@alignCast(adapter.?));
    const adp_vtable: [*]usize = adp_vtable_ptr.*;
    const adp_release: ReleaseFn = @ptrFromInt(adp_vtable[2]);
    _ = adp_release(adapter.?);

    hook_installed = true;
}

/// Used by non-dxgi DLLs: loads dxgi, creates a factory, installs the hook, releases.
pub fn installHookViaDxgi() void {
    const dxgi = LoadLibraryA("C:\\Windows\\System32\\dxgi.dll") orelse return;
    const proc = GetProcAddress(dxgi, "CreateDXGIFactory1") orelse return;

    // IDXGIFactory1 IID: {770aae78-f26f-4dba-a829-253c83d1b387}
    const iid_factory1 = GUID{
        .Data1 = 0x770aae78,
        .Data2 = 0xf26f,
        .Data3 = 0x4dba,
        .Data4 = .{ 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 },
    };

    const CreateFactory1Fn = *const fn (riid: *const GUID, pp_factory: *?*anyopaque) callconv(.winapi) HRESULT;
    const create: CreateFactory1Fn = @ptrCast(proc);

    var factory: ?*anyopaque = null;
    const hr = create(&iid_factory1, &factory);
    if (hr != S_OK or factory == null) return;

    tryInstallHook(&factory);

    const ReleaseFn = *const fn (this: *anyopaque) callconv(.winapi) u32;
    const vtable_ptr: *[*]usize = @ptrCast(@alignCast(factory.?));
    const vtable: [*]usize = vtable_ptr.*;
    const release: ReleaseFn = @ptrFromInt(vtable[2]);
    _ = release(factory.?);
}
