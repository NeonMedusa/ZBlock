instance: Wgpu.WGPUInstance,
surface: Wgpu.WGPUSurface,
adapter: Wgpu.WGPUAdapter,
device: Wgpu.WGPUDevice,
queue: Wgpu.WGPUQueue,
surface_config: Wgpu.WGPUSurfaceConfiguration,
device_limits: Wgpu.WGPULimits,
depth_texture: Wgpu.WGPUTexture,
depth_texture_view: Wgpu.WGPUTextureView,

// 释放WGPU资源
pub fn deinit(self: @This()) void {
    Wgpu.wgpuQueueRelease(self.queue);
    Wgpu.wgpuDeviceRelease(self.device);
    Wgpu.wgpuAdapterRelease(self.adapter);
    Wgpu.wgpuSurfaceRelease(self.surface);
    Wgpu.wgpuInstanceRelease(self.instance);
    Wgpu.wgpuTextureRelease(self.depth_texture);
    Wgpu.wgpuTextureViewRelease(self.depth_texture_view);
}

// 初始化WGPU上下文
pub fn init(
    window: *Window,
) !@This() {
    // 创建WGPU实例
    const instance_extras = Wgpu.WGPUInstanceExtras{
        .chain = Wgpu.WGPUChainedStruct{
            .sType = Wgpu.WGPUSType_InstanceExtras,
        },
        .backends = Wgpu.WGPUInstanceBackend_DX12, // 或者使用具体的后端组合
    };
    // 2. 创建主描述符，并将扩展结构体链入
    const instance_descriptor = Wgpu.WGPUInstanceDescriptor{
        .nextInChain = @ptrCast(&instance_extras.chain), // 通过链式结构连接
    };
    // 3. 创建实例
    const instance = Wgpu.wgpuCreateInstance(&instance_descriptor);
    if (instance == null) return error.InstanceCreationFailed;

    // 创建Surface
    const hwnd = Glfw.glfwGetWin32Window(window.handle);
    const hinstance = Glfw.GetModuleHandleW(null); // 获取实例句柄
    const win32_surface_desc = Wgpu.WGPUSurfaceSourceWindowsHWND{
        .chain = Wgpu.WGPUChainedStruct{
            .sType = Wgpu.WGPUSType_SurfaceSourceWindowsHWND,
        },
        .hwnd = hwnd,
        .hinstance = hinstance, // 添加实例句柄
    };
    const surface_desc = Wgpu.WGPUSurfaceDescriptor{
        .nextInChain = @ptrCast(&win32_surface_desc.chain),
    };
    const surface = Wgpu.wgpuInstanceCreateSurface(instance, &surface_desc);
    if (surface == null) return error.SurfaceCreationFailed;

    // 创建适配器
    const adapter_options = Wgpu.WGPURequestAdapterOptions{
        .compatibleSurface = surface,
    };
    var adapter: Wgpu.WGPUAdapter = undefined;
    const callback_info = Wgpu.WGPURequestAdapterCallbackInfo{
        .callback = requestAdapterCallback,
        .userdata1 = @ptrCast(&adapter),
    };
    _ = Wgpu.wgpuInstanceRequestAdapter(
        instance,
        &adapter_options,
        callback_info,
    );
    if (adapter == null) return error.AdapterRequestFailed;

    // 创建设备
    const required_features = &[_]Wgpu.WGPUFeatureName{
        Wgpu.WGPUFeatureName_IndirectFirstInstance,
            // wgpu.WGPUFeatureName_TextureCompressionBC,
    };

    var device: Wgpu.WGPUDevice = undefined;
    const device_desc = Wgpu.WGPUDeviceDescriptor{
        .requiredFeatures = required_features,
        .requiredFeatureCount = required_features.len,
    };
    _ = Wgpu.wgpuAdapterRequestDevice(adapter, &device_desc, .{
        .mode = Wgpu.WGPUCallbackMode_AllowSpontaneous,
        .callback = requestDeviceCallback, // 直接传递回调函数
        .userdata1 = @ptrCast(&device), // 传递用户数据
    });
    if (device == null) return error.DeviceRequestFailed;
    // 配置Surface
    const surface_config = Wgpu.WGPUSurfaceConfiguration{
        .device = device,
        .format = Wgpu.WGPUTextureFormat_BGRA8UnormSrgb,
        .usage = Wgpu.WGPUTextureUsage_RenderAttachment,
        .alphaMode = Wgpu.WGPUCompositeAlphaMode_Auto,
        .width = window.width,
        .height = window.height,
        .presentMode = Wgpu.WGPUPresentMode_Immediate,
    };
    Wgpu.wgpuSurfaceConfigure(surface, &surface_config);

    // 获取设备限制
    var device_limits = Wgpu.WGPULimits{};
    _ = Wgpu.wgpuDeviceGetLimits(device, &device_limits);

    // 创建队列
    const queue = Wgpu.wgpuDeviceGetQueue(device);

    // 创建深度纹理和视图
    const depth_texture = Wgpu.wgpuDeviceCreateTexture(device, &Wgpu.WGPUTextureDescriptor{
        .usage = Wgpu.WGPUTextureUsage_RenderAttachment,
        .dimension = Wgpu.WGPUTextureDimension_2D,
        .size = .{
            .width = surface_config.width,
            .height = surface_config.height,
            .depthOrArrayLayers = 1,
        },
        .format = Wgpu.WGPUTextureFormat_Depth24Plus,
        .mipLevelCount = 1,
        .sampleCount = 1,
    });
    const depth_texture_view = Wgpu.wgpuTextureCreateView(depth_texture, null);

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
    status: Wgpu.WGPURequestAdapterStatus,
    adapter: Wgpu.WGPUAdapter,
    message: Wgpu.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    if (status == Wgpu.WGPURequestAdapterStatus_Success) {
        const adapter_ptr: *Wgpu.WGPUAdapter = @ptrCast(@alignCast(userdata1));
        adapter_ptr.* = adapter;
    }
}

// 请求设备回调函数
fn requestDeviceCallback(
    status: Wgpu.WGPURequestDeviceStatus,
    device: Wgpu.WGPUDevice,
    message: Wgpu.WGPUStringView,
    userdata1: ?*anyopaque,
    userdata2: ?*anyopaque,
) callconv(.c) void {
    _ = message;
    _ = userdata2;
    if (status == Wgpu.WGPURequestDeviceStatus_Success) {
        const device_ptr: *Wgpu.WGPUDevice = @ptrCast(@alignCast(userdata1));
        device_ptr.* = device;
    }
}

pub fn createShaderModule(gctx: *Gctx, shader_file_path: []const u8) !Wgpu.WGPUShaderModule {
    const code_file = try std.fs.cwd().openFile(shader_file_path, .{});
    defer code_file.close();

    var shader_code: [128 * 4096]u8 = undefined;
    var reader = code_file.reader(&shader_code);
    const size = try reader.file.read(&shader_code);

    const shader_source = Wgpu.struct_WGPUShaderSourceWGSL{
        .code = .{
            .data = shader_code[0..size].ptr,
            .length = size,
        },
        .chain = .{
            .sType = Wgpu.WGPUSType_ShaderSourceWGSL,
        },
    };
    const shader_desc = Wgpu.WGPUShaderModuleDescriptor{
        .nextInChain = &shader_source.chain,
    };
    return Wgpu.wgpuDeviceCreateShaderModule(gctx.device, &shader_desc);
}

pub fn generateVertexAttributes(comptime VertexType: type) [std.meta.fields(VertexType).len]Wgpu.WGPUVertexAttribute {
    const fields = std.meta.fields(VertexType);
    var attributes: [fields.len]Wgpu.WGPUVertexAttribute = undefined;
    var offset: usize = 0;
    inline for (fields, 0..) |field, i| {
        const format = switch (field.type) {
            f32 => Wgpu.WGPUVertexFormat_Float32,
            [2]f32 => Wgpu.WGPUVertexFormat_Float32x2,
            [3]f32 => Wgpu.WGPUVertexFormat_Float32x3,
            [4]f32 => Wgpu.WGPUVertexFormat_Float32x4,
            u32 => Wgpu.WGPUVertexFormat_Uint32,
            [4]u32 => Wgpu.WGPUVertexFormat_Uint32x4,
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

const Wgpu = @import("cimports.zig").Wgpu;
const Glfw = @import("cimports.zig").Glfw;
