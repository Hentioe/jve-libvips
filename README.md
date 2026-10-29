# libvips（Zig 构建 / Zig 依赖）

本项目把 [libvips/libvips](https://github.com/libvips/libvips) 打包成一个可由其它
Zig 项目直接依赖的构建过程与编译产物。

**目的**：让其它 Zig 项目把 libvips 当作一个普通的 Zig 依赖引入（通过 `build.zig.zon`），
**无需把 libvips 源码复制进自己的工程**。本依赖负责：

- 把 libvips 编译成静态库（默认 `libvips.a`，可选 `libvips.so`）；
- 提供 libvips 的公共头文件目录（含生成好的 `version.h`、`enumtypes.h`）；
- 通过 `pkg-config` 发现并链接系统依赖，并把它们的 include / link 参数传递给集成方；
- 提供 `vips` 模块：`translate-c` 生成的 C API 绑定，同时携带全部 include / link 参数。

> [!WARNING]
> **注意**：本项目主要是给 [Hentioe/jve](https://github.com/Hentioe/jve) 提供支持，除此之外的作用都不会成为首要目的。

## 外部集成

本依赖不提供额外的 Zig 封装 API：唯一的公开模块 `vips` 是 libvips C API 的机械
翻译（`translate-c`），语义与 C 版完全一致；它同时携带所有头文件路径与链接参数，
因此集成方只需 import 这一个模块。

### 1. 在 `build.zig.zon` 添加依赖

```sh
zig fetch --save git+https://github.com/Hentioe/jve-libvips
```

### 2. 在 `build.zig` 中接入

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const vips_dep = b.dependency("libvips", .{
        .target = target,
        .optimize = optimize,
        // 可选：关闭不需要的依赖，例如：
        // .heif = false,
        // .jxl = false,
        // .magick = false,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // 关键：`vips` 模块同时提供 C API 绑定、include 路径和系统库链接参数。
    exe_mod.addImport("vips", vips_dep.module("vips"));
    // 链接 libvips 库本身。
    exe_mod.linkLibrary(vips_dep.artifact("vips"));

    const exe = b.addExecutable(.{ .name = "my_project", .root_module = exe_mod });
    b.installArtifact(exe);
}
```

### 3. 调用 libvips

使用 `vips` 模块：

```zig
const c = @import("vips");

pub fn main() !void {
    if (c.vips_init("my_project") != 0)
        return error.VipsInit;
    defer c.vips_shutdown();

    var image: ?*c.VipsImage = null;
    if (c.vips_black(&image, 64, 64, @as(?*anyopaque, null)) != 0)
        return error.VipsBlack;
    defer _ = c.g_object_unref(@ptrCast(image.?));
}
```

如果不想用自动生成的绑定，也可以在 `build.zig` 里自行 `b.addTranslateC` 一个聚合头
（`#include <vips/vips.h>`），或直接声明 `extern` 函数；注意自行 `addTranslateC`
时需要把依赖的 include 路径也加上（这些路径同样可以通过 `vips` 模块获得）。

### 4. 非 Zig 构建系统

先在本仓库构建，再使用安装产物：

```sh
nix-shell --run 'zig build'
```

- 库：`zig-out/lib/libvips.a`
- 头文件：`zig-out/include/vips/`（已包含生成的 `version.h`、`enumtypes.h`）

静态链接时还需要系统依赖库，可用 `pkg-config` 获取，例如：

```sh
pkg-config --cflags --libs glib-2.0 gio-2.0 gobject-2.0 gmodule-no-export-2.0 \
    expat zlib libjpeg libpng libwebp libwebpmux libwebpdemux libtiff-4 \
    libheif libjxl libjxl_threads lcms2 libexif imagequant cgif \
    pangocairo pangoft2 fontconfig MagickWand
```

## 构建本仓库

```sh
nix-shell --run 'zig build'
```

`shell.nix` 提供了 Zig 与全部系统依赖；不进入 `nix-shell` 时，需要自行保证
`pkg-config` 能找到这些库。

构建完成后可以运行链接自检，确认静态库的系统依赖完整（尤其是 expat）：

```sh
nix-shell --run 'zig build check'
```

### 选项

| 选项 | 默认值 | 说明 |
| --- | --- | --- |
| `-Dshared` | `false` | 构建动态库 `libvips.so`（带 soname 版本号） |
| `-Ddeprecated` | `false` | 编译 vips7 兼容 API |
| `-Dmagick` | 自动 | ImageMagick 支持（`.bmp` 等格式依赖它） |
| `-D<依赖名>` | `true` | 各系统依赖开关，见下（`fftw`、`archive` 默认 `false`） |
| `-Dextra-cflags` | 空 | 追加编译参数，如 `-I/opt/foo/include` |
| `-Dextra-libs` | 空 | 追加链接参数，如 `-L/opt/foo/lib -lfoo` |

可用依赖开关：`glib`、`expat`、`zlib`、`jpeg`、`png`、`spng`、`webp`、`tiff`、
`heif`、`jxl`、`lcms`、`exif`、`imagequant`、`cgif`、`fftw`、`archive`、
`pangocairo`、`fontconfig`、`magick`。

`glib` 与 `expat` 是必需项（缺失会直接配置失败，避免产出带未定义符号的静态库），
其余依赖缺失时会自动关闭并给出警告。`spng` 仅在 `libpng` 不存在时启用（避免与
`png` 加载器重复定义类型）。

### 动态库

默认构建静态库。需要动态库时：

```sh
nix-shell --run 'zig build -Dshared'
```

产物为 `zig-out/lib/libvips.so`，以及带 soname 的 `libvips.so.42`、
`libvips.so.42.20.8`；头文件安装位置不变。

集成方在 `b.dependency` 中传 `.shared = true` 即可使用动态库：

```zig
const vips_dep = b.dependency("libvips", .{
    .target = target,
    .optimize = optimize,
    .shared = true,
});

// 把依赖构建出的 libvips.so（含 soname 符号链接）安装到本项目的 zig-out/lib
b.installArtifact(vips_dep.artifact("vips"));

// 可选：让可执行文件从 zig-out/lib 加载
exe.root_module.addRPathSpecial("$ORIGIN/../lib");
```

动态库由本依赖完整构建（包含全部操作与格式支持），集成侧只负责安装和链接，不需要
像 slang 那样在集成侧再用 `b.addLibrary` 重建一遍。自己用 `addLibrary` 把静态
`libvips.a` 包成 `.so` 也可以，但链接器只会拉入被引用到的对象，容易漏掉格式 loader；
需要完整的 libvips 动态库时应直接使用 `-Dshared`。

若确实要在集成侧创建自己的共享库（例如包一层 shim），需要注意纯 C 根模块要提供一个
最小的 Zig 根文件，否则被 import 的翻译模块会因缺少 `@import("root")` 而编译失败。

Zig 会自动把依赖产物的目录写进可执行文件的 rpath，开发时可以直接运行。发布时需要
把 `libvips.so*` 一并安装到运行环境，或自行设置 `rpath` / `LD_LIBRARY_PATH`。

## 格式与提供库

必要格式：

| 格式 | 提供者 | 构建选项 / 宏 |
| --- | --- | --- |
| `.hdr` | libvips 自带 Radiance 读写 | 始终开启（`HAVE_RADIANCE`） |
| `.gif` 读取 | 仓库内置 libnsgif | 始终开启（`HAVE_NSGIF`） |
| `.gif` 写入 | cgif + libimagequant | `cgif`、`imagequant` |
| `.png` | libpng；没有 libpng 时回退 libspng | `png`（`spng` 仅回退） |
| `.jpg` `.jpeg` `.jpe` `.jfif` | libjpeg（libjpeg-turbo） | `jpeg` |
| `.webp` | libwebp + libwebpmux + libwebpdemux | `webp` |
| `.tif` `.tiff` | libtiff | `tiff` |
| `.jxl` | libjxl + libjxl_threads | `jxl` |
| `.heic` `.heif` `.avif` | libheif | `heif` |
| `.bmp` | ImageMagick（libvips 没有原生 BMP 读写） | `magick` |

过时格式：

| 格式 | 提供者 | 构建选项 / 宏 |
| --- | --- | --- |
| `.pbm` `.pgm` `.ppm` `.pfm` `.pnm` | **libvips 自带**（`ppmload.c`/`ppmsave.c`），不需要外部库 | `ppm`（`HAVE_PPM`），默认关闭 |
| `.j2k` `.jpt` `.j2c` `.jpc` `.jp2` | OpenJPEG（pkg-config `libopenjp2`） | `openjpeg`（`HAVE_LIBOPENJP2`），未接入 |

注意：ImageMagick（`magick`，默认自动开启，用于 `.bmp`）也可能通过它自己的
delegate 重新提供上述过时格式。要完全排除这些格式需要关闭 `magick`，但那样会同时
失去 `.bmp`。

## 说明与注意事项

- **依赖由集成方提供，构建由本依赖完成**。libvips 自身及所有 C/C++ 源码都由 Zig
  自带的 C/C++ 工具链编译，不要求安装 CMake、g++ 或 clang；但配置阶段需要
  `pkg-config` 以及对应的系统库（含开发头文件）。
- **不做交叉编译的依赖探测**。`pkg-config` 查的是构建主机上的库；目标平台与主机
  不一致时，请自行通过 `-Dextra-cflags` / `-Dextra-libs` 或系统环境配置。
- **生成文件已预先提交**。`zig/` 下的 `vips-enumtypes.c/.h`、`vipsmarshal.c/.h`
  是用 GLib 的 `glib-mkenums` / `glib-genmarshal` 从本仓库自己的头文件生成的，
  不是外部代码；预生成是为了让构建不依赖这两个工具。`config.h` 与
  `vips/version.h` 仍由 `build.zig` 在配置阶段生成。
- **模块既是 API 绑定也是链接入口**。`vips` 模块的 root source 是 translate-c 生成的
  C API；`addImport("vips", ...)` 同时继承全部 include 路径与系统库链接参数，
  `linkLibrary(artifact("vips"))` 负责库本身。
- **静态库需要链接 C++ 运行时**。libvips 含少量 C++ 源码，`vips` 模块已设置
  `link_libcpp = true`，集成方无需额外处理。
- **首次构建需要从头编译整个 libvips**，耗时取决于机器与启用的格式数量；之后
  Zig 会复用缓存。
- **i18n 默认关闭**，避免额外的 gettext / libintl 依赖；这不影响图像处理功能。
