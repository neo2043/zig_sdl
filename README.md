# ZIG_SDL

*Reference Repo* :- [castholm/SDL](https://github.com/castholm/SDL/)

This project demonstrates building SDL3 directly with the Zig build system and
using its C API from Zig. The SDL headers are passed through Zig's `translate-c`
step, so application code can import the generated API as `@import("sdl3_tc")`
instead of maintaining a separate hand-written binding.

SDL is compiled as part of this project rather than being loaded from a
pre-installed system installation. The exact SDL release is selected by the
archive URL in `build.zig.zon`; to compile a different release, change the
`.url` value to the corresponding SDL3 archive URL and update its package hash.
The version is also read from that URL and applied to the generated library
metadata.

Unlike the reference SDL package, this project does not use the separate
`sdl_linux_deps` Zig package. Native Linux builds still need the platform's
SDL system development libraries and tools, which the build discovers through
`pkg-config`.

The repository includes a small graphics smoke test in `src/sdl_demo.zig`. It
creates an 800x600 window, draws a colored rectangle, and exits when the window
is closed or Escape is pressed.

## Use as a Dependency

Add this package to another Zig project:

```sh
zig fetch --save git+https://github.com/neo2043/zig_sdl.git
```

The package exposes two separate build products:

- `sdl3_tc` is the translated C API module used with `@import("sdl3_tc")`.
- `sdl3_artifact` is the compiled library artifact.

Importing the module does not link the library. Add each product explicitly in
the consuming project's `build.zig`:

```zig
const sdl_dep = b.dependency("zig_sdl", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("sdl3_tc", sdl_dep.module("sdl3_tc"));
exe.root_module.linkLibrary(sdl_dep.artifact("sdl3_artifact"));
```

SDL declarations can then be imported from Zig source:

```zig
const sdl = @import("sdl3_tc");

pub fn main() void {
    _ = sdl.SDL_GetVersion();
}
```

## Build

```sh
zig build
zig build run
```

The project requires Zig 0.16.0 or newer, as specified in `build.zig.zon`.
