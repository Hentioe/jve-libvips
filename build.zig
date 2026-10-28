const std = @import("std");
const src = @import("zig/sources.zig");

const vips_version = "8.18.8";
const vips_major = 8;
const vips_minor = 18;
const vips_micro = 8;
const library_current = 62;
const library_revision = 8;
const library_age = 20;

/// A system dependency that is discovered through pkg-config.
///
/// Each entry maps to a `-D<name>=true|false` build option. When the option is
/// enabled the dependency is located with pkg-config and its include and link
/// flags are applied to the public `vips` module, so consumers linking the
/// artifact inherit them.
const Dep = struct {
    /// Build option name.
    option: []const u8,
    /// pkg-config module names.
    pc: []const []const u8,
    /// Config.h macro to define when found.
    macro: ?[]const u8 = null,
    default: bool = true,
};

const deps = [_]Dep{
    .{ .option = "glib", .pc = &.{ "glib-2.0", "gio-2.0", "gobject-2.0", "gmodule-no-export-2.0" } },
    .{ .option = "expat", .pc = &.{"expat"} },
    .{ .option = "zlib", .pc = &.{"zlib"}, .macro = "HAVE_ZLIB" },
    .{ .option = "jpeg", .pc = &.{"libjpeg"}, .macro = "HAVE_JPEG" },
    .{ .option = "png", .pc = &.{"libpng"}, .macro = "HAVE_PNG" },
    .{ .option = "spng", .pc = &.{"spng"}, .macro = "HAVE_SPNG" },
    .{ .option = "webp", .pc = &.{ "libwebp", "libwebpmux", "libwebpdemux" }, .macro = "HAVE_LIBWEBP" },
    .{ .option = "tiff", .pc = &.{"libtiff-4"}, .macro = "HAVE_TIFF" },
    .{ .option = "heif", .pc = &.{"libheif"}, .macro = "HAVE_HEIF" },
    .{ .option = "jxl", .pc = &.{ "libjxl", "libjxl_threads" }, .macro = "HAVE_LIBJXL" },
    .{ .option = "lcms", .pc = &.{"lcms2"}, .macro = "HAVE_LCMS2" },
    .{ .option = "exif", .pc = &.{"libexif"}, .macro = "HAVE_EXIF" },
    .{ .option = "imagequant", .pc = &.{"imagequant"}, .macro = "HAVE_IMAGEQUANT" },
    .{ .option = "cgif", .pc = &.{"cgif"}, .macro = "HAVE_CGIF" },
    .{ .option = "fftw", .pc = &.{"fftw3"}, .macro = "HAVE_FFTW", .default = false },
    .{ .option = "archive", .pc = &.{"libarchive"}, .macro = "HAVE_LIBARCHIVE", .default = false },
    .{ .option = "pangocairo", .pc = &.{"pangocairo"}, .macro = "HAVE_PANGOCAIRO" },
    .{ .option = "magick", .pc = &.{"MagickWand"} },
    .{ .option = "fontconfig", .pc = &.{ "pangoft2", "fontconfig" }, .macro = "HAVE_FONTCONFIG" },
};

const PcInfo = struct {
    includes: []const []const u8,
    libdirs: []const []const u8,
    libs: []const []const u8,
    cflags: []const []const u8,
    version: []const u8,
};

fn pcRun(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = argv,
        .stderr_limit = .limited(4096),
    }) catch return null;
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return std.mem.trim(u8, result.stdout, " \t\r\n");
}

fn queryPc(b: *std.Build, names: []const []const u8) ?PcInfo {
    var argv = std.ArrayList([]const u8).empty;
    argv.append(b.allocator, "pkg-config") catch return null;
    argv.append(b.allocator, "--cflags") catch return null;
    argv.append(b.allocator, "--libs") catch return null;
    argv.appendSlice(b.allocator, names) catch return null;

    const out = pcRun(b, argv.items) orelse return null;

    var includes = std.ArrayList([]const u8).empty;
    var libdirs = std.ArrayList([]const u8).empty;
    var libs = std.ArrayList([]const u8).empty;
    var cflags = std.ArrayList([]const u8).empty;

    var it = std.mem.tokenizeAny(u8, out, " \t\r\n");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) {
            includes.append(b.allocator, tok[2..]) catch return null;
        } else if (std.mem.startsWith(u8, tok, "-L")) {
            libdirs.append(b.allocator, tok[2..]) catch return null;
        } else if (std.mem.startsWith(u8, tok, "-l")) {
            libs.append(b.allocator, tok[2..]) catch return null;
        } else if (std.mem.startsWith(u8, tok, "-D")) {
            cflags.append(b.allocator, tok) catch return null;
        } else if (std.mem.eql(u8, tok, "-pthread")) {
            // pthread is part of libc on every supported target here.
        } else {
            cflags.append(b.allocator, tok) catch return null;
        }
    }

    var vargv = std.ArrayList([]const u8).empty;
    vargv.append(b.allocator, "pkg-config") catch return null;
    vargv.append(b.allocator, "--modversion") catch return null;
    vargv.append(b.allocator, names[0]) catch return null;
    const version = pcRun(b, vargv.items) orelse return null;

    return .{
        .includes = includes.items,
        .libdirs = libdirs.items,
        .libs = libs.items,
        .cflags = cflags.items,
        .version = version,
    };
}

fn versionAtLeast(version: []const u8, minimum: []const u8) bool {
    var v_it = std.mem.splitScalar(u8, version, '.');
    var m_it = std.mem.splitScalar(u8, minimum, '.');
    while (m_it.next()) |m_part| {
        const v_part = v_it.next() orelse return false;
        const v_num = std.fmt.parseInt(u32, v_part, 10) catch 0;
        const m_num = std.fmt.parseInt(u32, m_part, 10) catch 0;
        if (v_num != m_num) return v_num > m_num;
    }
    return true;
}

fn addSourceGroup(
    mod: *std.Build.Module,
    files: []const []const u8,
    cflags: []const []const u8,
    cxxflags: []const []const u8,
) void {
    var c_files = std.ArrayList([]const u8).empty;
    var cxx_files = std.ArrayList([]const u8).empty;
    for (files) |f| {
        if (std.mem.endsWith(u8, f, ".cpp") or std.mem.endsWith(u8, f, ".cc")) {
            cxx_files.append(mod.owner.allocator, f) catch @panic("OOM");
        } else {
            c_files.append(mod.owner.allocator, f) catch @panic("OOM");
        }
    }
    if (c_files.items.len > 0) {
        mod.addCSourceFiles(.{ .files = c_files.items, .flags = cflags });
    }
    if (cxx_files.items.len > 0) {
        mod.addCSourceFiles(.{ .files = cxx_files.items, .flags = cxxflags });
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const shared = b.option(bool, "shared", "Build libvips as a shared library") orelse false;
    const deprecated = b.option(bool, "deprecated", "Build the deprecated (vips7) API") orelse false;

    // Private module used to compile the C/C++ sources into the library.
    const lib_mod = b.createModule(.{
        .root_source_file = null,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .sanitize_c = .off,
    });

    lib_mod.addIncludePath(b.path("libvips/include"));
    lib_mod.addIncludePath(b.path("libvips/foreign"));
    lib_mod.addIncludePath(b.path("zig"));
    lib_mod.addIncludePath(b.path("libvips/include/vips"));

    // Discover system dependencies and record which ones are available.
    var found = std.StringHashMap(PcInfo).init(b.allocator);

    // System flags are collected here and later applied both to the private
    // library module and to the public `vips` module, so that consumers inherit
    // them just by importing the module.
    var sys_includes = std.ArrayList([]const u8).empty;
    var sys_libdirs = std.ArrayList([]const u8).empty;
    var sys_libs = std.ArrayList([]const u8).empty;

    for (deps) |dep| {
        const enabled = b.option(bool, dep.option, b.fmt("Enable {s} support (pkg-config name: {s})", .{ dep.option, dep.pc[0] })) orelse dep.default;
        if (!enabled) continue;
        // libspng is only a fallback for when libpng is unavailable; compiling both
        // would define the same VipsForeignLoadPng types twice.
        if (std.mem.eql(u8, dep.option, "spng") and found.get("png") != null) continue;
        const info = queryPc(b, dep.pc) orelse {
            if (dep.default) {
                std.debug.print("warning: pkg-config could not find '{s}', disabling {s} support\n", .{ dep.pc[0], dep.option });
            }
            continue;
        };
        for (info.includes) |inc| {
            sys_includes.append(b.allocator, inc) catch @panic("OOM");
            lib_mod.addIncludePath(.{ .cwd_relative = inc });
        }
        for (info.libdirs) |dir| {
            sys_libdirs.append(b.allocator, dir) catch @panic("OOM");
            lib_mod.addLibraryPath(.{ .cwd_relative = dir });
        }
        for (info.libs) |lib| {
            sys_libs.append(b.allocator, lib) catch @panic("OOM");
            lib_mod.linkSystemLibrary(lib, .{});
        }
        for (info.cflags) |flag| {
            if (std.mem.startsWith(u8, flag, "-D")) {
                const body = flag[2..];
                if (std.mem.indexOfScalar(u8, body, '=')) |eq| {
                    lib_mod.addCMacro(body[0..eq], body[eq + 1 ..]);
                } else {
                    lib_mod.addCMacro(body, "1");
                }
            }
        }
        found.put(dep.option, info) catch @panic("OOM");
    }

    if (found.get("glib") == null) {
        std.debug.print("error: glib-2.0 is required to build libvips\n", .{});
        return;
    }
    // expat is used unconditionally by iofuncs/vips.c (XML parsing), so a
    // missing expat would produce a static library with unresolved XML_*
    // symbols. Fail here instead of silently building a broken artifact.
    if (found.get("expat") == null) {
        std.debug.print("error: expat is required to build libvips (pkg-config 'expat')\n", .{});
        return;
    }

    // ---------------------------------------------------------------- config.h
    var cfg = std.ArrayList(u8).empty;
    cfg.appendSlice(b.allocator,
        \\/* Generated by build.zig -- do not edit. */
        \\#ifndef VIPS_CONFIG_H
        \\#define VIPS_CONFIG_H
        \\
    ) catch @panic("OOM");

    const addDef = struct {
        fn f(list: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8, value: anytype) void {
            list.print(gpa, "#define {s} {any}\n", .{ name, value }) catch @panic("OOM");
        }
    }.f;
    const addStr = struct {
        fn f(list: *std.ArrayList(u8), gpa: std.mem.Allocator, name: []const u8, value: []const u8) void {
            list.print(gpa, "#define {s} \"{s}\"\n", .{ name, value }) catch @panic("OOM");
        }
    }.f;

    addStr(&cfg, b.allocator, "G_LOG_DOMAIN", "VIPS");
    if (deprecated) addDef(&cfg, b.allocator, "ENABLE_DEPRECATED", 1);
    addDef(&cfg, b.allocator, "HAVE_CONFIG_H", 1);

    // Platform / libc features.
    addDef(&cfg, b.allocator, "HAVE_VECTOR_ARITH", 1);
    addDef(&cfg, b.allocator, "HAVE_POSIX_MEMALIGN", 1);
    addDef(&cfg, b.allocator, "HAVE_MEMALIGN", 1);
    addDef(&cfg, b.allocator, "HAVE_PTHREAD_DEFAULT_NP", 1);
    addDef(&cfg, b.allocator, "HAVE_UNISTD_H", 1);
    addDef(&cfg, b.allocator, "HAVE_SYS_FILE_H", 1);
    addDef(&cfg, b.allocator, "HAVE_SYS_PARAM_H", 1);
    addDef(&cfg, b.allocator, "HAVE_SYS_MMAN_H", 1);

    // Always-on in-tree loaders.
    addDef(&cfg, b.allocator, "HAVE_NSGIF", 1);
    addDef(&cfg, b.allocator, "HAVE_RADIANCE", 1);
    addDef(&cfg, b.allocator, "HAVE_PPM", 0);
    addDef(&cfg, b.allocator, "HAVE_ANALYZE", 0);

    // i18n is deliberately disabled: libvips works fine untranslated and this
    // avoids a hard dependency on gettext/libintl.
    addStr(&cfg, b.allocator, "GETTEXT_PACKAGE", "vips8.18");
    addStr(&cfg, b.allocator, "VIPS_PREFIX", "/usr");
    addStr(&cfg, b.allocator, "VIPS_LIBDIR", "/usr/lib");
    addStr(&cfg, b.allocator, "VIPS_ICC_DIR", "/usr/share/color/icc");

    for (deps) |dep| {
        const info = found.get(dep.option) orelse continue;
        if (dep.macro) |macro| addDef(&cfg, b.allocator, macro, 1);
        const v = info.version;

        if (std.mem.eql(u8, dep.option, "png")) {
            addDef(&cfg, b.allocator, "HAVE_PNG_SET_CHUNK_MALLOC_MAX", 1);
        } else if (std.mem.eql(u8, dep.option, "tiff")) {
            addDef(&cfg, b.allocator, "HAVE_TIFF_COMPRESSION_WEBP", 1);
            addDef(&cfg, b.allocator, "HAVE_TIFF_OPEN_OPTIONS", 1);
            addDef(&cfg, b.allocator, "HAVE_TIFF_OPEN_OPTIONS_SET_MAX_CUMULATED_MEM_ALLOC", 1);
        } else if (std.mem.eql(u8, dep.option, "heif")) {
            addDef(&cfg, b.allocator, "HAVE_HEIF_ENCODER_PARAMETER_GET_VALID_INTEGER_VALUES", 1);
            addDef(&cfg, b.allocator, "HAVE_HEIF_ENCODING_OPTIONS_OUTPUT_NCLX_PROFILE", 1);
            addDef(&cfg, b.allocator, "HAVE_HEIF_ENCODING_OPTIONS_IMAGE_ORIENTATION", 1);
            if (versionAtLeast(v, "1.13.0")) addDef(&cfg, b.allocator, "HAVE_HEIF_INIT", @intFromBool(versionAtLeast(v, "1.13.0")));
            if (versionAtLeast(v, "1.17.0")) addDef(&cfg, b.allocator, "HAVE_HEIF_ERROR_SUCCESS", @intFromBool(versionAtLeast(v, "1.17.0")));
            if (versionAtLeast(v, "1.19.0")) addDef(&cfg, b.allocator, "HAVE_HEIF_GET_DISABLED_SECURITY_LIMITS", @intFromBool(versionAtLeast(v, "1.19.0")));
            if (versionAtLeast(v, "1.19.0")) addDef(&cfg, b.allocator, "HAVE_HEIF_MAX_TOTAL_MEMORY", @intFromBool(versionAtLeast(v, "1.19.0")));
        } else if (std.mem.eql(u8, dep.option, "jxl")) {
            if (versionAtLeast(v, "0.8.0")) addDef(&cfg, b.allocator, "HAVE_LIBJXL_0_8", @intFromBool(versionAtLeast(v, "0.8.0")));
            if (versionAtLeast(v, "0.9.0")) addDef(&cfg, b.allocator, "HAVE_LIBJXL_0_9", @intFromBool(versionAtLeast(v, "0.9.0")));
        } else if (std.mem.eql(u8, dep.option, "cgif")) {
            addDef(&cfg, b.allocator, "HAVE_CGIF_ATTR_NO_LOOP", 1);
            addDef(&cfg, b.allocator, "HAVE_CGIF_FRAME_ATTR_INTERLACED", 1);
            addDef(&cfg, b.allocator, "HAVE_CGIF_GEN_KEEP_IDENT_FRAMES", 1);
        } else if (std.mem.eql(u8, dep.option, "exif")) {
            if (versionAtLeast(v, "0.6.22")) addDef(&cfg, b.allocator, "HAVE_EXIF_0_6_22", @intFromBool(versionAtLeast(v, "0.6.22")));
            if (versionAtLeast(v, "0.6.23")) addDef(&cfg, b.allocator, "HAVE_EXIF_0_6_23", @intFromBool(versionAtLeast(v, "0.6.23")));
        }
    }

    if (found.get("magick") != null) {
        addDef(&cfg, b.allocator, "HAVE_MAGICK7", 1);
        addDef(&cfg, b.allocator, "ENABLE_MAGICKLOAD", 1);
        addDef(&cfg, b.allocator, "ENABLE_MAGICKSAVE", 1);
        addDef(&cfg, b.allocator, "HAVE_ACQUIREIMAGE", 1);
        addDef(&cfg, b.allocator, "HAVE_ACQUIREEXCEPTIONINFO", 1);
        addDef(&cfg, b.allocator, "HAVE_GETMAGICINFO", 1);
        addDef(&cfg, b.allocator, "HAVE_GETVIRTUALPIXELS", 1);
        addDef(&cfg, b.allocator, "HAVE_INHERITEXCEPTION", 1);
        addDef(&cfg, b.allocator, "HAVE_RESETIMAGEATTRIBUTEITERATOR", 1);
        addDef(&cfg, b.allocator, "HAVE_RESETIMAGEPROFILEITERATOR", 1);
        addDef(&cfg, b.allocator, "HAVE_RESETIMAGEPROPERTYITERATOR", 1);
        addDef(&cfg, b.allocator, "HAVE_SETIMAGEEXTENT", 1);
        addDef(&cfg, b.allocator, "HAVE_SETIMAGEOPTION", 1);
        addDef(&cfg, b.allocator, "HAVE_SETIMAGEPROPERTY", 1);
        addDef(&cfg, b.allocator, "HAVE_OPTIMIZEIMAGETRANSPARENCY", 1);
        addDef(&cfg, b.allocator, "HAVE_OPTIMIZEPLUSIMAGELAYERS", 1);
        addDef(&cfg, b.allocator, "HAVE_BLOBTOSTRINGINFO", 1);
        addDef(&cfg, b.allocator, "HAVE_IMAGESTOBLOB", 1);
        addDef(&cfg, b.allocator, "HAVE_IMPORTIMAGEPIXELS", 1);
        addDef(&cfg, b.allocator, "HAVE_NUMBER_SCENES", 1);
        addDef(&cfg, b.allocator, "HAVE_CMYCOLORSPACE", 1);
        addDef(&cfg, b.allocator, "HAVE_HCLPCOLORSPACE", 1);
        addDef(&cfg, b.allocator, "HAVE_GETIMAGEMAGICK3", 1);
    }

    cfg.appendSlice(b.allocator, "#endif /*VIPS_CONFIG_H*/\n") catch @panic("OOM");

    const generated = b.addWriteFiles();
    const config_h = generated.add("config.h", cfg.items);

    // ------------------------------------------------------------- version.h
    var vh = std.ArrayList(u8).empty;
    vh.print(b.allocator,
        \\/* Generated by build.zig -- do not edit. */
        \\#ifndef VIPS_VERSION_H
        \\#define VIPS_VERSION_H
        \\#define VIPS_VERSION "{s}"
        \\#define VIPS_VERSION_STRING "{s}"
        \\#define VIPS_MAJOR_VERSION ({d})
        \\#define VIPS_MINOR_VERSION ({d})
        \\#define VIPS_MICRO_VERSION ({d})
        \\#define VIPS_LIBRARY_CURRENT ({d})
        \\#define VIPS_LIBRARY_REVISION ({d})
        \\#define VIPS_LIBRARY_AGE ({d})
        \\#define VIPS_CONFIG "{s}"
        \\#define VIPS_ENABLE_DEPRECATED {d}
        \\#endif /*VIPS_VERSION_H*/
        \\
    , .{ vips_version, vips_version, vips_major, vips_minor, vips_micro, library_current, library_revision, library_age, vips_version, @intFromBool(deprecated) }) catch @panic("OOM");
    _ = generated.add("vips/version.h", vh.items);
    _ = generated.add("vips/enumtypes.h", @embedFile("zig/vips-enumtypes.h"));

    lib_mod.addIncludePath(config_h.dirname());
    lib_mod.addIncludePath(generated.getDirectory());

    // Public module: the translated C API plus every include path and link flag,
    // so a single `addImport("vips", ...)` is enough for consumers. There is no
    // separate "flags-only" module anymore.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("zig/vips-c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.path("libvips/include"));
    translate.addIncludePath(b.path("libvips/include/vips"));
    translate.addIncludePath(config_h.dirname());
    translate.addIncludePath(generated.getDirectory());
    var dep_it = found.valueIterator();
    while (dep_it.next()) |info| {
        for (info.includes) |inc| translate.addIncludePath(.{ .cwd_relative = inc });
    }

    const mod = b.addModule("vips", .{
        .root_source_file = translate.getOutput(),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .sanitize_c = .off,
    });
    mod.addIncludePath(b.path("libvips/include"));
    mod.addIncludePath(b.path("libvips/foreign"));
    mod.addIncludePath(b.path("zig"));
    mod.addIncludePath(b.path("libvips/include/vips"));
    mod.addIncludePath(config_h.dirname());
    mod.addIncludePath(generated.getDirectory());
    for (sys_includes.items) |inc| mod.addIncludePath(.{ .cwd_relative = inc });
    for (sys_libdirs.items) |dir| mod.addLibraryPath(.{ .cwd_relative = dir });
    for (sys_libs.items) |lib| mod.linkSystemLibrary(lib, .{});

    // ---------------------------------------------------------------- sources
    var cflag_list = std.ArrayList([]const u8).empty;
    cflag_list.appendSlice(b.allocator, &.{
        "-std=gnu99",
        "-DHAVE_CONFIG_H",
    }) catch @panic("OOM");
    var cxxflag_list = std.ArrayList([]const u8).empty;
    cxxflag_list.appendSlice(b.allocator, &.{
        "-std=c++14",
        "-DHAVE_CONFIG_H",
        "-fexceptions",
    }) catch @panic("OOM");

    // Escape hatch for dependencies that are not discoverable through
    // pkg-config: `-Dextra-cflags="-I/opt/foo/include"` and
    // `-Dextra-libs="-L/opt/foo/lib -lfoo"`.
    if (b.option([]const u8, "extra-cflags", "Extra compiler flags (space separated) for the libvips sources")) |extra| {
        var it = std.mem.tokenizeAny(u8, extra, " \t");
        while (it.next()) |tok| {
            cflag_list.append(b.allocator, tok) catch @panic("OOM");
            cxxflag_list.append(b.allocator, tok) catch @panic("OOM");
            if (std.mem.startsWith(u8, tok, "-I") and tok.len > 2) {
                lib_mod.addIncludePath(.{ .cwd_relative = tok[2..] });
                mod.addIncludePath(.{ .cwd_relative = tok[2..] });
            }
        }
    }
    if (b.option([]const u8, "extra-libs", "Extra linker flags (space separated) for consumers of libvips")) |extra| {
        var it = std.mem.tokenizeAny(u8, extra, " \t");
        while (it.next()) |tok| {
            if (std.mem.startsWith(u8, tok, "-L") and tok.len > 2) {
                lib_mod.addLibraryPath(.{ .cwd_relative = tok[2..] });
                mod.addLibraryPath(.{ .cwd_relative = tok[2..] });
            } else if (std.mem.startsWith(u8, tok, "-l") and tok.len > 2) {
                lib_mod.linkSystemLibrary(tok[2..], .{});
                mod.linkSystemLibrary(tok[2..], .{});
            } else {
                lib_mod.linkSystemLibrary(tok, .{});
                mod.linkSystemLibrary(tok, .{});
            }
        }
    }

    const cflags = cflag_list.items;
    const cxxflags = cxxflag_list.items;

    addSourceGroup(lib_mod, &src.arithmetic, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.resample, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.colour, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.conversion, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.convolution, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.freqfilt, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.histogram, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.draw, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.iofuncs, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.morphology, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.mosaicing, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.create, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.foreign, cflags, cxxflags);
    addSourceGroup(lib_mod, &src.nsgif, cflags, cxxflags);
    if (deprecated) addSourceGroup(lib_mod, &src.deprecated, cflags, cxxflags);
    if (found.get("magick") != null) addSourceGroup(lib_mod, &src.magick, cflags, cxxflags);

    addSourceGroup(lib_mod, &.{
        "zig/vips-enumtypes.c",
        "zig/vipsmarshal.c",
    }, cflags, cxxflags);

    const lib = b.addLibrary(.{
        .name = "vips",
        .root_module = lib_mod,
        .linkage = if (shared) .dynamic else .static,
        .version = .{ .major = library_current - library_age, .minor = library_age, .patch = library_revision },
    });
    b.installArtifact(lib);

    b.installDirectory(.{
        .source_dir = b.path("libvips/include/vips"),
        .install_dir = .header,
        .install_subdir = "vips",
        .include_extensions = &.{".h"},
    });
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(generated.getDirectory().path(b, "vips/version.h"), .header, "vips/version.h").step);
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(generated.getDirectory().path(b, "vips/enumtypes.h"), .header, "vips/enumtypes.h").step);

    // Link check: verifies that the static library can be linked against its
    // system dependencies (expat, glib, ...) without setting up a downstream
    // project. Run with `zig build check`.
    const check_step = b.step("check", "Link-check libvips against its system dependencies");
    const check_files = b.addWriteFiles();
    const check_zig = check_files.add("check.zig",
        \\const c = @import("vips");
        \\
        \\pub fn main() !void {
        \\    if (c.vips_init("vips-check") != 0) return error.VipsInit;
        \\    defer c.vips_shutdown();
        \\}
        \\
    );
    const check_mod = b.createModule(.{
        .root_source_file = check_zig,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .sanitize_c = .off,
    });
    check_mod.addImport("vips", mod);
    check_mod.linkLibrary(lib);
    const check_exe = b.addExecutable(.{ .name = "vips-check", .root_module = check_mod });
    check_step.dependOn(&check_exe.step);
}
