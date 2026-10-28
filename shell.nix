with import <nixpkgs> { };
let
  # 覆盖 Zig 命令，使用 zvm 运行 Zig
  custom-zig = writeShellScriptBin "zig" "exec zvm run 0.17.0 $@";
in
mkShell {
  packages = [
    custom-zig # 受 zvm 管理的 Zig
    pkg-config # 依赖库搜索
  ];

  buildInputs = [
    glib
    expat
    zlib
    libjpeg
    libpng
    libtiff
    libwebp
    libheif
    libjxl
    libhwy
    lcms2
    libexif
    libimagequant
    cgif
    libspng
    fftw
    libarchive
    cairo
    pango
    fontconfig
    imagemagick
  ];

  ZVM_SET_CU = 1; # 禁止 zvm 升级检查
}
