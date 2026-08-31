const std = @import("std");
const uri = std.Uri.parse(@import("build.zig.zon").dependencies.sdl3.url) catch unreachable;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl_dep = b.lazyDependency("sdl3", .{}) orelse @panic("null sdl3 lazy dependency");
    const sdl_include = sdl_dep.path("include");
    const sdl_source = sdl_dep.path("src");

    const preferred_linkage = b.option(std.builtin.LinkMode, "preferred_linkage", "SDL linkage") orelse .static;
    const strip = b.option(
        bool,
        "strip",
        "Strip debug symbols (default: varies)",
    );
    const sanitize_c = b.option(
        std.zig.SanitizeC,
        "sanitize_c",
        "Detect C undefined behavior (default: varies)",
    );
    const pic = b.option(
        bool,
        "pic",
        "Produce position-independent code (default: varies)",
    );
    const lto = b.option(
        std.zig.LtoMode,
        "lto",
        "Perform link time optimization (default: varies)",
    );
    const emscripten_pthreads = b.option(
        bool,
        "emscripten_pthreads",
        "Build with pthreads support when targeting Emscripten (default: false)",
    ) orelse false;
    var system_include_path = b.option(
        std.Build.LazyPath,
        "system_include_path",
        "System header search path for cross-compiling",
    );
    var system_framework_path = b.option(
        std.Build.LazyPath,
        "system_framework_path",
        "System framework search path for cross-compiling",
    );
    var library_path = b.option(
        std.Build.LazyPath,
        "library_path",
        "Library search path for cross-compiling",
    );
    const build_config_h_overrides = b.option(
        []const []const u8,
        "build_config_h_overrides",
        "Override 'SDL_build_config.h' entries (e.g. '-DHAVE_SIN=1', '-UHAVE_COS')",
    );
    
    const pkg_config_exe = b.option(
        []const u8,
        "pkg_config",
        "pkg-config executable"
    ) orelse b.graph.environ_map.get("PKG_CONFIG") orelse "pkg-config";

    const pkg_config_sysroot_dir = b.option(
        []const u8,
        "pkg_config_sysroot_dir",
        "Target sysroot used by pkg-config"
    ) orelse b.graph.environ_map.get("PKG_CONFIG_SYSROOT_DIR");

    const pkg_config_libdir = b.option(
        []const u8,
        "pkg_config_libdir",
        "Target pkg-config search path"
    ) orelse b.graph.environ_map.get("PKG_CONFIG_LIBDIR");

    const wayland_scanner = b.option(
        []const u8,
        "wayland_scanner",
        "wayland-scanner executable"
    ) orelse "wayland-scanner";

    const readelf = b.option(
        []const u8,
        "readelf",
        "readelf executable used to inspect target SONAMEs"
    ) orelse "readelf";
    
    const soname_overrides = b.option(
        []const []const u8,
        "soname_overrides",
        "Override discovered SONAMEs (e.g. 'x11=libX11.so.6')",
    );

    var windows = false;
    var linux = false;
    var linux_deps: ?LinuxDeps = null;
    var macos = false;
    var emscripten = false;
    var msvc = false; // Assume mingw-w64 as the default for Windows
    var musl = false; // Assume glibc as the default for Linux
    switch (target.result.os.tag) {
        .windows => {
            windows = true;
            msvc = target.result.abi == .msvc;
        },
        .linux => {
            linux = true;
            musl = target.result.abi.isMusl();
            linux_deps = discoverLinuxDeps(b, target, .{
                .pkg_config_exe = pkg_config_exe,
                .pkg_config_sysroot_dir = pkg_config_sysroot_dir,
                .pkg_config_libdir = pkg_config_libdir,
                .wayland_scanner = wayland_scanner,
                .readelf = readelf,
                .soname_overrides = soname_overrides,
            });
        },
        .macos => {
            macos = true;
            if (@hasField(std.Build, "sysroot") and b.sysroot != null) { // TODO: Remove after 0.17
                const sysroot = b.sysroot.?;
                system_include_path = system_include_path orelse .{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) };
                system_framework_path = system_framework_path orelse .{ .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }) };
                library_path = library_path orelse .{ .cwd_relative = "/usr/lib" }; // ???
            }
            if (!target.query.isNative() and (system_include_path == null or system_framework_path == null or library_path == null)) {
                std.log.err("'-Dsystem_include_path', '-Dsystem_framework_path' and '-Dlibrary_path' are required when building SDL for non-native macOS targets", .{});
                std.process.exit(1);
            }
        },
        .emscripten => {
            emscripten = true;
            if (@hasField(std.Build, "sysroot") and b.sysroot != null) { // TODO: Remove after 0.17
                const sysroot = b.sysroot.?;
                system_include_path = system_include_path orelse .{ .cwd_relative = b.pathJoin(&.{ sysroot, "include" }) };
            }
            if (system_include_path == null) {
                std.log.err("'-Dsystem_include_path' is required when building SDL for Emscripten", .{});
                std.process.exit(1);
            }
        },
        else => {},
    }

    const build_config_h: *std.Build.Step.ConfigHeader = build_config_h: {
        const cpu = target.result.cpu;
        const x86 = cpu.arch.isX86();
        const arm = cpu.arch.isArm();
        const aarch64 = cpu.arch.isAARCH64();
        const loongarch = cpu.arch == .loongarch32 or cpu.arch == .loongarch64;
        break :build_config_h b.addConfigHeader(.{
            .style = .{ .cmake = sdl_dep.path("include/build_config/SDL_build_config.h.cmake") },
            .include_path = "SDL_build_config.h",
        }, .{
            .SDL_PLATFORM_PRIVATE = false,
            .HAVE_GCC_ATOMICS = windows or linux or macos or emscripten,
            .HAVE_GCC_SYNC_LOCK_TEST_AND_SET = false,
            .SDL_DISABLE_ALLOCA = false,
            .HAVE_FLOAT_H = windows or linux or macos or emscripten,
            .HAVE_STDARG_H = windows or linux or macos or emscripten,
            .HAVE_STDDEF_H = windows or linux or macos or emscripten,
            .HAVE_STDINT_H = windows or linux or macos or emscripten,
            .HAVE_LIBC = windows or linux or macos or emscripten,
            .HAVE_ALLOCA_H = linux or macos or emscripten,
            .HAVE_ICONV_H = linux or macos or emscripten,
            .HAVE_INTTYPES_H = windows or linux or macos or emscripten,
            .HAVE_LIMITS_H = windows or linux or macos or emscripten,
            .HAVE_MALLOC_H = windows or linux or emscripten,
            .HAVE_MATH_H = windows or linux or macos or emscripten,
            .HAVE_MEMORY_H = windows or linux or macos or emscripten,
            .HAVE_SIGNAL_H = windows or linux or macos or emscripten,
            .HAVE_STDIO_H = windows or linux or macos or emscripten,
            .HAVE_STDLIB_H = windows or linux or macos or emscripten,
            .HAVE_STRINGS_H = (windows and !msvc) or linux or macos or emscripten,
            .HAVE_STRING_H = windows or linux or macos or emscripten,
            .HAVE_SYS_TYPES_H = windows or linux or macos or emscripten,
            .HAVE_WCHAR_H = windows or linux or macos or emscripten,
            .HAVE_PTHREAD_NP_H = false,
            .HAVE_DLOPEN = linux or macos or emscripten,
            .HAVE_MALLOC = windows or linux or macos or emscripten,
            .HAVE_FDATASYNC = linux or emscripten,
            .HAVE_GETENV = windows or linux or macos or emscripten,
            .HAVE_GETHOSTNAME = linux or macos or emscripten,
            .HAVE_SETENV = linux or macos or emscripten,
            .HAVE_PUTENV = windows or linux or macos or emscripten,
            .HAVE_UNSETENV = linux or macos or emscripten,
            .HAVE_ABS = windows or linux or macos or emscripten,
            .HAVE_BCOPY = linux or macos or emscripten,
            .HAVE_MEMSET = windows or linux or macos or emscripten,
            .HAVE_MEMCPY = windows or linux or macos or emscripten,
            .HAVE_MEMMOVE = windows or linux or macos or emscripten,
            .HAVE_MEMCMP = windows or linux or macos or emscripten,
            .HAVE_WCSLEN = windows or linux or macos or emscripten,
            .HAVE_WCSNLEN = windows or linux or macos or emscripten,
            .HAVE_WCSLCPY = macos,
            .HAVE_WCSLCAT = macos,
            .HAVE_WCSSTR = windows or linux or macos or emscripten,
            .HAVE_WCSCMP = windows or linux or macos or emscripten,
            .HAVE_WCSNCMP = windows or linux or macos or emscripten,
            .HAVE_WCSTOL = windows or linux or macos or emscripten,
            .HAVE_STRLEN = windows or linux or macos or emscripten,
            .HAVE_STRNLEN = windows or linux or macos or emscripten,
            .HAVE_STRLCPY = (linux and musl) or macos or emscripten,
            .HAVE_STRLCAT = (linux and musl) or macos or emscripten,
            .HAVE_STRPBRK = windows or linux or macos or emscripten,
            .HAVE__STRREV = windows,
            .HAVE_INDEX = linux or macos or emscripten,
            .HAVE_RINDEX = linux or macos or emscripten,
            .HAVE_STRCHR = windows or linux or macos or emscripten,
            .HAVE_STRRCHR = windows or linux or macos or emscripten,
            .HAVE_STRSTR = windows or linux or macos or emscripten,
            .HAVE_STRNSTR = macos,
            .HAVE_STRTOK_R = (windows and !msvc) or linux or macos or emscripten,
            .HAVE_ITOA = windows,
            .HAVE__LTOA = windows,
            .HAVE__ULTOA = windows,
            .HAVE_STRTOL = windows or linux or macos or emscripten,
            .HAVE_STRTOUL = windows or linux or macos or emscripten,
            .HAVE__I64TOA = windows,
            .HAVE__UI64TOA = windows,
            .HAVE_STRTOLL = windows or linux or macos or emscripten,
            .HAVE_STRTOULL = windows or linux or macos or emscripten,
            .HAVE_STRTOD = windows or linux or macos or emscripten,
            .HAVE_ATOI = windows or linux or macos or emscripten,
            .HAVE_ATOF = windows or linux or macos or emscripten,
            .HAVE_STRCMP = windows or linux or macos or emscripten,
            .HAVE_STRNCMP = windows or linux or macos or emscripten,
            .HAVE_VSSCANF = windows or linux or macos or emscripten,
            .HAVE_VSNPRINTF = windows or linux or macos or emscripten,
            .HAVE_ACOS = windows or linux or macos or emscripten,
            .HAVE_ACOSF = windows or linux or macos or emscripten,
            .HAVE_ASIN = windows or linux or macos or emscripten,
            .HAVE_ASINF = windows or linux or macos or emscripten,
            .HAVE_ATAN = windows or linux or macos or emscripten,
            .HAVE_ATANF = windows or linux or macos or emscripten,
            .HAVE_ATAN2 = windows or linux or macos or emscripten,
            .HAVE_ATAN2F = windows or linux or macos or emscripten,
            .HAVE_CEIL = windows or linux or macos or emscripten,
            .HAVE_CEILF = windows or linux or macos or emscripten,
            .HAVE_COPYSIGN = windows or linux or macos or emscripten,
            .HAVE_COPYSIGNF = windows or linux or macos or emscripten,
            .HAVE__COPYSIGN = windows,
            .HAVE_COS = windows or linux or macos or emscripten,
            .HAVE_COSF = windows or linux or macos or emscripten,
            .HAVE_EXP = windows or linux or macos or emscripten,
            .HAVE_EXPF = windows or linux or macos or emscripten,
            .HAVE_FABS = windows or linux or macos or emscripten,
            .HAVE_FABSF = windows or linux or macos or emscripten,
            .HAVE_FLOOR = windows or linux or macos or emscripten,
            .HAVE_FLOORF = windows or linux or macos or emscripten,
            .HAVE_FMOD = windows or linux or macos or emscripten,
            .HAVE_FMODF = windows or linux or macos or emscripten,
            .HAVE_ISINF = windows or linux or macos or emscripten,
            .HAVE_ISINFF = (linux and !musl) or emscripten,
            .HAVE_ISINF_FLOAT_MACRO = windows or linux or macos or emscripten,
            .HAVE_ISNAN = windows or linux or macos or emscripten,
            .HAVE_ISNANF = (linux and !musl) or emscripten,
            .HAVE_ISNAN_FLOAT_MACRO = windows or linux or macos or emscripten,
            .HAVE_LOG = windows or linux or macos or emscripten,
            .HAVE_LOGF = windows or linux or macos or emscripten,
            .HAVE_LOG10 = windows or linux or macos or emscripten,
            .HAVE_LOG10F = windows or linux or macos or emscripten,
            .HAVE_LROUND = windows or linux or macos or emscripten,
            .HAVE_LROUNDF = windows or linux or macos or emscripten,
            .HAVE_MODF = windows or linux or macos or emscripten,
            .HAVE_MODFF = windows or linux or macos or emscripten,
            .HAVE_POW = windows or linux or macos or emscripten,
            .HAVE_POWF = windows or linux or macos or emscripten,
            .HAVE_ROUND = windows or linux or macos or emscripten,
            .HAVE_ROUNDF = windows or linux or macos or emscripten,
            .HAVE_SCALBN = windows or linux or macos or emscripten,
            .HAVE_SCALBNF = windows or linux or macos or emscripten,
            .HAVE_SIN = windows or linux or macos or emscripten,
            .HAVE_SINF = windows or linux or macos or emscripten,
            .HAVE_SQRT = windows or linux or macos or emscripten,
            .HAVE_SQRTF = windows or linux or macos or emscripten,
            .HAVE_TAN = windows or linux or macos or emscripten,
            .HAVE_TANF = windows or linux or macos or emscripten,
            .HAVE_TRUNC = windows or linux or macos or emscripten,
            .HAVE_TRUNCF = windows or linux or macos or emscripten,
            .HAVE__FSEEKI64 = windows,
            .HAVE_FOPEN64 = (windows and !msvc) or (linux and !musl) or emscripten,
            .HAVE_FSEEKO = (windows and !msvc) or linux or macos or emscripten,
            .HAVE_FSEEKO64 = (windows and !msvc) or (linux and !musl) or emscripten,
            .HAVE_MEMFD_CREATE = linux,
            .HAVE_POSIX_FALLOCATE = linux or emscripten,
            .HAVE_SIGACTION = linux or macos or emscripten,
            .HAVE_SIGTIMEDWAIT = linux or emscripten,
            .HAVE_SA_SIGACTION = linux or macos or emscripten,
            .HAVE_ST_MTIM = linux or emscripten,
            .HAVE_SETJMP = linux or macos or emscripten,
            .HAVE_NANOSLEEP = linux or macos or emscripten,
            .HAVE_GMTIME_R = linux or macos or emscripten,
            .HAVE_LOCALTIME_R = linux or macos or emscripten,
            .HAVE_NL_LANGINFO = linux or macos or emscripten,
            .HAVE_SYSCONF = linux or macos or emscripten,
            .HAVE_SYSCTLBYNAME = macos,
            .HAVE_CLOCK_GETTIME = linux or emscripten,
            .HAVE_GETPAGESIZE = linux or macos or emscripten,
            .HAVE_ICONV = linux or emscripten,
            .SDL_USE_LIBICONV = false,
            .HAVE_PTHREAD_SETNAME_NP = linux or macos,
            .HAVE_PTHREAD_SET_NAME_NP = false,
            .HAVE_SEM_TIMEDWAIT = linux or (emscripten and emscripten_pthreads),
            .HAVE_GETAUXVAL = linux,
            .HAVE_ELF_AUX_INFO = false,
            .HAVE_PPOLL = linux,
            .HAVE__EXIT = windows or linux or macos or emscripten,
            .HAVE_GETRESUID = linux or emscripten,
            .HAVE_GETRESGID = linux or emscripten,
            .HAVE_DBUS_DBUS_H = linux,
            .HAVE_FCITX = linux,
            .HAVE_IBUS_IBUS_H = linux,
            .HAVE_INOTIFY_INIT1 = linux,
            .HAVE_INOTIFY = linux,
            .HAVE_LIBUSB = linux,
            .HAVE_O_CLOEXEC = linux or macos or emscripten,
            .HAVE_LINUX_INPUT_H = linux,
            .HAVE_LIBUDEV_H = linux,
            .HAVE_LIBDECOR_H = linux,
            .HAVE_LIBURING_H = linux,
            .HAVE_FRIBIDI_H = linux,
            .SDL_FRIBIDI_DYNAMIC = sonameValue(b, linux_deps, "fribidi"),
            .HAVE_LIBTHAI_H = linux,
            .SDL_LIBTHAI_DYNAMIC = sonameValue(b, linux_deps, "thai"),
            .HAVE_DDRAW_H = windows,
            .HAVE_DSOUND_H = windows,
            .HAVE_DINPUT_H = windows,
            .HAVE_XINPUT_H = windows,
            .HAVE_WINDOWS_GAMING_INPUT_H = false,
            .HAVE_GAMEINPUT_H = (windows and msvc),
            .HAVE_DXGI_H = windows,
            .HAVE_DXGI1_5_H = windows,
            .HAVE_DXGI1_6_H = windows,
            .HAVE_MMDEVICEAPI_H = windows,
            .HAVE_TPCSHRD_H = windows,
            .HAVE_ROAPI_H = (windows and !msvc),
            .HAVE_SHELLSCALINGAPI_H = windows,
            .USE_POSIX_SPAWN = false,
            .HAVE_POSIX_SPAWN_FILE_ACTIONS_ADDCHDIR = macos,
            .HAVE_POSIX_SPAWN_FILE_ACTIONS_ADDCHDIR_NP = linux or macos or emscripten,
            .SDL_DISABLE_DLOPEN_NOTES = false,
            .SDL_DEFAULT_ASSERT_LEVEL_CONFIGURED = false,
            .SDL_DEFAULT_ASSERT_LEVEL = null,
            .SDL_AUDIO_DISABLED = false,
            .SDL_VIDEO_DISABLED = false,
            .SDL_GPU_DISABLED = false,
            .SDL_RENDER_DISABLED = false,
            .SDL_CAMERA_DISABLED = false,
            .SDL_JOYSTICK_DISABLED = false,
            .SDL_HAPTIC_DISABLED = false,
            .SDL_HIDAPI_DISABLED = false,
            .SDL_POWER_DISABLED = false,
            .SDL_SENSOR_DISABLED = false,
            .SDL_DIALOG_DISABLED = false,
            .SDL_THREADS_DISABLED = (emscripten and !emscripten_pthreads),
            .SDL_AUDIO_DRIVER_ALSA = linux,
            .SDL_AUDIO_DRIVER_ALSA_DYNAMIC = sonameValue(b, linux_deps, "asound"),
            .SDL_AUDIO_DRIVER_OPENSLES = false,
            .SDL_AUDIO_DRIVER_AAUDIO = false,
            .SDL_AUDIO_DRIVER_COREAUDIO = macos,
            .SDL_AUDIO_DRIVER_DISK = windows or linux or macos or emscripten,
            .SDL_AUDIO_DRIVER_DSOUND = windows,
            .SDL_AUDIO_DRIVER_DUMMY = windows or linux or macos or emscripten,
            .SDL_AUDIO_DRIVER_EMSCRIPTEN = emscripten,
            .SDL_AUDIO_DRIVER_HAIKU = false,
            .SDL_AUDIO_DRIVER_JACK = linux,
            .SDL_AUDIO_DRIVER_JACK_DYNAMIC = sonameValue(b, linux_deps, "jack"),
            .SDL_AUDIO_DRIVER_NETBSD = false,
            .SDL_AUDIO_DRIVER_OSS = false,
            .SDL_AUDIO_DRIVER_PIPEWIRE = linux,
            .SDL_AUDIO_DRIVER_PIPEWIRE_DYNAMIC = sonameValue(b, linux_deps, "pipewire-0.3"),
            .SDL_AUDIO_DRIVER_PULSEAUDIO = linux,
            .SDL_AUDIO_DRIVER_PULSEAUDIO_DYNAMIC = sonameValue(b, linux_deps, "pulse"),
            .SDL_AUDIO_DRIVER_SNDIO = linux,
            .SDL_AUDIO_DRIVER_SNDIO_DYNAMIC = sonameValue(b, linux_deps, "sndio"),
            .SDL_AUDIO_DRIVER_WASAPI = windows,
            .SDL_AUDIO_DRIVER_VITA = false,
            .SDL_AUDIO_DRIVER_PSP = false,
            .SDL_AUDIO_DRIVER_PS2 = false,
            .SDL_AUDIO_DRIVER_N3DS = false,
            .SDL_AUDIO_DRIVER_NGAGE = false,
            .SDL_AUDIO_DRIVER_QNX = false,
            .SDL_AUDIO_DRIVER_PRIVATE = false,
            .SDL_INPUT_LINUXEV = linux,
            .SDL_INPUT_LINUXKD = linux,
            .SDL_INPUT_FBSDKBIO = false,
            .SDL_INPUT_WSCONS = false,
            .SDL_HAVE_MACHINE_JOYSTICK_H = false,
            .SDL_JOYSTICK_ANDROID = false,
            .SDL_JOYSTICK_DINPUT = windows,
            .SDL_JOYSTICK_DUMMY = false,
            .SDL_JOYSTICK_EMSCRIPTEN = emscripten,
            .SDL_JOYSTICK_GAMEINPUT = (windows and msvc),
            .SDL_JOYSTICK_HAIKU = false,
            .SDL_JOYSTICK_HIDAPI = windows or linux or macos,
            .SDL_JOYSTICK_IOKIT = macos,
            .SDL_JOYSTICK_LINUX = linux,
            .SDL_JOYSTICK_MFI = macos,
            .SDL_JOYSTICK_N3DS = false,
            .SDL_JOYSTICK_PS2 = false,
            .SDL_JOYSTICK_PSP = false,
            .SDL_JOYSTICK_RAWINPUT = windows,
            .SDL_JOYSTICK_USBHID = false,
            .SDL_JOYSTICK_VIRTUAL = windows or linux or macos or emscripten,
            .SDL_JOYSTICK_VITA = false,
            .SDL_JOYSTICK_WGI = false,
            .SDL_JOYSTICK_XINPUT = windows,
            .SDL_JOYSTICK_PRIVATE = false,
            .SDL_HAPTIC_DUMMY = emscripten,
            .SDL_HAPTIC_LINUX = linux,
            .SDL_HAPTIC_IOKIT = macos,
            .SDL_HAPTIC_DINPUT = windows,
            .SDL_HAPTIC_ANDROID = false,
            .SDL_HAPTIC_PRIVATE = false,
            .SDL_LIBUSB_DYNAMIC = sonameValue(b, linux_deps, "usb-1.0"),
            .SDL_UDEV_DYNAMIC = sonameValue(b, linux_deps, "udev"),
            .SDL_PROCESS_DUMMY = emscripten,
            .SDL_PROCESS_POSIX = linux or macos,
            .SDL_PROCESS_WINDOWS = windows,
            .SDL_PROCESS_PRIVATE = false,
            .SDL_SENSOR_ANDROID = false,
            .SDL_SENSOR_COREMOTION = false,
            .SDL_SENSOR_WINDOWS = windows,
            .SDL_SENSOR_DUMMY = linux or macos,
            .SDL_SENSOR_VITA = false,
            .SDL_SENSOR_N3DS = false,
            .SDL_SENSOR_EMSCRIPTEN = emscripten,
            .SDL_SENSOR_PRIVATE = false,
            .SDL_LOADSO_DLOPEN = linux or macos or emscripten,
            .SDL_LOADSO_DUMMY = false,
            .SDL_LOADSO_WINDOWS = windows,
            .SDL_LOADSO_PRIVATE = false,
            .SDL_THREAD_GENERIC_COND_SUFFIX = windows,
            .SDL_THREAD_GENERIC_RWLOCK_SUFFIX = windows,
            .SDL_THREAD_PTHREAD = linux or macos or (emscripten and emscripten_pthreads),
            .SDL_THREAD_PTHREAD_RECURSIVE_MUTEX = linux or macos or (emscripten and emscripten_pthreads),
            .SDL_THREAD_PTHREAD_RECURSIVE_MUTEX_NP = false,
            .SDL_THREAD_WINDOWS = windows,
            .SDL_THREAD_VITA = false,
            .SDL_THREAD_PSP = false,
            .SDL_THREAD_PS2 = false,
            .SDL_THREAD_N3DS = false,
            .SDL_THREAD_PRIVATE = false,
            .SDL_TIME_UNIX = linux or macos or emscripten,
            .SDL_TIME_WINDOWS = windows,
            .SDL_TIME_VITA = false,
            .SDL_TIME_PSP = false,
            .SDL_TIME_PS2 = false,
            .SDL_TIME_N3DS = false,
            .SDL_TIME_NGAGE = false,
            .SDL_TIME_PRIVATE = false,
            .SDL_TIMER_HAIKU = false,
            .SDL_TIMER_UNIX = linux or macos or emscripten,
            .SDL_TIMER_WINDOWS = windows,
            .SDL_TIMER_VITA = false,
            .SDL_TIMER_PSP = false,
            .SDL_TIMER_PS2 = false,
            .SDL_TIMER_N3DS = false,
            .SDL_TIMER_PRIVATE = false,
            .SDL_VIDEO_DRIVER_ANDROID = false,
            .SDL_VIDEO_DRIVER_COCOA = macos,
            .SDL_VIDEO_DRIVER_DUMMY = windows or linux or macos or emscripten,
            .SDL_VIDEO_DRIVER_EMSCRIPTEN = emscripten,
            .SDL_VIDEO_DRIVER_HAIKU = false,
            .SDL_VIDEO_DRIVER_KMSDRM = linux,
            .SDL_VIDEO_DRIVER_KMSDRM_DYNAMIC = sonameValue(b, linux_deps, "drm"),
            .SDL_VIDEO_DRIVER_KMSDRM_DYNAMIC_GBM = sonameValue(b, linux_deps, "gbm"),
            .SDL_VIDEO_DRIVER_N3DS = false,
            .SDL_VIDEO_DRIVER_NGAGE = false,
            .SDL_VIDEO_DRIVER_OFFSCREEN = windows or linux or macos or emscripten,
            .SDL_VIDEO_DRIVER_PS2 = false,
            .SDL_VIDEO_DRIVER_PSP = false,
            .SDL_VIDEO_DRIVER_RISCOS = false,
            .SDL_VIDEO_DRIVER_ROCKCHIP = false,
            .SDL_VIDEO_DRIVER_RPI = false,
            .SDL_VIDEO_DRIVER_UIKIT = false,
            .SDL_VIDEO_DRIVER_VITA = false,
            .SDL_VIDEO_DRIVER_VIVANTE = false,
            .SDL_VIDEO_DRIVER_VIVANTE_VDK = false,
            .SDL_VIDEO_DRIVER_OPENVR = false,
            .SDL_VIDEO_DRIVER_WAYLAND = linux,
            .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC = sonameValue(b, linux_deps, "wayland-client"),
            .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_CURSOR = sonameValue(b, linux_deps, "wayland-cursor"),
            .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_EGL = sonameValue(b, linux_deps, "wayland-egl"),
            .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_LIBDECOR = sonameValue(b, linux_deps, "decor-0"),
            .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_XKBCOMMON = sonameValue(b, linux_deps, "xkbcommon"),
            .SDL_VIDEO_DRIVER_WINDOWS = windows,
            .SDL_VIDEO_DRIVER_X11 = linux,
            .SDL_VIDEO_DRIVER_X11_DYNAMIC = sonameValue(b, linux_deps, "X11"),
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XCURSOR = sonameValue(b, linux_deps, "Xcursor"),
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XEXT = sonameValue(b, linux_deps, "Xext"),
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XFIXES = sonameValue(b, linux_deps, "Xfixes"),
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XINPUT2 = sonameValue(b, linux_deps, "Xi"),
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XRANDR = sonameValue(b, linux_deps, "Xrandr"),
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XSS = sonameValue(b, linux_deps, "Xss"),
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XTEST = sonameValue(b, linux_deps, "Xtst"),
            .SDL_VIDEO_DRIVER_X11_HAS_XKBLIB = linux,
            .SDL_VIDEO_DRIVER_X11_SUPPORTS_GENERIC_EVENTS = linux,
            .SDL_VIDEO_DRIVER_X11_XCURSOR = linux,
            .SDL_VIDEO_DRIVER_X11_XDBE = linux,
            .SDL_VIDEO_DRIVER_X11_XFIXES = linux,
            .SDL_VIDEO_DRIVER_X11_XINPUT2 = linux,
            .SDL_VIDEO_DRIVER_X11_XINPUT2_SUPPORTS_MULTITOUCH = linux,
            .SDL_VIDEO_DRIVER_X11_XINPUT2_SUPPORTS_SCROLLINFO = linux,
            .SDL_VIDEO_DRIVER_X11_XINPUT2_SUPPORTS_GESTURE = linux,
            .SDL_VIDEO_DRIVER_X11_XRANDR = linux,
            .SDL_VIDEO_DRIVER_X11_XSCRNSAVER = linux,
            .SDL_VIDEO_DRIVER_X11_XSHAPE = linux,
            .SDL_VIDEO_DRIVER_X11_XSYNC = linux,
            .SDL_VIDEO_DRIVER_X11_XTEST = linux,
            .SDL_VIDEO_DRIVER_QNX = false,
            .SDL_VIDEO_DRIVER_PRIVATE = false,
            .SDL_VIDEO_RENDER_D3D = windows,
            .SDL_VIDEO_RENDER_D3D11 = windows,
            .SDL_VIDEO_RENDER_D3D12 = windows,
            .SDL_VIDEO_RENDER_GPU = windows or linux or macos,
            .SDL_VIDEO_RENDER_METAL = macos,
            .SDL_VIDEO_RENDER_VULKAN = windows or linux or macos,
            .SDL_VIDEO_RENDER_OGL = windows or linux or macos,
            .SDL_VIDEO_RENDER_OGL_ES2 = windows or linux or macos or emscripten,
            .SDL_VIDEO_RENDER_NGAGE = false,
            .SDL_VIDEO_RENDER_PS2 = false,
            .SDL_VIDEO_RENDER_PSP = false,
            .SDL_VIDEO_RENDER_VITA_GXM = false,
            .SDL_VIDEO_RENDER_PRIVATE = false,
            .SDL_VIDEO_OPENGL = windows or linux or macos,
            .SDL_VIDEO_OPENGL_ES = linux,
            .SDL_VIDEO_OPENGL_ES2 = windows or linux or macos or emscripten,
            .SDL_VIDEO_OPENGL_CGL = macos,
            .SDL_VIDEO_OPENGL_GLX = linux,
            .SDL_VIDEO_OPENGL_WGL = windows,
            .SDL_VIDEO_OPENGL_EGL = windows or linux or macos,
            .SDL_VIDEO_STATIC_ANGLE = false,
            .SDL_VIDEO_VULKAN = windows or linux or macos,
            .SDL_VIDEO_METAL = macos,
            .SDL_GPU_D3D11 = false,
            .SDL_GPU_D3D12 = windows,
            .SDL_GPU_VULKAN = windows or linux or macos,
            .SDL_GPU_METAL = macos,
            .SDL_GPU_PRIVATE = false,
            .SDL_POWER_ANDROID = false,
            .SDL_POWER_LINUX = linux,
            .SDL_POWER_WINDOWS = windows,
            .SDL_POWER_MACOSX = macos,
            .SDL_POWER_UIKIT = false,
            .SDL_POWER_HAIKU = false,
            .SDL_POWER_EMSCRIPTEN = emscripten,
            .SDL_POWER_HARDWIRED = false,
            .SDL_POWER_VITA = false,
            .SDL_POWER_PSP = false,
            .SDL_POWER_N3DS = false,
            .SDL_POWER_PRIVATE = false,
            .SDL_FILESYSTEM_ANDROID = false,
            .SDL_FILESYSTEM_HAIKU = false,
            .SDL_FILESYSTEM_COCOA = macos,
            .SDL_FILESYSTEM_DUMMY = false,
            .SDL_FILESYSTEM_RISCOS = false,
            .SDL_FILESYSTEM_UNIX = linux,
            .SDL_FILESYSTEM_WINDOWS = windows,
            .SDL_FILESYSTEM_EMSCRIPTEN = emscripten,
            .SDL_FILESYSTEM_VITA = false,
            .SDL_FILESYSTEM_PSP = false,
            .SDL_FILESYSTEM_PS2 = false,
            .SDL_FILESYSTEM_N3DS = false,
            .SDL_FILESYSTEM_PRIVATE = false,
            .SDL_STORAGE_STEAM = windows or linux or macos,
            .SDL_STORAGE_PRIVATE = false,
            .SDL_FSOPS_POSIX = linux or macos or emscripten,
            .SDL_FSOPS_WINDOWS = windows,
            .SDL_FSOPS_DUMMY = false,
            .SDL_FSOPS_PRIVATE = false,
            .SDL_CAMERA_DRIVER_DUMMY = windows or linux or macos or emscripten,
            .SDL_CAMERA_DRIVER_V4L2 = linux,
            .SDL_CAMERA_DRIVER_COREMEDIA = macos,
            .SDL_CAMERA_DRIVER_ANDROID = false,
            .SDL_CAMERA_DRIVER_EMSCRIPTEN = emscripten,
            .SDL_CAMERA_DRIVER_MEDIAFOUNDATION = windows,
            .SDL_CAMERA_DRIVER_PIPEWIRE = linux,
            .SDL_CAMERA_DRIVER_PIPEWIRE_DYNAMIC = sonameValue(b, linux_deps, "pipewire-0.3"),
            .SDL_CAMERA_DRIVER_VITA = false,
            .SDL_CAMERA_DRIVER_PRIVATE = false,
            .SDL_DIALOG_DUMMY = false,
            .SDL_TRAY_DUMMY = emscripten,
            .SDL_ALTIVEC_BLITTERS = false,
            .DYNAPI_NEEDS_DLOPEN = linux or macos or emscripten,
            .SDL_USE_IME = linux,
            .SDL_DISABLE_WINDOWS_IME = false,
            .SDL_GDK_TEXTINPUT = false,
            .SDL_IPHONE_KEYBOARD = false,
            .SDL_IPHONE_LAUNCHSCREEN = false,
            .SDL_VIDEO_VITA_PIB = false,
            .SDL_VIDEO_VITA_PVR = false,
            .SDL_VIDEO_VITA_PVR_OGL = false,
            .SDL_EMSCRIPTEN_PERSISTENT_PATH_STRING = null,
            .SDL_XKBCOMMON_VERSION_MAJOR = versionComponent(linux_deps, .xkbcommon, .major),
            .SDL_XKBCOMMON_VERSION_MINOR = versionComponent(linux_deps, .xkbcommon, .minor),
            .SDL_XKBCOMMON_VERSION_PATCH = versionComponent(linux_deps, .xkbcommon, .patch),
            .SDL_LIBDECOR_VERSION_MAJOR = versionComponent(linux_deps, .libdecor, .major),
            .SDL_LIBDECOR_VERSION_MINOR = versionComponent(linux_deps, .libdecor, .minor),
            .SDL_LIBDECOR_VERSION_PATCH = versionComponent(linux_deps, .libdecor, .patch),
            .SDL_DISABLE_SSE = !(x86 and std.Target.x86.featureSetHas(cpu.features, .sse)),
            .SDL_DISABLE_SSE2 = !(x86 and std.Target.x86.featureSetHas(cpu.features, .sse2)),
            .SDL_DISABLE_SSE3 = !(x86 and std.Target.x86.featureSetHas(cpu.features, .sse3)),
            .SDL_DISABLE_SSE4_1 = !(x86 and std.Target.x86.featureSetHas(cpu.features, .sse4_1)),
            .SDL_DISABLE_SSE4_2 = !(x86 and std.Target.x86.featureSetHas(cpu.features, .sse4_2)),
            .SDL_DISABLE_AVX = !(x86 and std.Target.x86.featureSetHas(cpu.features, .avx)),
            .SDL_DISABLE_AVX2 = !(x86 and std.Target.x86.featureSetHas(cpu.features, .avx2)),
            .SDL_DISABLE_AVX512F = !(x86 and std.Target.x86.featureSetHas(cpu.features, .avx512f)),
            .SDL_DISABLE_MMX = !(x86 and std.Target.x86.featureSetHas(cpu.features, .mmx)),
            .SDL_DISABLE_LSX = !(loongarch and std.Target.loongarch.featureSetHas(cpu.features, .lsx)),
            .SDL_DISABLE_LASX = !(loongarch and std.Target.loongarch.featureSetHas(cpu.features, .lasx)),
            .SDL_DISABLE_NEON = !(arm and std.Target.arm.featureSetHas(cpu.features, .neon) or aarch64 and std.Target.aarch64.featureSetHas(cpu.features, .neon)),
        });
    };

    if (build_config_h_overrides) |overrides| for (overrides) |override| {
        if (std.mem.startsWith(u8, override, "-D")) {
            const name, const value = std.mem.cutScalar(u8, override[2..], '=') orelse .{ override[2..], "1" };
            build_config_h.addIdent(name, value);
        } else if (std.mem.startsWith(u8, override, "-U")) {
            _ = build_config_h.values.swapRemove(override[2..]);
        } else {
            std.log.err("expected 'SDL_build_config.h' entry override in the form '-D<name>[=<value>]' or '-U<name>', found '{s}'", .{override});
            std.process.exit(1);
        }
    };

    const url_path = try uri.path.toRawMaybeAlloc(b.allocator);
    const filename = std.mem.lastIndexOfScalar(u8, url_path, '/') orelse @panic("sdl3 dependency version");
    const name = url_path[filename + 1 ..];
    const prefix = "SDL3-";
    const suffix = ".zip";
    const version = name[prefix.len .. name.len - suffix.len];
    const parsed_version = try std.SemanticVersion.parse(version);

    const revision = b.addConfigHeader(.{
        .style = .{ .cmake = sdl_dep.path("include/build_config/SDL_revision.h.cmake") },
        .include_path = "SDL3/SDL_revision.h",
    }, .{
        .SDL_VENDOR_INFO = "https://github.com/libsdl-org/SDL/",
        .SDL_REVISION = version,
    });

    const sdl_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .sanitize_c = sanitize_c,
        .pic = pic,
    });

    const sdl_lib = b.addLibrary(.{
        .linkage = if (emscripten) .static else preferred_linkage,
        .name = "sdl3_artifact",
        .root_module = sdl_module,
        .version = .{
            .major = parsed_version.major,
            .minor = parsed_version.minor,
            .patch = parsed_version.patch,
        },
        .use_llvm = if (emscripten) true else null,
    });
    sdl_lib.lto = lto;

    switch (sdl_lib.linkage.?) {
        .static => {
            sdl_module.addCMacro("SDL_STATIC_LIB", "1");
        },
        .dynamic => {
            sdl_module.addCMacro("DLL_EXPORT", "1");
        },
    }

    sdl_module.addCMacro("USING_GENERATED_CONFIG_H", "1");
    sdl_module.addCMacro("SDL_BUILD_MAJOR_VERSION", b.fmt("{d}", .{ parsed_version.major }));
    sdl_module.addCMacro("SDL_BUILD_MINOR_VERSION", b.fmt("{d}", .{ parsed_version.minor }));
    sdl_module.addCMacro("SDL_BUILD_MICRO_VERSION", b.fmt("{d}", .{ parsed_version.patch }));

    sdl_module.addConfigHeader(build_config_h);
    sdl_module.addConfigHeader(revision);
    sdl_module.addIncludePath(sdl_include);
    sdl_module.addIncludePath(sdl_source);
    sdl_module.addSystemIncludePath(sdl_source.path(b, "video/khronos"));
    if (linux_deps) |deps| {
        for (deps.include_paths) |path| {
            sdl_module.addSystemIncludePath(.{ .cwd_relative = path });
        }
    }

    if (target.result.os.tag == .linux) {
        sdl_module.linkSystemLibrary("m", .{});
        sdl_module.linkSystemLibrary("dl", .{});
        sdl_module.linkSystemLibrary("pthread", .{});
    }

    if (windows and msvc) {
        sdl_module.addCMacro("_CRT_SECURE_NO_DEPRECATE", "1");
        sdl_module.addCMacro("_CRT_NONSTDC_NO_DEPRECATE", "1");
        sdl_module.addCMacro("_CRT_SECURE_NO_WARNINGS", "1");
    }
    if (emscripten and emscripten_pthreads) {
        sdl_module.addCMacro("__EMSCRIPTEN_PTHREADS__", "1");
        sdl_module.addCMacro("_REENTRANT", "1");
    }

    if (system_include_path) |path| {
        sdl_module.addSystemIncludePath(path);
    }
    if (system_framework_path) |path| {
        sdl_module.addSystemFrameworkPath(path);
    }
    if (library_path) |path| {
        sdl_module.addLibraryPath(path);
    }

    var cflags: std.ArrayList([]const u8) = .empty;
    cflags.appendSlice(b.allocator, &.{
        "-Wall",
        "-Wundef",
        "-Wfloat-conversion",
        "-fno-strict-aliasing",
        "-Wshadow",
        "-Wno-unused-local-typedefs",
        "-Wimplicit-fallthrough",
    }) catch @panic("out of memory");

    if (sdl_lib.linkage.? == .dynamic) {
        cflags.append(b.allocator, "-fvisibility=hidden") catch @panic("out of memory");
    }
    if (linux) {
        cflags.append(b.allocator, "-pthread") catch @panic("out of memory");
        cflags.appendSlice(b.allocator, linux_deps.?.cflags) catch @panic("out of memory");
    }
    if (macos) {
        cflags.append(b.allocator, "-pthread") catch @panic("out of memory");
        cflags.append(b.allocator, "-fobjc-arc") catch @panic("out of memory");
    }
    if (emscripten and emscripten_pthreads) {
        cflags.append(b.allocator, "-pthread") catch @panic("out of memory");
    }

    addPlatformSources(
        b,
        sdl_module,
        .{
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .sanitize_c = sanitize_c,
            .pic = pic,
            .lto = lto,
            .emscripten_pthreads = emscripten_pthreads,
            .build_configheader = build_config_h,
            .revision_configheader = revision,
            .sdl_dep = sdl_dep,
            .sdl_library = sdl_lib,
            .linux_deps = if (linux) &linux_deps.? else null,
        },
        cflags.items,
    );

    const install_sdl_lib = b.addInstallArtifact(sdl_lib, .{});

    const install_sdl = b.step("install_sdl", "Install SDL");
    install_sdl.dependOn(&install_sdl_lib.step);

    b.getInstallStep().dependOn(&install_sdl_lib.step);

    const translate = b.addTranslateC(.{
        .root_source_file = sdl_dep.path("include/SDL3/SDL.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate.addIncludePath(sdl_include);
    translate.addConfigHeader(build_config_h);
    translate.addConfigHeader(revision);
    const sdl_translate_module = translate.addModule("sdl3_tc");

    const demo_module = b.createModule(.{
        .root_source_file = b.path("src/sdl_demo.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    demo_module.addImport("sdl3_tc", sdl_translate_module);
    demo_module.linkLibrary(sdl_lib);

    const demo = b.addExecutable(.{
        .name = "sdl_demo",
        .root_module = demo_module,
    });
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    if (b.args) |args| run_demo.addArgs(args);
    const run_step = b.step("run", "Run the SDL graphics demo");
    run_step.dependOn(&run_demo.step);
}

const LinuxDiscoveryOptions = struct {
    pkg_config_exe: []const u8,
    pkg_config_sysroot_dir: ?[]const u8,
    pkg_config_libdir: ?[]const u8,
    wayland_scanner: []const u8,
    readelf: []const u8,
    soname_overrides: ?[]const []const u8,
};

const Soname = struct {
    key: []const u8,
    value: []const u8,
};

const LinuxDeps = struct {
    include_paths: []const []const u8,
    cflags: []const []const u8,
    sonames: []const Soname,
    xkbcommon_version: std.SemanticVersion,
    libdecor_version: std.SemanticVersion,
    wayland_scanner: []const u8,
    wayland_scanner_mode: []const u8,

    fn soname(deps: LinuxDeps, key: []const u8) []const u8 {
        for (deps.sonames) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        @panic("missing discovered SONAME");
    }
};

const PkgSpec = struct {
    name: []const u8,
    requirement: ?[]const u8 = null,
};

const SonameSpec = struct {
    key: []const u8,
    package: []const u8,
};

fn discoverLinuxDeps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    options: LinuxDiscoveryOptions,
) LinuxDeps {
    if (!target.query.isNative() and (options.pkg_config_sysroot_dir == null or options.pkg_config_libdir == null)) {
        std.log.err("cross-compiling SDL for Linux requires '-Dpkg_config_sysroot_dir' and '-Dpkg_config_libdir' (or their PKG_CONFIG_* environment equivalents)", .{});
        std.process.exit(1);
    }

    var environ = b.graph.environ_map.clone(b.allocator) catch @panic("out of memory");
    defer environ.deinit();
    environ.put("LC_ALL", "C") catch @panic("out of memory");
    if (options.pkg_config_sysroot_dir) |value| {
        environ.put("PKG_CONFIG_SYSROOT_DIR", value) catch @panic("out of memory");
    }
    if (options.pkg_config_libdir) |value| {
        environ.put("PKG_CONFIG_LIBDIR", value) catch @panic("out of memory");
        _ = environ.swapRemove("PKG_CONFIG_PATH");
    }

    const packages = [_]PkgSpec{
        .{ .name = "x11" },
        .{ .name = "xext" },
        .{ .name = "xcursor" },
        .{ .name = "xi" },
        .{ .name = "xfixes" },
        .{ .name = "xrandr" },
        .{ .name = "xrender" },
        .{ .name = "xscrnsaver" },
        .{ .name = "xtst" },
        .{ .name = "wayland-client", .requirement = "wayland-client >= 1.18" },
        .{ .name = "wayland-egl" },
        .{ .name = "wayland-cursor" },
        .{ .name = "egl" },
        .{ .name = "xkbcommon", .requirement = "xkbcommon >= 0.5.0" },
        .{ .name = "libdecor-0" },
        .{ .name = "alsa" },
        .{ .name = "libpipewire-0.3", .requirement = "libpipewire-0.3 >= 0.3.44" },
        .{ .name = "libpulse", .requirement = "libpulse >= 0.9.15" },
        .{ .name = "jack" },
        .{ .name = "sndio" },
        .{ .name = "libdrm" },
        .{ .name = "gbm" },
        .{ .name = "fribidi" },
        .{ .name = "libthai" },
        .{ .name = "libusb-1.0", .requirement = "libusb-1.0 >= 1.0.16" },
        .{ .name = "dbus-1" },
        .{ .name = "ibus-1.0" },
        .{ .name = "liburing-ffi" },
        .{ .name = "libudev" },
    };

    var include_paths: std.ArrayList([]const u8) = .empty;
    var cflags: std.ArrayList([]const u8) = .empty;

    for (packages) |package| {
        const spec = package.requirement orelse package.name;
        runPkgConfigCheck(b, options.pkg_config_exe, &environ, package.name, spec);
        const output = runCommand(b, &.{ options.pkg_config_exe, "--cflags", package.name }, &environ, package.name);
        if (output.len == 0) {
            continue;
        }

        var it = std.mem.splitScalar(u8, output, ' ');
        while (it.next()) |flag| {
            if (std.mem.startsWith(u8, flag, "-I") and flag.len > 2) {
                appendUnique(b, &include_paths, flag[2..]);
            } else {
                appendUnique(b, &cflags, flag);
            }
        }
    }

    const xkbcommon_version = pkgConfigVersion(b, options.pkg_config_exe, &environ, "xkbcommon");
    const libdecor_version = pkgConfigVersion(b, options.pkg_config_exe, &environ, "libdecor-0");
    const scanner_version = pkgConfigVersion(b, options.pkg_config_exe, &environ, "wayland-scanner");

    const scanner_mode = if (scanner_version.order(.{ .major = 1, .minor = 15, .patch = 0 }) == .lt)
        "code"
    else
        "private-code";

    const soname_specs = [_]SonameSpec{
        .{ .key = "X11", .package = "x11" },
        .{ .key = "Xext", .package = "xext" },
        .{ .key = "Xcursor", .package = "xcursor" },
        .{ .key = "Xi", .package = "xi" },
        .{ .key = "Xfixes", .package = "xfixes" },
        .{ .key = "Xrandr", .package = "xrandr" },
        .{ .key = "Xss", .package = "xscrnsaver" },
        .{ .key = "Xtst", .package = "xtst" },
        .{ .key = "wayland-client", .package = "wayland-client" },
        .{ .key = "wayland-cursor", .package = "wayland-cursor" },
        .{ .key = "wayland-egl", .package = "wayland-egl" },
        .{ .key = "xkbcommon", .package = "xkbcommon" },
        .{ .key = "decor-0", .package = "libdecor-0" },
        .{ .key = "asound", .package = "alsa" },
        .{ .key = "pipewire-0.3", .package = "libpipewire-0.3" },
        .{ .key = "pulse", .package = "libpulse" },
        .{ .key = "jack", .package = "jack" },
        .{ .key = "sndio", .package = "sndio" },
        .{ .key = "drm", .package = "libdrm" },
        .{ .key = "gbm", .package = "gbm" },
        .{ .key = "fribidi", .package = "fribidi" },
        .{ .key = "thai", .package = "libthai" },
        .{ .key = "usb-1.0", .package = "libusb-1.0" },
        .{ .key = "udev", .package = "libudev" },
    };

    var sonames: std.ArrayList(Soname) = .empty;
    for (soname_specs) |spec| {
        const value = sonameOverride(options.soname_overrides, spec.key) orelse discoverSoname(
            b,
            options.pkg_config_exe,
            options.readelf,
            options.pkg_config_sysroot_dir,
            &environ,
            spec,
        );
        validateSoname(spec.key, value);
        sonames.append(b.allocator, .{ .key = spec.key, .value = value }) catch @panic("out of memory");
    }

    return .{
        .include_paths = include_paths.toOwnedSlice(b.allocator) catch @panic("out of memory"),
        .cflags = cflags.toOwnedSlice(b.allocator) catch @panic("out of memory"),
        .sonames = sonames.toOwnedSlice(b.allocator) catch @panic("out of memory"),
        .xkbcommon_version = xkbcommon_version,
        .libdecor_version = libdecor_version,
        .wayland_scanner = options.wayland_scanner,
        .wayland_scanner_mode = scanner_mode,
    };
}

fn runPkgConfigCheck(
    b: *std.Build,
    executable: []const u8,
    environ: *const std.process.Environ.Map,
    package: []const u8,
    spec: []const u8,
) void {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ executable, "--print-errors", "--exists", spec },
        .environ_map = environ,
    }) catch |err| {
        std.log.err("failed to execute '{s}' while checking Linux SDL dependency '{s}': {s}", .{ executable, package, @errorName(err) });
        std.process.exit(1);
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    if (!termSucceeded(result.term)) {
        std.log.err("required Linux SDL dependency '{s}' was not found:\n{s}", .{ package, std.mem.trim(u8, result.stderr, " \r\n") });
        std.process.exit(1);
    }
}

fn runCommand(
    b: *std.Build,
    argv: []const []const u8,
    environ: ?*const std.process.Environ.Map,
    context: []const u8,
) []const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{ .argv = argv, .environ_map = environ }) catch |err| {
        std.log.err("failed to execute '{s}' while discovering '{s}': {s}", .{ argv[0], context, @errorName(err) });
        std.process.exit(1);
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    if (!termSucceeded(result.term)) {
        std.log.err("'{s}' failed while discovering '{s}':\n{s}", .{ argv[0], context, std.mem.trim(u8, result.stderr, " \r\n") });
        std.process.exit(1);
    }
    const output = if (std.mem.trim(u8, result.stdout, " \r\n").len > 0) result.stdout else result.stderr;
    return b.dupe(std.mem.trim(u8, output, " \r\n"));
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn parseShellWords(b: *std.Build, input: []const u8) []const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var quote: ?u8 = null;
    var escaping = false;

    for (input) |byte| {
        if (escaping) {
            word.append(b.allocator, byte) catch @panic("out of memory");
            escaping = false;
        } else if (byte == '\\' and quote != '\'') {
            escaping = true;
        } else if (quote) |delimiter| {
            if (byte == delimiter) {
                quote = null;
            } else {
                word.append(b.allocator, byte) catch @panic("out of memory");
            }
        } else if (byte == '\'' or byte == '"') {
            quote = byte;
        } else if (std.ascii.isWhitespace(byte)) {
            if (word.items.len > 0) {
                words.append(b.allocator, b.dupe(word.items)) catch @panic("out of memory");
                word.clearRetainingCapacity();
            }
        } else {
            word.append(b.allocator, byte) catch @panic("out of memory");
        }
    }
    if (escaping or quote != null) {
        std.log.err("invalid shell escaping in pkg-config output: {s}", .{input});
        std.process.exit(1);
    }
    if (word.items.len > 0) {
        words.append(b.allocator, b.dupe(word.items)) catch @panic("out of memory");
    }
    return words.toOwnedSlice(b.allocator) catch @panic("out of memory");
}

fn appendUnique(b: *std.Build, list: *std.ArrayList([]const u8), value: []const u8) void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    list.append(b.allocator, b.dupe(value)) catch @panic("out of memory");
}

fn pkgConfigOutputError(package: []const u8) noreturn {
    std.log.err("invalid pkg-config output for Linux SDL dependency '{s}'", .{package});
    std.process.exit(1);
}

fn pkgConfigVersion(
    b: *std.Build,
    executable: []const u8,
    environ: *const std.process.Environ.Map,
    package: []const u8,
) std.SemanticVersion {
    const output = runCommand(b, &.{ executable, "--modversion", package }, environ, package);
    return std.SemanticVersion.parse(output) catch @panic("semantic version parse error");
}

fn discoverSoname(
    b: *std.Build,
    pkg_config_exe: []const u8,
    readelf: []const u8,
    sysroot: ?[]const u8,
    environ: *const std.process.Environ.Map,
    spec: SonameSpec,
) []const u8 {
    const raw_libdir = runCommand(b, &.{ pkg_config_exe, "--variable=libdir", spec.package }, environ, spec.package);

    var library_dirs: std.ArrayList([]const u8) = .empty;
    if (raw_libdir.len > 0) appendUnique(b, &library_dirs, sysrootPath(b, sysroot, raw_libdir));
    for (library_dirs.items) |libdir| {
        const library_path = b.pathJoin(&.{ libdir, b.fmt("lib{s}.so", .{spec.key}) });
        if (tryReadSoname(b, readelf, environ, library_path)) |soname| return soname;
    }

    std.log.err("unable to inspect target shared library 'lib{s}.so' for pkg-config package '{s}'", .{ spec.key, spec.package });
    std.process.exit(1);
}

fn tryReadSoname(
    b: *std.Build,
    readelf: []const u8,
    environ: *const std.process.Environ.Map,
    library_path: []const u8,
) ?[]const u8 {
    const result = std.process.run(b.allocator, b.graph.io, .{
        .argv = &.{ readelf, "-dW", library_path },
        .environ_map = environ,
    }) catch return null;
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    if (!termSucceeded(result.term)) return null;
    const marker = "Library soname: [";
    const marker_index = std.mem.indexOf(u8, result.stdout, marker) orelse return null;
    const value_start = marker_index + marker.len;
    const value_end = std.mem.findScalarPos(u8, result.stdout, value_start, ']') orelse return null;
    return b.dupe(result.stdout[value_start..value_end]);
}

fn sysrootPath(b: *std.Build, sysroot: ?[]const u8, path: []const u8) []const u8 {
    const root = sysroot orelse return path;
    if (!std.fs.path.isAbsolute(path) or std.mem.startsWith(u8, path, root)) return path;
    return b.pathJoin(&.{ root, std.mem.trimStart(u8, path, "/\\") });
}

fn sonameOverride(overrides: ?[]const []const u8, key: []const u8) ?[]const u8 {
    const values = overrides orelse return null;
    for (values) |entry| {
        const found_key, const value = std.mem.cutScalar(u8, entry, '=') orelse {
            std.log.err("expected SONAME override in the form '<library>=<soname>', found '{s}'", .{entry});
            std.process.exit(1);
        };
        if (std.ascii.eqlIgnoreCase(found_key, key)) return value;
    }
    return null;
}

fn validateSoname(key: []const u8, value: []const u8) void {
    if (value.len == 0) {
        std.log.err("empty SONAME discovered for '{s}'", .{key});
        std.process.exit(1);
    }
    for (value) |byte| {
        if (byte == '"' or byte == '\\' or std.ascii.isControl(byte)) {
            std.log.err("invalid character in SONAME '{s}' for '{s}'", .{ value, key });
            std.process.exit(1);
        }
    }
}

fn sonameValue(b: *std.Build, deps: ?LinuxDeps, key: []const u8) []const u8 {
    const linux_deps = deps orelse return "";
    return b.fmt("\"{s}\"", .{linux_deps.soname(key)});
}

const VersionKind = enum { xkbcommon, libdecor };
const VersionComponent = enum { major, minor, patch };

fn versionComponent(deps: ?LinuxDeps, kind: VersionKind, component: VersionComponent) ?i64 {
    const linux_deps = deps orelse return null;
    const version = switch (kind) {
        .xkbcommon => linux_deps.xkbcommon_version,
        .libdecor => linux_deps.libdecor_version,
    };
    return @intCast(switch (component) {
        .major => version.major,
        .minor => version.minor,
        .patch => version.patch,
    });
}

const platform_struct = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: ?bool,
    sanitize_c: ?std.zig.SanitizeC,
    pic: ?bool,
    lto: ?std.zig.LtoMode,
    emscripten_pthreads: bool,
    build_configheader: *std.Build.Step.ConfigHeader,
    revision_configheader: *std.Build.Step.ConfigHeader,
    sdl_dep: *std.Build.Dependency,
    sdl_library: *std.Build.Step.Compile,
    linux_deps: ?*const LinuxDeps,
};

fn addPlatformSources(
    b: *std.Build,
    module: *std.Build.Module,
    platform: platform_struct,
    cflags: []const []const u8,
) void {
    const sdl_source_lazypath = platform.sdl_dep.path("src");
    const sdl_include_lazypath = platform.sdl_dep.path("include");

    module.addCSourceFiles(.{
        .root = sdl_source_lazypath,
        .flags = cflags,
        .files = &.{
            "SDL.c",
            "SDL_assert.c",
            "SDL_error.c",
            "SDL_guid.c",
            "SDL_hashtable.c",
            "SDL_hints.c",
            "SDL_list.c",
            "SDL_log.c",
            "SDL_properties.c",
            "SDL_utils.c",
            "atomic/SDL_atomic.c",
            "atomic/SDL_spinlock.c",
            "audio/SDL_audio.c",
            "audio/SDL_audiocvt.c",
            "audio/SDL_audiodev.c",
            "audio/SDL_audioqueue.c",
            "audio/SDL_audioresample.c",
            "audio/SDL_audiotypecvt.c",
            "audio/SDL_mixer.c",
            "audio/SDL_wave.c",
            "camera/SDL_camera.c",
            "core/SDL_core_unsupported.c",
            "cpuinfo/SDL_cpuinfo.c",
            "dynapi/SDL_dynapi.c",
            "events/SDL_categories.c",
            "events/SDL_clipboardevents.c",
            "events/SDL_displayevents.c",
            "events/SDL_dropevents.c",
            "events/SDL_events.c",
            "events/SDL_eventwatch.c",
            "events/SDL_keyboard.c",
            "events/SDL_keymap.c",
            "events/SDL_keysym_to_keycode.c",
            "events/SDL_keysym_to_scancode.c",
            "events/SDL_mouse.c",
            "events/SDL_pen.c",
            "events/SDL_quit.c",
            "events/SDL_scancode_tables.c",
            "events/SDL_touch.c",
            "events/SDL_windowevents.c",
            "events/imKStoUCS.c",
            "filesystem/SDL_filesystem.c",
            "gpu/SDL_gpu.c",
            "haptic/SDL_haptic.c",
            "hidapi/SDL_hidapi.c",
            "io/SDL_asyncio.c",
            "io/SDL_iostream.c",
            "io/generic/SDL_asyncio_generic.c",
            "joystick/SDL_gamepad.c",
            "joystick/SDL_joystick.c",
            "joystick/SDL_steam_virtual_gamepad.c",
            "joystick/controller_type.c",
            "locale/SDL_locale.c",
            "main/SDL_main_callbacks.c",
            "main/SDL_runapp.c",
            "misc/SDL_libusb.c",
            "misc/SDL_url.c",
            "power/SDL_power.c",
            "render/SDL_render.c",
            "render/SDL_render_unsupported.c",
            "render/SDL_yuv_sw.c",
            "render/direct3d/SDL_render_d3d.c",
            "render/direct3d/SDL_shaders_d3d.c",
            "render/direct3d11/SDL_render_d3d11.c",
            "render/direct3d11/SDL_shaders_d3d11.c",
            "render/direct3d12/SDL_render_d3d12.c",
            "render/direct3d12/SDL_shaders_d3d12.c",
            "render/gpu/SDL_pipeline_gpu.c",
            "render/gpu/SDL_render_gpu.c",
            "render/gpu/SDL_shaders_gpu.c",
            "render/ngage/SDL_render_ngage.c",
            "render/opengl/SDL_render_gl.c",
            "render/opengl/SDL_shaders_gl.c",
            "render/opengles2/SDL_render_gles2.c",
            "render/opengles2/SDL_shaders_gles2.c",
            "render/ps2/SDL_render_ps2.c",
            "render/psp/SDL_render_psp.c",
            "render/software/SDL_blendfillrect.c",
            "render/software/SDL_blendline.c",
            "render/software/SDL_blendpoint.c",
            "render/software/SDL_drawline.c",
            "render/software/SDL_drawpoint.c",
            "render/software/SDL_render_sw.c",
            "render/software/SDL_triangle.c",
            "render/vitagxm/SDL_render_vita_gxm.c",
            "render/vitagxm/SDL_render_vita_gxm_memory.c",
            "render/vitagxm/SDL_render_vita_gxm_tools.c",
            "render/vulkan/SDL_render_vulkan.c",
            "render/vulkan/SDL_shaders_vulkan.c",
            "sensor/SDL_sensor.c",
            "stdlib/SDL_crc16.c",
            "stdlib/SDL_crc32.c",
            "stdlib/SDL_getenv.c",
            "stdlib/SDL_iconv.c",
            "stdlib/SDL_malloc.c",
            "stdlib/SDL_memcpy.c",
            "stdlib/SDL_memmove.c",
            "stdlib/SDL_memset.c",
            "stdlib/SDL_mslibc.c",
            "stdlib/SDL_murmur3.c",
            "stdlib/SDL_qsort.c",
            "stdlib/SDL_random.c",
            "stdlib/SDL_stdlib.c",
            "stdlib/SDL_string.c",
            "stdlib/SDL_strtokr.c",
            "storage/SDL_storage.c",
            "thread/SDL_thread.c",
            "time/SDL_time.c",
            "timer/SDL_timer.c",
            "video/SDL_RLEaccel.c",
            "video/SDL_blit.c",
            "video/SDL_blit_0.c",
            "video/SDL_blit_1.c",
            "video/SDL_blit_A.c",
            "video/SDL_blit_N.c",
            "video/SDL_blit_auto.c",
            "video/SDL_blit_copy.c",
            "video/SDL_blit_slow.c",
            "video/SDL_bmp.c",
            "video/SDL_clipboard.c",
            "video/SDL_egl.c",
            "video/SDL_fillrect.c",
            "video/SDL_pixels.c",
            "video/SDL_rect.c",
            "video/SDL_rotate.c",
            "video/SDL_stb.c",
            "video/SDL_stretch.c",
            "video/SDL_surface.c",
            "video/SDL_video.c",
            "video/SDL_video_unsupported.c",
            "video/SDL_vulkan_utils.c",
            "video/SDL_yuv.c",
            "video/yuv2rgb/yuv_rgb_lsx.c",
            "video/yuv2rgb/yuv_rgb_sse.c",
            "video/yuv2rgb/yuv_rgb_std.c",
            "dialog/SDL_dialog.c",
            "dialog/SDL_dialog_utils.c",
            "process/SDL_process.c",
            "tray/SDL_tray_utils.c",
        },
    });

    const sdl_uclibc_c_files = .{
        "libm/e_atan2.c",
        "libm/e_exp.c",
        "libm/e_fmod.c",
        "libm/e_log.c",
        "libm/e_log10.c",
        "libm/e_pow.c",
        "libm/e_rem_pio2.c",
        "libm/e_sqrt.c",
        "libm/k_cos.c",
        "libm/k_rem_pio2.c",
        "libm/k_sin.c",
        "libm/k_tan.c",
        "libm/s_atan.c",
        "libm/s_copysign.c",
        "libm/s_cos.c",
        "libm/s_fabs.c",
        "libm/s_floor.c",
        "libm/s_isinf.c",
        "libm/s_isinff.c",
        "libm/s_isnan.c",
        "libm/s_isnanf.c",
        "libm/s_modf.c",
        "libm/s_scalbn.c",
        "libm/s_sin.c",
        "libm/s_tan.c",
    };

    switch (platform.sdl_library.linkage.?) {
        .static => {
            module.addCSourceFiles(.{
                .root = sdl_source_lazypath,
                .flags = cflags,
                .files = &sdl_uclibc_c_files,
            });
        },
        .dynamic => {
            std.debug.assert(platform.target.result.os.tag != .emscripten);
            const sdl_uclibc_mod = b.createModule(.{
                .target = platform.target,
                .optimize = platform.optimize,
                .link_libc = true,
                .strip = platform.strip,
                .sanitize_c = platform.sanitize_c,
                .pic = platform.pic,
            });
            const sdl_uclibc_lib = b.addLibrary(.{
                .linkage = .static,
                .name = "SDL_uclib",
                .root_module = sdl_uclibc_mod,
            });
            sdl_uclibc_lib.lto = platform.lto;

            sdl_uclibc_mod.addCMacro("USING_GENERATED_CONFIG_H", "1");

            sdl_uclibc_mod.addConfigHeader(platform.build_configheader);
            sdl_uclibc_mod.addConfigHeader(platform.revision_configheader);
            sdl_uclibc_mod.addIncludePath(sdl_include_lazypath);
            sdl_uclibc_mod.addIncludePath(sdl_source_lazypath);

            var uclibc_flags: std.ArrayList([]const u8) = .empty;
            uclibc_flags.appendSlice(b.allocator, cflags) catch @panic("out of memory");
            uclibc_flags.append(b.allocator, "-fvisibility=hidden") catch @panic("out of memory");
            sdl_uclibc_mod.addCSourceFiles(.{
                .root = sdl_source_lazypath,
                .flags = uclibc_flags.items,
                .files = &sdl_uclibc_c_files,
            });

            module.linkLibrary(sdl_uclibc_lib);
        },
    }

    switch (platform.target.result.os.tag) {
        .linux => {
            module.addCSourceFiles(.{
                .root = sdl_source_lazypath,
                .flags = cflags,
                .files = &.{
                    "audio/dummy/SDL_dummyaudio.c",
                    "audio/disk/SDL_diskaudio.c",
                    "camera/dummy/SDL_camera_dummy.c",
                    "loadso/dlopen/SDL_sysloadso.c",
                    "joystick/virtual/SDL_virtualjoystick.c",
                    "video/dummy/SDL_nullevents.c",
                    "video/dummy/SDL_nullframebuffer.c",
                    "video/dummy/SDL_nullvideo.c",
                    "audio/alsa/SDL_alsa_audio.c",
                    "audio/jack/SDL_jackaudio.c",
                    "audio/pipewire/SDL_pipewire.c",
                    "camera/pipewire/SDL_camera_pipewire.c",
                    "audio/pulseaudio/SDL_pulseaudio.c",
                    "audio/sndio/SDL_sndioaudio.c",
                    "video/x11/SDL_x11clipboard.c",
                    "video/x11/SDL_x11dyn.c",
                    "video/x11/SDL_x11events.c",
                    "video/x11/SDL_x11framebuffer.c",
                    "video/x11/SDL_x11keyboard.c",
                    "video/x11/SDL_x11messagebox.c",
                    "video/x11/SDL_x11modes.c",
                    "video/x11/SDL_x11mouse.c",
                    "video/x11/SDL_x11opengl.c",
                    "video/x11/SDL_x11opengles.c",
                    "video/x11/SDL_x11pen.c",
                    "video/x11/SDL_x11settings.c",
                    "video/x11/SDL_x11shape.c",
                    "video/x11/SDL_x11toolkit.c",
                    "video/x11/SDL_x11touch.c",
                    "video/x11/SDL_x11video.c",
                    "video/x11/SDL_x11vulkan.c",
                    "video/x11/SDL_x11window.c",
                    "video/x11/SDL_x11xfixes.c",
                    "video/x11/SDL_x11xinput2.c",
                    "video/x11/SDL_x11xsync.c",
                    "video/x11/SDL_x11xtest.c",
                    "video/x11/edid-parse.c",
                    "video/x11/xsettings-client.c",
                    "video/kmsdrm/SDL_kmsdrmdyn.c",
                    "video/kmsdrm/SDL_kmsdrmevents.c",
                    "video/kmsdrm/SDL_kmsdrmmouse.c",
                    "video/kmsdrm/SDL_kmsdrmopengles.c",
                    "video/kmsdrm/SDL_kmsdrmvideo.c",
                    "video/kmsdrm/SDL_kmsdrmvulkan.c",
                    "video/wayland/SDL_waylandclipboard.c",
                    "video/wayland/SDL_waylandcolor.c",
                    "video/wayland/SDL_waylanddatamanager.c",
                    "video/wayland/SDL_waylanddyn.c",
                    "video/wayland/SDL_waylandevents.c",
                    "video/wayland/SDL_waylandkeyboard.c",
                    "video/wayland/SDL_waylandmessagebox.c",
                    "video/wayland/SDL_waylandmouse.c",
                    "video/wayland/SDL_waylandopengles.c",
                    "video/wayland/SDL_waylandshmbuffer.c",
                    "video/wayland/SDL_waylandutil.c",
                    "video/wayland/SDL_waylandvideo.c",
                    "video/wayland/SDL_waylandvulkan.c",
                    "video/wayland/SDL_waylandwindow.c",
                    "tray/unix/SDL_tray.c",
                    "core/unix/SDL_appid.c",
                    "core/unix/SDL_fribidi.c",
                    "core/unix/SDL_gtk.c",
                    "core/unix/SDL_libthai.c",
                    "core/unix/SDL_poll.c",
                    "camera/v4l2/SDL_camera_v4l2.c",
                    "haptic/linux/SDL_syshaptic.c",
                    "core/linux/SDL_dbus.c",
                    "core/linux/SDL_system_theme.c",
                    "core/linux/SDL_progressbar.c",
                    "core/linux/SDL_ime.c",
                    "core/linux/SDL_ibus.c",
                    "core/linux/SDL_fcitx.c",
                    "core/linux/SDL_udev.c",
                    "core/linux/SDL_evdev.c",
                    "core/linux/SDL_evdev_kbd.c",
                    "io/io_uring/SDL_asyncio_liburing.c",
                    "core/linux/SDL_evdev_capabilities.c",
                    "core/linux/SDL_threadprio.c",
                    "joystick/hidapi/SDL_hidapi_8bitdo.c",
                    "joystick/hidapi/SDL_hidapi_combined.c",
                    "joystick/hidapi/SDL_hidapi_flydigi.c",
                    "joystick/hidapi/SDL_hidapi_gamecube.c",
                    "joystick/hidapi/SDL_hidapi_gip.c",
                    "joystick/hidapi/SDL_hidapi_lg4ff.c",
                    "joystick/hidapi/SDL_hidapi_luna.c",
                    "joystick/hidapi/SDL_hidapi_ps3.c",
                    "joystick/hidapi/SDL_hidapi_ps4.c",
                    "joystick/hidapi/SDL_hidapi_ps5.c",
                    "joystick/hidapi/SDL_hidapi_rumble.c",
                    "joystick/hidapi/SDL_hidapi_shield.c",
                    "joystick/hidapi/SDL_hidapi_sinput.c",
                    "joystick/hidapi/SDL_hidapi_stadia.c",
                    "joystick/hidapi/SDL_hidapi_steam.c",
                    "joystick/hidapi/SDL_hidapi_steam_hori.c",
                    "joystick/hidapi/SDL_hidapi_steam_triton.c",
                    "joystick/hidapi/SDL_hidapi_steamdeck.c",
                    "joystick/hidapi/SDL_hidapi_switch.c",
                    "joystick/hidapi/SDL_hidapi_switch2.c",
                    "joystick/hidapi/SDL_hidapi_wii.c",
                    "joystick/hidapi/SDL_hidapi_xbox360.c",
                    "joystick/hidapi/SDL_hidapi_xbox360w.c",
                    "joystick/hidapi/SDL_hidapi_xboxone.c",
                    "joystick/hidapi/SDL_hidapi_zuiki.c",
                    "joystick/hidapi/SDL_hidapijoystick.c",
                    "joystick/hidapi/SDL_report_descriptor.c",
                    "joystick/linux/SDL_sysjoystick.c",
                    "haptic/hidapi/SDL_hidapihaptic.c",
                    "haptic/hidapi/SDL_hidapihaptic_lg4ff.c",
                    "thread/pthread/SDL_systhread.c",
                    "thread/pthread/SDL_sysmutex.c",
                    "thread/pthread/SDL_syscond.c",
                    "thread/pthread/SDL_sysrwlock.c",
                    "thread/pthread/SDL_systls.c",
                    "thread/pthread/SDL_syssem.c",
                    "misc/unix/SDL_sysurl.c",
                    "power/linux/SDL_syspower.c",
                    "locale/unix/SDL_syslocale.c",
                    "filesystem/unix/SDL_sysfilesystem.c",
                    "storage/generic/SDL_genericstorage.c",
                    "storage/steam/SDL_steamstorage.c",
                    "filesystem/posix/SDL_sysfsops.c",
                    "time/unix/SDL_systime.c",
                    "timer/unix/SDL_systimer.c",
                    "dialog/unix/SDL_unixdialog.c",
                    "dialog/unix/SDL_portaldialog.c",
                    "dialog/unix/SDL_zenitydialog.c",
                    "dialog/unix/SDL_zenitymessagebox.c",
                    "process/posix/SDL_posixprocess.c",
                    "video/offscreen/SDL_offscreenevents.c",
                    "video/offscreen/SDL_offscreenframebuffer.c",
                    "video/offscreen/SDL_offscreenopengles.c",
                    "video/offscreen/SDL_offscreenvideo.c",
                    "video/offscreen/SDL_offscreenvulkan.c",
                    "video/offscreen/SDL_offscreenwindow.c",
                    "gpu/vulkan/SDL_gpu_vulkan.c",
                    "sensor/dummy/SDL_dummysensor.c",
                    "main/generic/SDL_sysmain_callbacks.c",
                },
            });

            const wayland_protocols = [_][]const u8{
                "alpha-modifier-v1.xml",
                "color-management-v1.xml",
                "cursor-shape-v1.xml",
                "fractional-scale-v1.xml",
                "frog-color-management-v1.xml",
                "idle-inhibit-unstable-v1.xml",
                "input-timestamps-unstable-v1.xml",
                "keyboard-shortcuts-inhibit-unstable-v1.xml",
                "pointer-constraints-unstable-v1.xml",
                "pointer-gestures-unstable-v1.xml",
                "pointer-warp-v1.xml",
                "primary-selection-unstable-v1.xml",
                "relative-pointer-unstable-v1.xml",
                "tablet-v2.xml",
                "text-input-unstable-v3.xml",
                "viewporter.xml",
                "wayland.xml",
                "xdg-activation-v1.xml",
                "xdg-decoration-unstable-v1.xml",
                "xdg-dialog-v1.xml",
                "xdg-foreign-unstable-v2.xml",
                "xdg-output-unstable-v1.xml",
                "xdg-shell.xml",
                "xdg-toplevel-icon-v1.xml",
            };
            const deps = platform.linux_deps.?;
            for (wayland_protocols) |xml_name| {
                const xml = platform.sdl_dep.path(b.pathJoin(&.{ "wayland-protocols", xml_name }));
                const protocol_stem = std.fs.path.stem(xml_name);
                const header_name = b.fmt("{s}-client-protocol.h", .{protocol_stem});
                const source_name = b.fmt("{s}-protocol.c", .{protocol_stem});

                const header_step = b.addSystemCommand(&.{ deps.wayland_scanner, "client-header" });
                header_step.addFileArg(xml);
                const header = header_step.addOutputFileArg(header_name);
                module.addIncludePath(header.dirname());

                const source_step = b.addSystemCommand(&.{ deps.wayland_scanner, deps.wayland_scanner_mode });
                source_step.addFileArg(xml);
                const generated_source = source_step.addOutputFileArg(source_name);
                source_step.step.dependOn(&header_step.step);
                module.addCSourceFile(.{ .file = generated_source, .flags = cflags });
            }
        },
        .windows => {
            module.addCSourceFiles(.{
                .root = sdl_source_lazypath,
                .flags = cflags,
                .files = &.{
                    "audio/dummy/SDL_dummyaudio.c",
                    "audio/disk/SDL_diskaudio.c",
                    "camera/dummy/SDL_camera_dummy.c",
                    "joystick/virtual/SDL_virtualjoystick.c",
                    "video/dummy/SDL_nullevents.c",
                    "video/dummy/SDL_nullframebuffer.c",
                    "video/dummy/SDL_nullvideo.c",
                    "core/windows/SDL_gameinput.cpp",
                    "core/windows/SDL_hid.c",
                    "core/windows/SDL_immdevice.c",
                    "core/windows/SDL_windows.c",
                    "core/windows/SDL_xinput.c",
                    "core/windows/pch.c",
                    "core/windows/pch_cpp.cpp",
                    "main/windows/SDL_sysmain_runapp.c",
                    "io/windows/SDL_asyncio_windows_ioring.c",
                    "misc/windows/SDL_sysurl.c",
                    "audio/directsound/SDL_directsound.c",
                    "audio/wasapi/SDL_wasapi.c",
                    "video/windows/SDL_windowsclipboard.c",
                    "video/windows/SDL_windowsevents.c",
                    "video/windows/SDL_windowsframebuffer.c",
                    "video/windows/SDL_windowsgameinput.cpp",
                    "video/windows/SDL_windowskeyboard.c",
                    "video/windows/SDL_windowsmessagebox.c",
                    "video/windows/SDL_windowsmodes.c",
                    "video/windows/SDL_windowsmouse.c",
                    "video/windows/SDL_windowsopengl.c",
                    "video/windows/SDL_windowsopengles.c",
                    "video/windows/SDL_windowsrawinput.c",
                    "video/windows/SDL_windowsshape.c",
                    "video/windows/SDL_windowsvideo.c",
                    "video/windows/SDL_windowsvulkan.c",
                    "video/windows/SDL_windowswindow.c",
                    "thread/generic/SDL_syscond.c",
                    "thread/generic/SDL_sysrwlock.c",
                    "thread/windows/SDL_syscond_cv.c",
                    "thread/windows/SDL_sysmutex.c",
                    "thread/windows/SDL_sysrwlock_srw.c",
                    "thread/windows/SDL_syssem.c",
                    "thread/windows/SDL_systhread.c",
                    "thread/windows/SDL_systls.c",
                    "sensor/windows/SDL_windowssensor.c",
                    "power/windows/SDL_syspower.c",
                    "locale/windows/SDL_syslocale.c",
                    "filesystem/windows/SDL_sysfilesystem.c",
                    "filesystem/windows/SDL_sysfsops.c",
                    "storage/generic/SDL_genericstorage.c",
                    "storage/steam/SDL_steamstorage.c",
                    "time/windows/SDL_systime.c",
                    "timer/windows/SDL_systimer.c",
                    "loadso/windows/SDL_sysloadso.c",
                    "tray/windows/SDL_tray.c",
                    "joystick/hidapi/SDL_hidapi_8bitdo.c",
                    "joystick/hidapi/SDL_hidapi_combined.c",
                    "joystick/hidapi/SDL_hidapi_flydigi.c",
                    "joystick/hidapi/SDL_hidapi_gamecube.c",
                    "joystick/hidapi/SDL_hidapi_gip.c",
                    "joystick/hidapi/SDL_hidapi_lg4ff.c",
                    "joystick/hidapi/SDL_hidapi_luna.c",
                    "joystick/hidapi/SDL_hidapi_ps3.c",
                    "joystick/hidapi/SDL_hidapi_ps4.c",
                    "joystick/hidapi/SDL_hidapi_ps5.c",
                    "joystick/hidapi/SDL_hidapi_rumble.c",
                    "joystick/hidapi/SDL_hidapi_shield.c",
                    "joystick/hidapi/SDL_hidapi_sinput.c",
                    "joystick/hidapi/SDL_hidapi_stadia.c",
                    "joystick/hidapi/SDL_hidapi_steam.c",
                    "joystick/hidapi/SDL_hidapi_steam_hori.c",
                    "joystick/hidapi/SDL_hidapi_steam_triton.c",
                    "joystick/hidapi/SDL_hidapi_steamdeck.c",
                    "joystick/hidapi/SDL_hidapi_switch.c",
                    "joystick/hidapi/SDL_hidapi_switch2.c",
                    "joystick/hidapi/SDL_hidapi_wii.c",
                    "joystick/hidapi/SDL_hidapi_xbox360.c",
                    "joystick/hidapi/SDL_hidapi_xbox360w.c",
                    "joystick/hidapi/SDL_hidapi_xboxone.c",
                    "joystick/hidapi/SDL_hidapi_zuiki.c",
                    "joystick/hidapi/SDL_hidapijoystick.c",
                    "joystick/hidapi/SDL_report_descriptor.c",
                    "haptic/hidapi/SDL_hidapihaptic.c",
                    "haptic/hidapi/SDL_hidapihaptic_lg4ff.c",
                    "joystick/windows/SDL_dinputjoystick.c",
                    "joystick/windows/SDL_rawinputjoystick.c",
                    "joystick/windows/SDL_windows_gaming_input.c",
                    "joystick/windows/SDL_windowsjoystick.c",
                    "joystick/windows/SDL_xinputjoystick.c",
                    "haptic/windows/SDL_dinputhaptic.c",
                    "haptic/windows/SDL_windowshaptic.c",
                    "camera/mediafoundation/SDL_camera_mediafoundation.c",
                    "dialog/windows/SDL_windowsdialog.c",
                    "process/windows/SDL_windowsprocess.c",
                    "video/offscreen/SDL_offscreenevents.c",
                    "video/offscreen/SDL_offscreenframebuffer.c",
                    "video/offscreen/SDL_offscreenopengles.c",
                    "video/offscreen/SDL_offscreenvideo.c",
                    "video/offscreen/SDL_offscreenvulkan.c",
                    "video/offscreen/SDL_offscreenwindow.c",
                    "gpu/d3d12/SDL_gpu_d3d12.c",
                    "gpu/vulkan/SDL_gpu_vulkan.c",
                    "main/generic/SDL_sysmain_callbacks.c",
                },
            });

            if (platform.target.result.abi == .msvc) {
                module.addCSourceFiles(.{
                    .root = sdl_source_lazypath,
                    .flags = cflags,
                    .files = &.{
                        "joystick/gdk/SDL_gameinputjoystick.cpp",
                    },
                });
            }
            if (platform.sdl_library.linkage.? == .dynamic) {
                module.addWin32ResourceFile(.{ .file = sdl_source_lazypath.path(b, "core/windows/version.rc") });
            }
            module.linkSystemLibrary("kernel32", .{});
            module.linkSystemLibrary("user32", .{});
            module.linkSystemLibrary("gdi32", .{});
            module.linkSystemLibrary("winmm", .{});
            module.linkSystemLibrary("imm32", .{});
            module.linkSystemLibrary("ole32", .{});
            module.linkSystemLibrary("oleaut32", .{});
            module.linkSystemLibrary("version", .{});
            module.linkSystemLibrary("uuid", .{});
            module.linkSystemLibrary("advapi32", .{});
            module.linkSystemLibrary("setupapi", .{});
            module.linkSystemLibrary("shell32", .{});
            module.linkSystemLibrary("dinput8", .{});
            if (platform.target.result.abi == .msvc) {
                module.linkSystemLibrary("oldnames", .{});
            }
        },
        .macos => {
            module.addCSourceFiles(.{
                .root = sdl_source_lazypath,
                .flags = cflags,
                .files = &.{
                    "audio/dummy/SDL_dummyaudio.c",
                    "audio/disk/SDL_diskaudio.c",
                    "camera/dummy/SDL_camera_dummy.c",
                    "loadso/dlopen/SDL_sysloadso.c",
                    "joystick/virtual/SDL_virtualjoystick.c",
                    "video/dummy/SDL_nullevents.c",
                    "video/dummy/SDL_nullframebuffer.c",
                    "video/dummy/SDL_nullvideo.c",
                    "camera/coremedia/SDL_camera_coremedia.m",
                    "misc/macos/SDL_sysurl.m",
                    "audio/coreaudio/SDL_coreaudio.m",
                    "joystick/hidapi/SDL_hidapi_8bitdo.c",
                    "joystick/hidapi/SDL_hidapi_combined.c",
                    "joystick/hidapi/SDL_hidapi_flydigi.c",
                    "joystick/hidapi/SDL_hidapi_gamecube.c",
                    "joystick/hidapi/SDL_hidapi_gip.c",
                    "joystick/hidapi/SDL_hidapi_lg4ff.c",
                    "joystick/hidapi/SDL_hidapi_luna.c",
                    "joystick/hidapi/SDL_hidapi_ps3.c",
                    "joystick/hidapi/SDL_hidapi_ps4.c",
                    "joystick/hidapi/SDL_hidapi_ps5.c",
                    "joystick/hidapi/SDL_hidapi_rumble.c",
                    "joystick/hidapi/SDL_hidapi_shield.c",
                    "joystick/hidapi/SDL_hidapi_sinput.c",
                    "joystick/hidapi/SDL_hidapi_stadia.c",
                    "joystick/hidapi/SDL_hidapi_steam.c",
                    "joystick/hidapi/SDL_hidapi_steam_hori.c",
                    "joystick/hidapi/SDL_hidapi_steam_triton.c",
                    "joystick/hidapi/SDL_hidapi_steamdeck.c",
                    "joystick/hidapi/SDL_hidapi_switch.c",
                    "joystick/hidapi/SDL_hidapi_switch2.c",
                    "joystick/hidapi/SDL_hidapi_wii.c",
                    "joystick/hidapi/SDL_hidapi_xbox360.c",
                    "joystick/hidapi/SDL_hidapi_xbox360w.c",
                    "joystick/hidapi/SDL_hidapi_xboxone.c",
                    "joystick/hidapi/SDL_hidapi_zuiki.c",
                    "joystick/hidapi/SDL_hidapijoystick.c",
                    "joystick/hidapi/SDL_report_descriptor.c",
                    "haptic/hidapi/SDL_hidapihaptic.c",
                    "haptic/hidapi/SDL_hidapihaptic_lg4ff.c",
                    "joystick/apple/SDL_mfijoystick.m",
                    "joystick/darwin/SDL_iokitjoystick.c",
                    "haptic/darwin/SDL_syshaptic.c",
                    "power/macos/SDL_syspower.c",
                    "locale/macos/SDL_syslocale.m",
                    "time/unix/SDL_systime.c",
                    "timer/unix/SDL_systimer.c",
                    "filesystem/cocoa/SDL_sysfilesystem.m",
                    "storage/generic/SDL_genericstorage.c",
                    "storage/steam/SDL_steamstorage.c",
                    "filesystem/posix/SDL_sysfsops.c",
                    "video/cocoa/SDL_cocoaclipboard.m",
                    "video/cocoa/SDL_cocoaevents.m",
                    "video/cocoa/SDL_cocoakeyboard.m",
                    "video/cocoa/SDL_cocoamessagebox.m",
                    "video/cocoa/SDL_cocoametalview.m",
                    "video/cocoa/SDL_cocoamodes.m",
                    "video/cocoa/SDL_cocoamouse.m",
                    "video/cocoa/SDL_cocoaopengl.m",
                    "video/cocoa/SDL_cocoaopengles.m",
                    "video/cocoa/SDL_cocoapen.m",
                    "video/cocoa/SDL_cocoashape.m",
                    "video/cocoa/SDL_cocoavideo.m",
                    "video/cocoa/SDL_cocoavulkan.m",
                    "video/cocoa/SDL_cocoawindow.m",
                    "render/metal/SDL_render_metal.m",
                    "gpu/metal/SDL_gpu_metal.m",
                    "tray/cocoa/SDL_tray.m",
                    "thread/pthread/SDL_systhread.c",
                    "thread/pthread/SDL_sysmutex.c",
                    "thread/pthread/SDL_syscond.c",
                    "thread/pthread/SDL_sysrwlock.c",
                    "thread/pthread/SDL_systls.c",
                    "thread/pthread/SDL_syssem.c",
                    "dialog/cocoa/SDL_cocoadialog.m",
                    "process/posix/SDL_posixprocess.c",
                    "video/offscreen/SDL_offscreenevents.c",
                    "video/offscreen/SDL_offscreenframebuffer.c",
                    "video/offscreen/SDL_offscreenopengles.c",
                    "video/offscreen/SDL_offscreenvideo.c",
                    "video/offscreen/SDL_offscreenvulkan.c",
                    "video/offscreen/SDL_offscreenwindow.c",
                    "gpu/vulkan/SDL_gpu_vulkan.c",
                    "sensor/dummy/SDL_dummysensor.c",
                    "main/generic/SDL_sysmain_callbacks.c",
                },
            });

            module.linkFramework("CoreMedia", .{});
            module.linkFramework("CoreVideo", .{});
            module.linkFramework("Cocoa", .{});
            module.linkFramework("UniformTypeIdentifiers", .{ .weak = true });
            module.linkFramework("IOKit", .{});
            module.linkFramework("ForceFeedback", .{});
            module.linkFramework("Carbon", .{});
            module.linkFramework("CoreAudio", .{});
            module.linkFramework("AudioToolbox", .{});
            module.linkFramework("AVFoundation", .{});
            module.linkFramework("Foundation", .{});
            module.linkFramework("GameController", .{});
            module.linkFramework("Metal", .{});
            module.linkFramework("QuartzCore", .{});
            module.linkFramework("CoreHaptics", .{ .weak = true });
        },
        .emscripten => {
            module.addCSourceFiles(.{
                .root = sdl_source_lazypath,
                .flags = cflags,
                .files = &.{
                    "audio/dummy/SDL_dummyaudio.c",
                    "audio/disk/SDL_diskaudio.c",
                    "camera/dummy/SDL_camera_dummy.c",
                    "loadso/dlopen/SDL_sysloadso.c",
                    "joystick/virtual/SDL_virtualjoystick.c",
                    "video/dummy/SDL_nullevents.c",
                    "video/dummy/SDL_nullframebuffer.c",
                    "video/dummy/SDL_nullvideo.c",
                    "main/emscripten/SDL_sysmain_callbacks.c",
                    "main/emscripten/SDL_sysmain_runapp.c",
                    "misc/emscripten/SDL_sysurl.c",
                    "audio/emscripten/SDL_emscriptenaudio.c",
                    "filesystem/emscripten/SDL_sysfilesystem.c",
                    "filesystem/posix/SDL_sysfsops.c",
                    "camera/emscripten/SDL_camera_emscripten.c",
                    "joystick/emscripten/SDL_sysjoystick.c",
                    "power/emscripten/SDL_syspower.c",
                    "locale/emscripten/SDL_syslocale.c",
                    "time/unix/SDL_systime.c",
                    "timer/unix/SDL_systimer.c",
                    "sensor/emscripten/SDL_emscriptensensor.c",
                    "video/emscripten/SDL_emscriptenevents.c",
                    "video/emscripten/SDL_emscriptenframebuffer.c",
                    "video/emscripten/SDL_emscriptenmouse.c",
                    "video/emscripten/SDL_emscriptenopengles.c",
                    "video/emscripten/SDL_emscriptenvideo.c",
                    "dialog/unix/SDL_unixdialog.c",
                    "dialog/unix/SDL_portaldialog.c",
                    "dialog/unix/SDL_zenitydialog.c",
                    "dialog/unix/SDL_zenitymessagebox.c",
                    "video/offscreen/SDL_offscreenevents.c",
                    "video/offscreen/SDL_offscreenframebuffer.c",
                    "video/offscreen/SDL_offscreenopengles.c",
                    "video/offscreen/SDL_offscreenvideo.c",
                    "video/offscreen/SDL_offscreenvulkan.c",
                    "video/offscreen/SDL_offscreenwindow.c",
                    "haptic/dummy/SDL_syshaptic.c",
                    "storage/generic/SDL_genericstorage.c",
                    "process/dummy/SDL_dummyprocess.c",
                    "tray/dummy/SDL_tray.c",
                },
            });
            if (platform.emscripten_pthreads) {
                module.addCSourceFiles(.{
                    .root = sdl_source_lazypath,
                    .flags = cflags,
                    .files = &.{
                        "thread/pthread/SDL_systhread.c",
                        "thread/pthread/SDL_sysmutex.c",
                        "thread/pthread/SDL_syscond.c",
                        "thread/pthread/SDL_sysrwlock.c",
                        "thread/pthread/SDL_systls.c",
                        "thread/pthread/SDL_syssem.c",
                    },
                });
            } else {
                module.addCSourceFiles(.{
                    .root = sdl_source_lazypath,
                    .flags = cflags,
                    .files = &.{
                        "thread/generic/SDL_systhread.c",
                        "thread/generic/SDL_sysmutex.c",
                        "thread/generic/SDL_syscond.c",
                        "thread/generic/SDL_sysrwlock.c",
                        "thread/generic/SDL_systls.c",
                        "thread/generic/SDL_syssem.c",
                    },
                });
            }
        },
        else => @panic("unsupported SDL target platform"),
    }

    if (platform.sdl_library.linkage.? == .dynamic) {
        platform.sdl_library.setVersionScript(sdl_source_lazypath.path(b, "dynapi/SDL_dynapi.sym"));
        platform.sdl_library.linker_allow_undefined_version = true;
    }
}
