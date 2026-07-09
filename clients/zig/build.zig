// Fiducia Zig client build script. Verified with Zig 0.16.0.
//
//   zig build            # build the static library artifact
//   zig build test       # run the unit tests
//
// Dependents fetch this package (see build.zig.zon) and import the module:
//
//   const fiducia_dep = b.dependency("fiducia_client", .{ .target = target, .optimize = optimize });
//   exe.root_module.addImport("fiducia", fiducia_dep.module("fiducia"));

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Public module — dependents `@import("fiducia")`.
    const mod = b.addModule("fiducia", .{
        .root_source_file = b.path("src/fiducia.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library artifact (doubles as a compile smoke-test).
    const lib = b.addLibrary(.{
        .name = "fiducia",
        .root_module = mod,
    });
    b.installArtifact(lib);

    // Unit tests: `zig build test`.
    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run fiducia client unit tests");
    test_step.dependOn(&run_tests.step);
}
