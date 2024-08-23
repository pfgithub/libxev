const std = @import("std");
const CompileStep = std.build.Step.Compile;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("xev", .{ .root_source_file = b.path("src/main.zig") });

    const test_install = b.option(
        bool,
        "install-tests",
        "Install the test binaries into zig-out",
    ) orelse false;

    // Our tests require libc on Linux and Mac. Note that libxev itself
    // does NOT require libc.
    const test_libc = switch (target.result.os.tag) {
        .linux, .macos => true,
        else => false,
    };

    // We always build our test exe as part of `zig build` so that
    // we can easily run it manually without digging through the cache.
    const test_exe = b.addTest(.{
        .name = "xev-test",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (test_libc) test_exe.linkLibC(); // Tests depend on libc, libxev does not
    if (test_install) b.installArtifact(test_exe);

    // zig build test test binary and runner.
    const tests_run = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests_run.step);

    // Dynamic C lib. We only build this if this is the native target so we
    // can link to libxml2 on our native system.
    if (target.query.isNative()) {
        const dynamic_lib_name = "xev";

        const dynamic_lib = b.addSharedLibrary(.{
            .name = dynamic_lib_name,
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = optimize,
        });
        b.installArtifact(dynamic_lib);
        b.default_step.dependOn(&dynamic_lib.step);

        const dynamic_binding_test = b.addExecutable(.{
            .name = "dynamic-binding-test",
            .target = target,
            .optimize = optimize,
        });
        dynamic_binding_test.linkLibC();
        dynamic_binding_test.addIncludePath(b.path("include"));
        dynamic_binding_test.addCSourceFile(.{
            .file = b.path("examples/_basic.c"),
            .flags = &[_][]const u8{ "-Wall", "-Wextra", "-pedantic", "-std=c99" },
        });
        dynamic_binding_test.linkLibrary(dynamic_lib);
        if (test_install) b.installArtifact(dynamic_binding_test);

        const dynamic_binding_test_run = b.addRunArtifact(dynamic_binding_test);
        test_step.dependOn(&dynamic_binding_test_run.step);
    }

    // C Headers
    const c_header = b.addInstallFileWithDir(
        b.path("include/xev.h"),
        .header,
        "xev.h",
    );
    b.getInstallStep().dependOn(&c_header.step);

    // pkg-config
    {
        const file = try b.cache_root.join(b.allocator, &[_][]const u8{"libxev.pc"});
        const pkgconfig_file = try std.fs.cwd().createFile(file, .{});

        const writer = pkgconfig_file.writer();
        try writer.print(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: libxev
            \\URL: https://github.com/mitchellh/libxev
            \\Description: High-performance, cross-platform event loop
            \\Version: 0.1.0
            \\Cflags: -I${{includedir}}
            \\Libs: -L${{libdir}} -lxev
        , .{b.install_prefix});
        defer pkgconfig_file.close();

        b.getInstallStep().dependOn(&b.addInstallFileWithDir(
            .{ .cwd_relative = file },
            .prefix,
            "share/pkgconfig/libxev.pc",
        ).step);
    }
}
