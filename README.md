# ZIG_SDL

This project builds SDL3 from the Zig package dependency and includes a small
graphics smoke test.

```text
zig build
zig build run
zig build test
```

`zig build run` opens an 800x600 window, draws a colored rectangle, and exits
when the window is closed or Escape is pressed.
