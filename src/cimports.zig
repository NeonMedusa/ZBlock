pub const Glfw = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cDefine("GLFW_EXPOSE_NATIVE_WIN32", "1");
    @cInclude("glfw3.h");
    @cInclude("glfw3native.h");
});

pub const Wgpu = @cImport({
    @cInclude("wgpu.h");
});
