// dxgi.zig — fake dxgi.dll entry points
//
// Forwards CreateDXGIFactory / CreateDXGIFactory1 / CreateDXGIFactory2
// to the real system dxgi.dll, then installs vtable hooks on the returned
// factory's first adapter to spoof the GPU name.

const hook = @import("core");
const GUID = hook.GUID;
const HRESULT = hook.HRESULT;
const S_OK = hook.S_OK;
const E_FAIL = hook.E_FAIL;

// Win32 imports
extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(hModule: *anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*anyopaque;

var real_dxgi: ?*anyopaque = null;

fn ensureRealDxgi() void {
    if (real_dxgi == null) {
        real_dxgi = LoadLibraryA("C:\\Windows\\System32\\dxgi.dll");
    }
}

export fn CreateDXGIFactory(riid: *const GUID, pp_factory: *?*anyopaque) callconv(.winapi) HRESULT {
    ensureRealDxgi();
    const lib = real_dxgi orelse return E_FAIL;
    const proc = GetProcAddress(lib, "CreateDXGIFactory") orelse return E_FAIL;
    const func: *const fn (*const GUID, *?*anyopaque) callconv(.winapi) HRESULT = @ptrCast(proc);
    const hr = func(riid, pp_factory);
    if (hr == S_OK) hook.tryInstallHook(pp_factory);
    return hr;
}

export fn CreateDXGIFactory1(riid: *const GUID, pp_factory: *?*anyopaque) callconv(.winapi) HRESULT {
    ensureRealDxgi();
    const lib = real_dxgi orelse return E_FAIL;
    const proc = GetProcAddress(lib, "CreateDXGIFactory1") orelse return E_FAIL;
    const func: *const fn (*const GUID, *?*anyopaque) callconv(.winapi) HRESULT = @ptrCast(proc);
    const hr = func(riid, pp_factory);
    if (hr == S_OK) hook.tryInstallHook(pp_factory);
    return hr;
}

export fn CreateDXGIFactory2(flags: u32, riid: *const GUID, pp_factory: *?*anyopaque) callconv(.winapi) HRESULT {
    ensureRealDxgi();
    const lib = real_dxgi orelse return E_FAIL;
    const proc = GetProcAddress(lib, "CreateDXGIFactory2") orelse return E_FAIL;
    const func: *const fn (u32, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT = @ptrCast(proc);
    const hr = func(flags, riid, pp_factory);
    if (hr == S_OK) hook.tryInstallHook(pp_factory);
    return hr;
}

// DLL_PROCESS_ATTACH = 1
export fn DllMain(hinst: *anyopaque, reason: u32, reserved: ?*anyopaque) callconv(.winapi) i32 {
    _ = hinst;
    _ = reserved;
    if (reason == 1) { // DLL_PROCESS_ATTACH
        ensureRealDxgi();
    }
    return 1; // TRUE
}
