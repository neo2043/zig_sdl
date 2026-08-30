# ZIG_SDL

*Reference Repo* :- [castholm/SDL](https://github.com/castholm/SDL/)

This project demonstrates building SDL3 directly with the Zig build system and
using its C API from Zig. The SDL headers are passed through Zig's `translate-c`
step, so application code can import the generated API as `@import("sdl")`
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

## Build

```sh
zig build
zig build run
zig build test
```

The project requires Zig 0.16.0 or newer, as specified in `build.zig.zon`.
