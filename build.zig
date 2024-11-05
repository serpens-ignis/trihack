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
    _ = try cwd.createFile("zig-out/nh/perm", .{});
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
    const flags = [_][]const u8{
        "-o", "-d", "-e", "-v", "-p",
        "-q", "-r", "-s", "-h", "-z",
    };
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

fn build_comp(
    b: *std.Build,
    src_files: []const []const u8,
    input_files: []const []const u8,
    comptime shortname: []const u8,
    comptime longname: []const u8,
) !void {
    const src_paths = [_][]const u8{};
    const include_paths = [_][]const u8{
        "nethack/include",
        "zig-out/include",
    };
    const libs = [_][]const u8{};

    const yacc_cmd = &[_][]const u8{
        "yacc",
        "-d",
        "nethack/util/" ++ shortname ++ "_comp.y",
        "--header=zig-out/include/" ++ shortname ++ "_comp.h",
        "-o",
        "zig-out/util/" ++ shortname ++ "_yacc.c",
    };
    const lex_cmd = &[_][]const u8{
        "lex",
        "-o",
        "zig-out/util/" ++ shortname ++ "_lex.c",
        "nethack/util/" ++ shortname ++ "_comp.l",
    };

    const yacc = b.addSystemCommand(yacc_cmd);
    const lex = b.addSystemCommand(lex_cmd);
    for (makedefs_cmds) |cmd| {
        yacc.step.dependOn(&cmd.step);
        lex.step.dependOn(&cmd.step);
    }

    const comp = try build_c(
        b,
        shortname ++ "_comp",
        src_files,
        &src_paths,
        &include_paths,
        &libs,
    );

    const install = b.getInstallStep();
    const comp_step = b.step(shortname ++ "_comp", "Run the " ++ longname ++ " compiler");
    comp.step.dependOn(&yacc.step);
    comp.step.dependOn(&lex.step);
    for (input_files) |file| {
        const cmd = b.addRunArtifact(comp);
        cmd.addArg(std.fs.path.basename(file));
        cmd.setCwd(b.path("zig-out/dat/"));
        comp_step.dependOn(&cmd.step);
        install.dependOn(&cmd.step);
    }
    install.dependOn(&comp.step);
}

fn build_lev_comp(b: *std.Build) !void {
    const src_files = [_][]const u8{
        "zig-out/util/lev_yacc.c",
        "zig-out/util/lev_lex.c",
        "nethack/util/lev_main.c",
        "nethack/util/panic.c",
        "nethack/src/alloc.c",
        "nethack/src/drawing.c",
        "nethack/src/decl.c",
        "nethack/src/monst.c",
        "nethack/src/objects.c",
    };
    const input_files = try find_all(b, "zig-out/dat/", ".des");
    try build_comp(b, &src_files, input_files, "lev", "level");
}

fn build_dgn_comp(b: *std.Build) !void {
    const src_files = [_][]const u8{
        "zig-out/util/dgn_yacc.c",
        "zig-out/util/dgn_lex.c",
        "nethack/util/dgn_main.c",
        "nethack/util/panic.c",
        "nethack/src/alloc.c",
    };
    const input_files = [_][]const u8{
        "dungeon.pdf",
    };
    try build_comp(b, &src_files, &input_files, "dgn", "dungeon");
}

fn build_dlb(b: *std.Build) !void {
    const src_files = [_][]const u8{
        "nethack/util/dlb_main.c",
        "nethack/util/panic.c",
        "nethack/src/alloc.c",
        "nethack/src/dlb.c",
    };
    const src_paths = [_][]const u8{};
    const include_paths = [_][]const u8{
        "nethack/include",
        "zig-out/include",
    };
    const nhdat_files = [_][]const u8{
        "cf",           "../nh/nhdat",  "help",         "hh",           "cmdhelp",
        "keyhelp",      "history",      "opthelp",      "wizhelp",      "dungeon",
        "tribute",      "bogusmon",     "data",         "engrave",      "epitaph",
        "oracles",      "options",      "quest.dat",    "rumors",       "air.lev",
        "Arc-fila.lev", "Arc-filb.lev", "Arc-goal.lev", "Arc-loca.lev", "Arc-strt.lev",
        "asmodeus.lev", "astral.lev",   "baalz.lev",    "Bar-fila.lev", "Bar-filb.lev",
        "Bar-goal.lev", "Bar-loca.lev", "Bar-strt.lev", "bigrm-1.lev",  "bigrm-2.lev",
        "bigrm-3.lev",  "bigrm-4.lev",  "bigrm-5.lev",  "bigrm-6.lev",  "bigrm-7.lev",
        "bigrm-8.lev",  "bigrm-9.lev",  "bigrm-10.lev", "castle.lev",   "Cav-fila.lev",
        "Cav-filb.lev", "Cav-goal.lev", "Cav-loca.lev", "Cav-strt.lev", "earth.lev",
        "fakewiz1.lev", "fakewiz2.lev", "fire.lev",     "Hea-fila.lev", "Hea-filb.lev",
        "Hea-goal.lev", "Hea-loca.lev", "Hea-strt.lev", "juiblex.lev",  "Kni-fila.lev",
        "Kni-filb.lev", "Kni-goal.lev", "Kni-loca.lev", "Kni-strt.lev", "knox.lev",
        "medusa-1.lev", "medusa-2.lev", "medusa-3.lev", "medusa-4.lev", "minefill.lev",
        "minend-1.lev", "minend-2.lev", "minend-3.lev", "minetn-1.lev", "minetn-2.lev",
        "minetn-3.lev", "minetn-4.lev", "minetn-5.lev", "minetn-6.lev", "minetn-7.lev",
        "Mon-fila.lev", "Mon-filb.lev", "Mon-goal.lev", "Mon-loca.lev", "Mon-strt.lev",
        "oracle.lev",   "orcus.lev",    "Pri-fila.lev", "Pri-filb.lev", "Pri-goal.lev",
        "Pri-loca.lev", "Pri-strt.lev", "Ran-fila.lev", "Ran-filb.lev", "Ran-goal.lev",
        "Ran-loca.lev", "Ran-strt.lev", "Rog-fila.lev", "Rog-filb.lev", "Rog-goal.lev",
        "Rog-loca.lev", "Rog-strt.lev", "Sam-fila.lev", "Sam-filb.lev", "Sam-goal.lev",
        "Sam-loca.lev", "Sam-strt.lev", "sanctum.lev",  "soko1-1.lev",  "soko1-2.lev",
        "soko2-1.lev",  "soko2-2.lev",  "soko3-1.lev",  "soko3-2.lev",  "soko4-1.lev",
        "soko4-2.lev",  "Tou-fila.lev", "Tou-filb.lev", "Tou-goal.lev", "Tou-loca.lev",
        "Tou-strt.lev", "tower1.lev",   "tower2.lev",   "tower3.lev",   "Val-fila.lev",
        "Val-filb.lev", "Val-goal.lev", "Val-loca.lev", "Val-strt.lev", "valley.lev",
        "water.lev",    "Wiz-fila.lev", "Wiz-filb.lev", "Wiz-goal.lev", "Wiz-loca.lev",
        "Wiz-strt.lev", "wizard1.lev",  "wizard2.lev",  "wizard3.lev",
    };
    const libs = [_][]const u8{};
    const dlb = try build_c(b, "dlb", &src_files, &src_paths, &include_paths, &libs);
    const dlb_step = b.step("dlb", "Run dlb archiver");
    const dlb_cmd = b.addRunArtifact(dlb);
    dlb_cmd.addArgs(&nhdat_files);
    dlb_cmd.setCwd(b.path("zig-out/dat"));
    dlb_step.dependOn(&dlb_cmd.step);
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
    try build_lev_comp(b);
    try build_dgn_comp(b);
    try build_dlb(b);
    try build_nethack(b);
    build_trihack(b);
}
