instance: wgpu.WGPUInstance,
surface: wgpu.WGPUSurface,
adapter: wgpu.WGPUAdapter,
device: wgpu.WGPUDevice,
queue: wgpu.WGPUQueue,
surface_config: wgpu.WGPUSurfaceConfiguration,
device_limits: wgpu.WGPULimits,
depth_texture: wgpu.WGPUTexture,
depth_texture_view: wgpu.WGPUTextureView,

// 释放WGPU资源
pub fn deinit(self: @This()) void {
    wgpu.wgpuQueueRelease(self.queue);
    wgpu.wgpuDeviceRelease(self.device);
    wgpu.wgpuAdapterRelease(self.adapter);
    wgpu.wgpuSurfaceRelease(self.surface);
    wgpu.wgpuInstanceRelease(self.instance);
    wgpu.wgpuTextureRelease(self.depth_texture);
    wgpu.wgpuTextureViewRelease(self.depth_texture_view);
}

// 初始化WGPU上下文
pub fn init(
    window: *Window,
) !@This() {
    // 创建WGPU实例
    const instance_extras = wgpu.WGPUInstanceExtras{
        .chain = wgpu.WGPUChainedStruct{
            .sType = wgpu.WGPUSType_InstanceExtras,
        },
        .backends = wgpu.WGPUInstanceBackend_DX12, // 或者使用具体的后端组合
    };
    // 2. 创建主描述符，并将扩展结构体链入
    const instance_descriptor = wgpu.WGPUInstanceDescriptor{
        .nextInChain = @ptrCast(&instance_extras.chain), // 通过链式结构连接
    };
    // 3. 创建实例
    const instance = wgpu.wgpuCreateInstance(&instance_descriptor);
    if (instance == null) return error.InstanceCreationFailed;

    // 创建Surface
    const hwnd = glfw.glfwGetWin32Window(window.handle);
    const hinstance = glfw.GetModuleHandleW(null); // 获取实例句柄
    const win32_surface_desc = wgpu.WGPUSurfaceSourceWindowsHWND{
        .chain = wgpu.WGPUChainedStruct{
            .sType = wgpu.WGPUSType_SurfaceSourceWindowsHWND,
        },
        .hwnd = hwnd,
        .hinstance = hinstance, // 添加实例句柄
    };
    const surface_desc = wgpu.WGPUSurfaceDescriptor{
        .nextInChain = @ptrCast(&win32_surface_desc.chain),
    };
    const surface = wgpu.wgpuInstanceCreateSurface(instance, &surface_desc);
    if (surface == null) return error.SurfaceCreationFailed;

    // 创建适配器
    const adapter_options = wgpu.WGPURequestAdapterOptions{
        .compatibleSurface = surface,
    };
    var adapter: wgpu.WGPUAdapter = undefined;
    const callback_info = wgpu.WGPURequestAdapterCallbackInfo{
        .callback = requestAdapterCallback,
        .userdata1 = @ptrCast(&adapter),
    };
    _ = wgpu.wgpuInstanceRequestAdapter(
        instance,
        &adapter_options,
        callback_info,
    );
    if (adapter == null) return error.AdapterRequestFailed;

    // 创建设备
    const required_features = &[_]wgpu.WGPUFeatureName{
        wgpu.WGPUFeatureName_IndirectFirstInstance,
    };

    var device: wgpu.WGPUDevice = undefined;
    const device_desc = wgpu.WGPUDeviceDescriptor{
        .requiredFeatures = required_features,
        .requiredFeatureCount = required_features.len,
    };
    _ = wgpu.wgpuAdapterRequestDevice(adapter, &device_desc, .{
        .mode = wgpu.WGPUCallbackMode_AllowSpontaneous,
        .callback = requestDeviceCallback, // 直接传递回调函数
        .userdata1 = @ptrCast(&device), // 传递用户数据
    });
    if (device == null) return error.DeviceRequestFailed;
    // 配置Surface
    const surface_config = wgpu.WGPUSurfaceConfiguration{
        .device = device,
        .format = wgpu.WGPUTextureFormat_BGRA8UnormSrgb,
        .usage = wgpu.WGPUTextureUsage_RenderAttachment,
        .alphaMode = wgpu.WGPUCompositeAlphaMode_Auto,
        .width = window.width,
        .height = window.height,
        .presentMode = wgpu.WGPUPresentMode_Immediate,
    };
    wgpu.wgpuSurfaceConfigure(surface, &surface_config);

    // 获取设备限制
    var device_limits = wgpu.WGPULimits{};
    _ = wgpu.wgpuDeviceGetLimits(device, &device_limits);

    // 创建队列
    const queue = wgpu.wgpuDeviceGetQueue(device);

    // 创建深度纹理和视图
    const depth_texture = wgpu.wgpuDeviceCreateTexture(device, &wgpu.WGPUTextureDescriptor{
        .usage = wgpu.WGPUTextureUsage_RenderAttachment,
        .dimension = wgpu.WGPUTextureDimension_2D,
        .size = .{
            .width = surface_config.width,
            .height = surface_config.height,
            .depthOrArrayLayers = 1,
        },
        .format = wgpu.WGPUTextureFormat_Depth24Plus,
        .mipLevelCount = 1,
        .sampleCount = 1,
    });
    const depth_texture_view = wgpu.wgpuTextureCreateView(depth_texture, null);

    return .{
        .instance = instance,
        .surface = surface,
        .adapter = adapter,
        .device = device,
        .queue = queue,
        .surface_config = surface_config,
        .device_limits = device_limits,
        .depth_texture = depth_texture,
        .depth_texture_view = depth_texture_view,
    };
}

// 请求适配器回调函数
fn requestAdapterCallback(
    status: wgpu.WGPURequestAdapterStatus,
    adapter: wgpu.WGPUAdapter,
    message: wgpu.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    if (status == wgpu.WGPURequestAdapterStatus_Success) {
        const adapter_ptr: *wgpu.WGPUAdapter = @ptrCast(@alignCast(userdata1));
        adapter_ptr.* = adapter;
    }
}

// 请求设备回调函数
fn requestDeviceCallback(
    status: wgpu.WGPURequestDeviceStatus,
    device: wgpu.WGPUDevice,
    message: wgpu.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    if (status == wgpu.WGPURequestDeviceStatus_Success) {
        const device_ptr: *wgpu.WGPUDevice = @ptrCast(@alignCast(userdata1));
        device_ptr.* = device;
    }
}

pub fn createShaderModule(gctx: *Gctx, shader_file_path: []const u8) !wgpu.WGPUShaderModule {
    const code_file = try std.fs.cwd().openFile(shader_file_path, .{});
    defer code_file.close();

    var shader_code: [128 * 4096]u8 = undefined;
    var reader = code_file.reader(&shader_code);
    const size = try reader.file.read(&shader_code);

    const shader_source = wgpu.struct_WGPUShaderSourceWGSL{
        .code = .{
            .data = shader_code[0..size].ptr,
            .length = size,
        },
        .chain = .{
            .sType = wgpu.WGPUSType_ShaderSourceWGSL,
        },
    };
    const shader_desc = wgpu.WGPUShaderModuleDescriptor{
        .nextInChain = &shader_source.chain,
    };
    return wgpu.wgpuDeviceCreateShaderModule(gctx.device, &shader_desc);
}

pub fn generateVertexAttributes(comptime VertexType: type) [std.meta.fields(VertexType).len]wgpu.WGPUVertexAttribute {
    const fields = std.meta.fields(VertexType);
    var attributes: [fields.len]wgpu.WGPUVertexAttribute = undefined;
    var offset: usize = 0;
    inline for (fields, 0..) |field, i| {
        const format = switch (field.type) {
            f32 => wgpu.WGPUVertexFormat_Float32,
            [2]f32 => wgpu.WGPUVertexFormat_Float32x2,
            [3]f32 => wgpu.WGPUVertexFormat_Float32x3,
            [4]f32 => wgpu.WGPUVertexFormat_Float32x4,
            u32 => wgpu.WGPUVertexFormat_Uint32,
            [4]u32 => wgpu.WGPUVertexFormat_Uint32x4,
            else => @compileError("Unsupported vertex attribute type: " ++ @typeName(field.type)),
        };
        attributes[i] = .{
            .format = format,
            .offset = offset,
            .shaderLocation = @intCast(i),
        };
        offset += @sizeOf(field.type);
    }
    return attributes;
}

const std = @import("std");
const Window = @import("window.zig");
const Gctx = @import("gctx.zig");

const wgpu = @import("cimports.zig").wgpu;
const glfw = @import("cimports.zig").glfw;
