const std = @import("std");

var target: std.Build.ResolvedTarget = undefined;
var optimize: std.builtin.OptimizeMode = undefined;
var makedefs_cmds: [10]*std.Build.Step.Run = undefined;

fn find_all(
    b: *std.Build,
    path: []const u8,
    extension: []const u8,
) ![][]const u8 {
    const wildcard = std.mem.eql(u8, ".*", extension);
    var files = std.ArrayList([]const u8).init(b.allocator);
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true });
    var dir_it = dir.iterate();
    while (try dir_it.next()) |file| {
        const name = file.name;
        if (wildcard or std.mem.eql(u8, std.fs.path.extension(name), extension)) {
            try files.append(try std.mem.concat(b.allocator, u8, &.{ path, name }));
        }
    }
    return files.toOwnedSlice();
}

fn prepare(b: *std.Build) !void {
    const paths = [_][]const u8{
        "zig-out/src",
        "zig-out/include",
        "zig-out/dat",
        "zig-out/util",
        "zig-out/nh",
    };
    const cwd = std.fs.cwd();
    for (paths) |path| {
        try cwd.makePath(path);
    }
    for (try find_all(b, "nethack/dat/", ".*")) |file| {
        _ = try cwd.updateFile(
            file,
            cwd,
            try std.mem.concat(
                b.allocator,
                u8,
                &.{ "zig-out/dat/", std.fs.path.basename(file) },
            ),
            .{},
        );
    }
    _ = try cwd.updateFile("nethack/sys/unix/sysconf", cwd, "zig-out/nh/sysconf", .{});
}

fn build_c(
    b: *std.Build,
    name: []const u8,
    src_files: []const []const u8,
    src_paths: []const []const u8,
    include_paths: []const []const u8,
    libs: []const []const u8,
) !*std.Build.Step.Compile {
    const outdir = try std.fs.cwd().realpathAlloc(b.allocator, "zig-out/nh");
    const cflags = .{
        "-w",
        "-fno-sanitize=all",
        "-DNOTPARMDECL",
        "-DDLB",
        "-DCOMPRESS=\"/bin/gzip\"",
        "-DCOMPRESS_EXTENSION=\".gz\"",
        "-DSYSCF",
        try std.mem.concat(b.allocator, u8, &.{ "-DSYSCF_FILE=\"", outdir, "/sysconf\"" }),
        "-DSECURE",
        "-DTIMED_DELAY",
        try std.mem.concat(b.allocator, u8, &.{ "-DHACKDIR=\"", outdir, "\"" }),
        "-DDUMPLOG",
        "-DCONFIG_ERROR_SECURE=FALSE",
        "-DCURSES_GRAPHICS",
    };
    const exe = b.addExecutable(.{
        .name = name,
        .target = target,
        .optimize = optimize,
    });
    exe.addCSourceFiles(.{ .files = src_files, .flags = &cflags });
    for (src_paths) |dirname| {
        exe.addCSourceFiles(.{ .files = try find_all(b, dirname, ".c"), .flags = &cflags });
    }
    for (include_paths) |path| {
        exe.addIncludePath(b.path(path));
    }
    for (libs) |lib| {
        exe.linkSystemLibrary(lib);
    }
    exe.linkLibC();
    b.installArtifact(exe);
    return exe;
}

fn build_makedefs(b: *std.Build) !void {
    const src_files = [_][]const u8{
        "nethack/util/makedefs.c",
        "nethack/src/objects.c",
        "nethack/src/monst.c",
    };
    const src_paths = [_][]const u8{};
    const include_paths = [_][]const u8{
        "nethack/include",
    };
    const libs = [_][]const u8{};
    const flags = [_][]const u8{ "-o", "-d", "-e", "-v", "-p", "-q", "-r", "-s", "-h", "-z" };
    const makedefs = try build_c(
        b,
        "makedefs",
        &src_files,
        &src_paths,
        &include_paths,
        &libs,
    );
    const install = b.getInstallStep();
    const makedefs_step = b.step("makedefs", "Run makedefs util");
    for (flags, 0..) |flag, i| {
        const cmd = b.addRunArtifact(makedefs);
        cmd.addArg(flag);
        cmd.setCwd(b.path("zig-out/util/"));
        makedefs_cmds[i] = cmd;
        makedefs_step.dependOn(&cmd.step);
        install.dependOn(&cmd.step);
    }
}

fn build_nethack(b: *std.Build) !void {
    const src_paths = [_][]const u8{
        "nethack/src/",
        "nethack/win/curses/",
        "nethack/win/tty/",
    };
    const src_files = [_][]const u8{
        "nethack/sys/unix/unixmain.c",
        "nethack/sys/unix/unixunix.c",
        "nethack/sys/share/posixregex.c",
        "nethack/sys/share/unixtty.c",
        "nethack/sys/share/ioctl.c",
    };
    const include_paths = [_][]const u8{
        "nethack/include",
        "nethack/win/curses",
        "zig-out/include",
    };
    const libs = [_][]const u8{
        "curses",
    };
    const nethack = try build_c(b, "nethack", &src_files, &src_paths, &include_paths, &libs);
    const nethack_step = b.step("nethack", "Run nethack on the terminal");
    const nethack_cmd = b.addRunArtifact(nethack);
    nethack_step.dependOn(&nethack_cmd.step);
    for (makedefs_cmds) |cmd| {
        nethack.step.dependOn(&cmd.step);
    }
}

fn build_trihack(b: *std.Build) void {
    const exe = b.addExecutable(.{
        .name = "trihack",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run trihack");
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
}

pub fn build(b: *std.Build) !void {
    target = b.standardTargetOptions(.{});
    optimize = b.standardOptimizeOption(.{});
    try prepare(b);
    try build_makedefs(b);
    try build_nethack(b);
    build_trihack(b);
}
