const std = @import("std");
const uri = std.Uri.parse(@import("build.zig.zon").dependencies.sdl3.url) catch unreachable;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl_dep = b.lazyDependency("sdl3", .{}) orelse @panic("null sdl3 lazy dependency");
    const include = sdl_dep.path("include");
    const source = sdl_dep.path("src");

    const preferred_linkage = b.option(std.builtin.LinkMode, "preferred_linkage", "SDL linkage") orelse .static;

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
    const emscripten_pthreads = b.option(
        bool,
        "emscripten_pthreads",
        "Build with pthreads support when targeting Emscripten (default: false)",
    ) orelse false;
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

    var windows = false;
    var linux = false;
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
            .HAVE_GCC_SYNC_LOCK_TEST_AND_SET = false, // MARK
            .SDL_DISABLE_ALLOCA = false, // MARK
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
            .HAVE_PTHREAD_NP_H = false, // MARK
            .HAVE_DLOPEN = linux or macos or emscripten,
            .HAVE_MALLOC = windows or linux or macos or emscripten,
            .HAVE_FDATASYNC = linux or emscripten,
            .HAVE_GETENV = windows or linux or macos or emscripten,
            .HAVE_GETHOSTNAME = linux or macos or emscripten,
            .HAVE_SETENV = linux or macos or emscripten,
            .HAVE_PUTENV = windows or linux or macos or emscripten,
            .HAVE_UNSETENV = linux or macos or emscripten,
            .HAVE_ABS = windows or linux or macos or emscripten, // MARK
            .HAVE_BCOPY = linux or macos or emscripten, // MARK
            .HAVE_MEMSET = windows or linux or macos or emscripten,
            .HAVE_MEMCPY = windows or linux or macos or emscripten,
            .HAVE_MEMMOVE = windows or linux or macos or emscripten,
            .HAVE_MEMCMP = windows or linux or macos or emscripten,
            .HAVE_WCSLEN = windows or linux or macos or emscripten, // MARK
            .HAVE_WCSNLEN = windows or linux or macos or emscripten, // MARK
            .HAVE_WCSLCPY = macos, // MARK
            .HAVE_WCSLCAT = macos, // MARK
            .HAVE_WCSSTR = windows or linux or macos or emscripten, // MARK
            .HAVE_WCSCMP = windows or linux or macos or emscripten, // MARK
            .HAVE_WCSNCMP = windows or linux or macos or emscripten, // MARK
            .HAVE_WCSTOL = windows or linux or macos or emscripten, // MARK
            .HAVE_STRLEN = windows or linux or macos or emscripten,
            .HAVE_STRNLEN = windows or linux or macos or emscripten, // MARK
            .HAVE_STRLCPY = (linux and musl) or macos or emscripten, // MARK
            .HAVE_STRLCAT = (linux and musl) or macos or emscripten, // MARK
            .HAVE_STRPBRK = windows or linux or macos or emscripten, // MARK
            .HAVE__STRREV = windows, // MARK
            .HAVE_INDEX = linux or macos or emscripten, // MARK
            .HAVE_RINDEX = linux or macos or emscripten, // MARK
            .HAVE_STRCHR = windows or linux or macos or emscripten,
            .HAVE_STRRCHR = windows or linux or macos or emscripten,
            .HAVE_STRSTR = windows or linux or macos or emscripten,
            .HAVE_STRNSTR = macos, // MARK
            .HAVE_STRTOK_R = (windows and !msvc) or linux or macos or emscripten,
            .HAVE_ITOA = windows, // MARK
            .HAVE__LTOA = windows, // MARK
            .HAVE__ULTOA = windows, // MARK
            .HAVE_STRTOL = windows or linux or macos or emscripten,
            .HAVE_STRTOUL = windows or linux or macos or emscripten,
            .HAVE__I64TOA = windows, // MARK
            .HAVE__UI64TOA = windows, // MARK
            .HAVE_STRTOLL = windows or linux or macos or emscripten,
            .HAVE_STRTOULL = windows or linux or macos or emscripten,
            .HAVE_STRTOD = windows or linux or macos or emscripten,
            .HAVE_ATOI = windows or linux or macos or emscripten,
            .HAVE_ATOF = windows or linux or macos or emscripten,
            .HAVE_STRCMP = windows or linux or macos or emscripten,
            .HAVE_STRNCMP = windows or linux or macos or emscripten,
            .HAVE_VSSCANF = windows or linux or macos or emscripten,
            .HAVE_VSNPRINTF = windows or linux or macos or emscripten,
            .HAVE_ACOS = windows or linux or macos or emscripten, // MARK
            .HAVE_ACOSF = windows or linux or macos or emscripten, // MARK
            .HAVE_ASIN = windows or linux or macos or emscripten, // MARK
            .HAVE_ASINF = windows or linux or macos or emscripten, // MARK
            .HAVE_ATAN = windows or linux or macos or emscripten, // MARK
            .HAVE_ATANF = windows or linux or macos or emscripten, // MARK
            .HAVE_ATAN2 = windows or linux or macos or emscripten, // MARK
            .HAVE_ATAN2F = windows or linux or macos or emscripten, // MARK
            .HAVE_CEIL = windows or linux or macos or emscripten,
            .HAVE_CEILF = windows or linux or macos or emscripten,
            .HAVE_COPYSIGN = windows or linux or macos or emscripten, // MARK
            .HAVE_COPYSIGNF = windows or linux or macos or emscripten, // MARK
            .HAVE__COPYSIGN = windows, // MARK
            .HAVE_COS = windows or linux or macos or emscripten,
            .HAVE_COSF = windows or linux or macos or emscripten,
            .HAVE_EXP = windows or linux or macos or emscripten,
            .HAVE_EXPF = windows or linux or macos or emscripten,
            .HAVE_FABS = windows or linux or macos or emscripten,
            .HAVE_FABSF = windows or linux or macos or emscripten,
            .HAVE_FLOOR = windows or linux or macos or emscripten,
            .HAVE_FLOORF = windows or linux or macos or emscripten,
            .HAVE_FMOD = windows or linux or macos or emscripten, // MARK
            .HAVE_FMODF = windows or linux or macos or emscripten, // MARK
            .HAVE_ISINF = windows or linux or macos or emscripten,
            .HAVE_ISINFF = (linux and !musl) or emscripten, // MARK
            .HAVE_ISINF_FLOAT_MACRO = windows or linux or macos or emscripten, // MARK
            .HAVE_ISNAN = windows or linux or macos or emscripten,
            .HAVE_ISNANF = (linux and !musl) or emscripten, // MARK
            .HAVE_ISNAN_FLOAT_MACRO = windows or linux or macos or emscripten, // MARK
            .HAVE_LOG = windows or linux or macos or emscripten,
            .HAVE_LOGF = windows or linux or macos or emscripten,
            .HAVE_LOG10 = windows or linux or macos or emscripten, // MARK
            .HAVE_LOG10F = windows or linux or macos or emscripten, // MARK
            .HAVE_LROUND = windows or linux or macos or emscripten, // MARK
            .HAVE_LROUNDF = windows or linux or macos or emscripten, // MARK
            .HAVE_MODF = windows or linux or macos or emscripten, // MARK
            .HAVE_MODFF = windows or linux or macos or emscripten, // MARK
            .HAVE_POW = windows or linux or macos or emscripten, // MARK
            .HAVE_POWF = windows or linux or macos or emscripten, // MARK
            .HAVE_ROUND = windows or linux or macos or emscripten, // MARK
            .HAVE_ROUNDF = windows or linux or macos or emscripten, // MARK
            .HAVE_SCALBN = windows or linux or macos or emscripten, // MARK
            .HAVE_SCALBNF = windows or linux or macos or emscripten, // MARK
            .HAVE_SIN = windows or linux or macos or emscripten,
            .HAVE_SINF = windows or linux or macos or emscripten,
            .HAVE_SQRT = windows or linux or macos or emscripten,
            .HAVE_SQRTF = windows or linux or macos or emscripten,
            .HAVE_TAN = windows or linux or macos or emscripten,
            .HAVE_TANF = windows or linux or macos or emscripten,
            .HAVE_TRUNC = windows or linux or macos or emscripten, // MARK
            .HAVE_TRUNCF = windows or linux or macos or emscripten, // MARK
            .HAVE__FSEEKI64 = windows, // MARK
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
            .HAVE_SYSCTLBYNAME = macos, // MARK
            .HAVE_CLOCK_GETTIME = linux or emscripten,
            .HAVE_GETPAGESIZE = linux or macos or emscripten,
            .HAVE_ICONV = linux or emscripten,
            .SDL_USE_LIBICONV = false, // MARK
            .HAVE_PTHREAD_SETNAME_NP = linux or macos,
            .HAVE_PTHREAD_SET_NAME_NP = false, // MARK
            .HAVE_SEM_TIMEDWAIT = linux or (emscripten and emscripten_pthreads),
            .HAVE_GETAUXVAL = linux,
            .HAVE_ELF_AUX_INFO = false, // MARK
            .HAVE_PPOLL = linux,
            .HAVE__EXIT = windows or linux or macos or emscripten,
            .HAVE_GETRESUID = linux or emscripten,
            .HAVE_GETRESGID = linux or emscripten,
            .HAVE_DBUS_DBUS_H = linux, // MARK
            .HAVE_FCITX = linux, // MARK
            .HAVE_IBUS_IBUS_H = linux, // MARK
            .HAVE_INOTIFY_INIT1 = linux, // MARK
            .HAVE_INOTIFY = linux, // MARK
            .HAVE_LIBUSB = linux, // MARK
            .HAVE_O_CLOEXEC = linux or macos or emscripten,
            .HAVE_LINUX_INPUT_H = linux,
            .HAVE_LIBUDEV_H = linux, // MARK
            .HAVE_LIBDECOR_H = linux, // MARK
            .HAVE_LIBURING_H = linux, // MARK
            .HAVE_FRIBIDI_H = linux, // MARK
            .SDL_FRIBIDI_DYNAMIC = if (target.result.os.tag == .linux) "\"libfribidi.so.0\"" else "",
            .HAVE_LIBTHAI_H = linux, // MARK
            .SDL_LIBTHAI_DYNAMIC = if (target.result.os.tag == .linux) "\"libthai.so.0\"" else "",
            .HAVE_DDRAW_H = windows, // MARK
            .HAVE_DSOUND_H = windows, // MARK
            .HAVE_DINPUT_H = windows, // MARK
            .HAVE_XINPUT_H = windows, // MARK
            .HAVE_WINDOWS_GAMING_INPUT_H = false, // MARK
            .HAVE_GAMEINPUT_H = (windows and msvc), // MARK
            .HAVE_DXGI_H = windows, // MARK
            .HAVE_DXGI1_5_H = windows, // MARK
            .HAVE_DXGI1_6_H = windows, // MARK
            .HAVE_MMDEVICEAPI_H = windows, // MARK
            .HAVE_TPCSHRD_H = windows, // MARK
            .HAVE_ROAPI_H = (windows and !msvc), // MARK
            .HAVE_SHELLSCALINGAPI_H = windows, // MARK
            .USE_POSIX_SPAWN = false, // MARK
            .HAVE_POSIX_SPAWN_FILE_ACTIONS_ADDCHDIR = macos, // MARK
            .HAVE_POSIX_SPAWN_FILE_ACTIONS_ADDCHDIR_NP = linux or macos or emscripten, // MARK
            .SDL_DISABLE_DLOPEN_NOTES = false, // MARK
            .SDL_DEFAULT_ASSERT_LEVEL_CONFIGURED = false, // MARK
            .SDL_DEFAULT_ASSERT_LEVEL = null,
            .SDL_AUDIO_DISABLED = false, // MARK
            .SDL_VIDEO_DISABLED = false, // MARK
            .SDL_GPU_DISABLED = false, // MARK
            .SDL_RENDER_DISABLED = false, // MARK
            .SDL_CAMERA_DISABLED = false, // MARK
            .SDL_JOYSTICK_DISABLED = false, // MARK
            .SDL_HAPTIC_DISABLED = false, // MARK
            .SDL_HIDAPI_DISABLED = false, // MARK
            .SDL_POWER_DISABLED = false, // MARK
            .SDL_SENSOR_DISABLED = false, // MARK
            .SDL_DIALOG_DISABLED = false, // MARK
            .SDL_THREADS_DISABLED = (emscripten and !emscripten_pthreads), // MARK
            .SDL_AUDIO_DRIVER_ALSA = linux,
            .SDL_AUDIO_DRIVER_ALSA_DYNAMIC = if (target.result.os.tag == .linux) "\"libasound.so.2\"" else "",
            .SDL_AUDIO_DRIVER_OPENSLES = false, // MARK
            .SDL_AUDIO_DRIVER_AAUDIO = false, // MARK
            .SDL_AUDIO_DRIVER_COREAUDIO = macos,
            .SDL_AUDIO_DRIVER_DISK = windows or linux or macos or emscripten,
            .SDL_AUDIO_DRIVER_DSOUND = windows, // MARK
            .SDL_AUDIO_DRIVER_DUMMY = windows or linux or macos or emscripten,
            .SDL_AUDIO_DRIVER_EMSCRIPTEN = emscripten, // MARK
            .SDL_AUDIO_DRIVER_HAIKU = false, // MARK
            .SDL_AUDIO_DRIVER_JACK = linux, // MARK
            .SDL_AUDIO_DRIVER_JACK_DYNAMIC = if (target.result.os.tag == .linux) "\"libjack.so.0\"" else "",
            .SDL_AUDIO_DRIVER_NETBSD = false,
            .SDL_AUDIO_DRIVER_OSS = false,
            .SDL_AUDIO_DRIVER_PIPEWIRE = linux, // MARK
            .SDL_AUDIO_DRIVER_PIPEWIRE_DYNAMIC = if (target.result.os.tag == .linux) "\"libpipewire-0.3.so.0\"" else "",
            .SDL_AUDIO_DRIVER_PULSEAUDIO = linux, // MARK
            .SDL_AUDIO_DRIVER_PULSEAUDIO_DYNAMIC = if (target.result.os.tag == .linux) "\"libpulse.so.0\"" else "",
            .SDL_AUDIO_DRIVER_SNDIO = linux, // MARK
            .SDL_AUDIO_DRIVER_SNDIO_DYNAMIC = if (target.result.os.tag == .linux) "\"libsndio.so.7\"" else "",
            .SDL_AUDIO_DRIVER_WASAPI = windows, // MARK
            .SDL_AUDIO_DRIVER_VITA = false, // MARK
            .SDL_AUDIO_DRIVER_PSP = false, // MARK
            .SDL_AUDIO_DRIVER_PS2 = false, // MARK
            .SDL_AUDIO_DRIVER_N3DS = false, // MARK
            .SDL_AUDIO_DRIVER_NGAGE = false, // MARK
            .SDL_AUDIO_DRIVER_QNX = false, // MARK
            .SDL_AUDIO_DRIVER_PRIVATE = false, // MARK
            .SDL_INPUT_LINUXEV = linux,
            .SDL_INPUT_LINUXKD = linux,
            .SDL_INPUT_FBSDKBIO = false, // MARK
            .SDL_INPUT_WSCONS = false, // MARK
            .SDL_HAVE_MACHINE_JOYSTICK_H = false, // MARK
            .SDL_JOYSTICK_ANDROID = false, // MARK
            .SDL_JOYSTICK_DINPUT = windows, // MARK
            .SDL_JOYSTICK_DUMMY = false, // MARK
            .SDL_JOYSTICK_EMSCRIPTEN = emscripten, // MARK
            .SDL_JOYSTICK_GAMEINPUT = (windows and msvc), // MARK
            .SDL_JOYSTICK_HAIKU = false, // MARK
            .SDL_JOYSTICK_HIDAPI = windows or linux or macos,
            .SDL_JOYSTICK_IOKIT = macos, // MARK
            .SDL_JOYSTICK_LINUX = linux,
            .SDL_JOYSTICK_MFI = macos, // MARK
            .SDL_JOYSTICK_N3DS = false, // MARK
            .SDL_JOYSTICK_PS2 = false, // MARK
            .SDL_JOYSTICK_PSP = false, // MARK
            .SDL_JOYSTICK_RAWINPUT = windows, // MARK
            .SDL_JOYSTICK_USBHID = false, // MARK
            .SDL_JOYSTICK_VIRTUAL = windows or linux or macos or emscripten,
            .SDL_JOYSTICK_VITA = false, // MARK
            .SDL_JOYSTICK_WGI = false, // MARK
            .SDL_JOYSTICK_XINPUT = windows, // MARK
            .SDL_JOYSTICK_PRIVATE = false, // MARK
            .SDL_HAPTIC_DUMMY = emscripten, // MARK
            .SDL_HAPTIC_LINUX = linux,
            .SDL_HAPTIC_IOKIT = macos, // MARK
            .SDL_HAPTIC_DINPUT = windows,
            .SDL_HAPTIC_ANDROID = false, // MARK
            .SDL_HAPTIC_PRIVATE = false, // MARK
            .SDL_LIBUSB_DYNAMIC = if (target.result.os.tag == .linux) "\"libusb-1.0.so.0\"" else "",
            .SDL_UDEV_DYNAMIC = if (target.result.os.tag == .linux) "\"libudev.so.1\"" else "",
            .SDL_PROCESS_DUMMY = emscripten, // MARK
            .SDL_PROCESS_POSIX = linux or macos,
            .SDL_PROCESS_WINDOWS = windows,
            .SDL_PROCESS_PRIVATE = false, // MARK
            .SDL_SENSOR_ANDROID = false, // MARK
            .SDL_SENSOR_COREMOTION = false, // MARK
            .SDL_SENSOR_WINDOWS = windows,
            .SDL_SENSOR_DUMMY = linux or macos,
            .SDL_SENSOR_VITA = false, // MARK
            .SDL_SENSOR_N3DS = false, // MARK
            .SDL_SENSOR_EMSCRIPTEN = emscripten, // MARK
            .SDL_SENSOR_PRIVATE = false, // MARK
            .SDL_LOADSO_DLOPEN = linux or macos or emscripten,
            .SDL_LOADSO_DUMMY = false, // MARK
            .SDL_LOADSO_WINDOWS = windows,
            .SDL_LOADSO_PRIVATE = false, // MARK
            .SDL_THREAD_GENERIC_COND_SUFFIX = windows,
            .SDL_THREAD_GENERIC_RWLOCK_SUFFIX = windows,
            .SDL_THREAD_PTHREAD = linux or macos or (emscripten and emscripten_pthreads),
            .SDL_THREAD_PTHREAD_RECURSIVE_MUTEX = linux or macos or (emscripten and emscripten_pthreads),
            .SDL_THREAD_PTHREAD_RECURSIVE_MUTEX_NP = false, // MARK
            .SDL_THREAD_WINDOWS = windows,
            .SDL_THREAD_VITA = false, // MARK
            .SDL_THREAD_PSP = false, // MARK
            .SDL_THREAD_PS2 = false, // MARK
            .SDL_THREAD_N3DS = false, // MARK
            .SDL_THREAD_PRIVATE = false, // MARK
            .SDL_TIME_UNIX = linux or macos or emscripten,
            .SDL_TIME_WINDOWS = windows,
            .SDL_TIME_VITA = false, // MARK
            .SDL_TIME_PSP = false, // MARK
            .SDL_TIME_PS2 = false, // MARK
            .SDL_TIME_N3DS = false, // MARK
            .SDL_TIME_NGAGE = false, // MARK
            .SDL_TIME_PRIVATE = false, // MARK
            .SDL_TIMER_HAIKU = false, // MARK
            .SDL_TIMER_UNIX = linux or macos or emscripten,
            .SDL_TIMER_WINDOWS = windows,
            .SDL_TIMER_VITA = false, // MARK
            .SDL_TIMER_PSP = false, // MARK
            .SDL_TIMER_PS2 = false, // MARK
            .SDL_TIMER_N3DS = false, // MARK
            .SDL_TIMER_PRIVATE = false, // MARK
            .SDL_VIDEO_DRIVER_ANDROID = false, // MARK
            .SDL_VIDEO_DRIVER_COCOA = macos,
            .SDL_VIDEO_DRIVER_DUMMY = windows or linux or macos or emscripten,
            .SDL_VIDEO_DRIVER_EMSCRIPTEN = emscripten, // MARK
            .SDL_VIDEO_DRIVER_HAIKU = false, // MARK
            .SDL_VIDEO_DRIVER_KMSDRM = linux, // MARK
            .SDL_VIDEO_DRIVER_KMSDRM_DYNAMIC = if (target.result.os.tag == .linux) "\"libdrm.so.2\"" else "",
            .SDL_VIDEO_DRIVER_KMSDRM_DYNAMIC_GBM = if (target.result.os.tag == .linux) "\"libgbm.so.1\"" else "",
            .SDL_VIDEO_DRIVER_N3DS = false, // MARK65
            .SDL_VIDEO_DRIVER_NGAGE = false, // MARK65
            .SDL_VIDEO_DRIVER_OFFSCREEN = windows or linux or macos or emscripten,
            .SDL_VIDEO_DRIVER_PS2 = false, // MARK
            .SDL_VIDEO_DRIVER_PSP = false, // MARK
            .SDL_VIDEO_DRIVER_RISCOS = false, // MARK
            .SDL_VIDEO_DRIVER_ROCKCHIP = false, // MARK
            .SDL_VIDEO_DRIVER_RPI = false, // MARK
            .SDL_VIDEO_DRIVER_UIKIT = false, // MARK
            .SDL_VIDEO_DRIVER_VITA = false, // MARK
            .SDL_VIDEO_DRIVER_VIVANTE = false, // MARK
            .SDL_VIDEO_DRIVER_VIVANTE_VDK = false, // MARK
            .SDL_VIDEO_DRIVER_OPENVR = false, // MARK
            .SDL_VIDEO_DRIVER_WAYLAND = linux,
            .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC = if (target.result.os.tag == .linux) "\"libwayland-client.so.0\"" else "",
            .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_CURSOR = if (target.result.os.tag == .linux) "\"libwayland-cursor.so.0\"" else "",
            .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_EGL = if (target.result.os.tag == .linux) "\"libwayland-egl.so.1\"" else "",
            .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_LIBDECOR = if (target.result.os.tag == .linux) "\"libdecor-0.so.0\"" else "",
            .SDL_VIDEO_DRIVER_WAYLAND_DYNAMIC_XKBCOMMON = if (target.result.os.tag == .linux) "\"libxkbcommon.so.0\"" else "",
            .SDL_VIDEO_DRIVER_WINDOWS = windows,
            .SDL_VIDEO_DRIVER_X11 = linux,
            .SDL_VIDEO_DRIVER_X11_DYNAMIC = if (target.result.os.tag == .linux) "\"libX11.so.6\"" else "",
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XCURSOR = if (target.result.os.tag == .linux) "\"libXcursor.so.1\"" else "",
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XEXT = if (target.result.os.tag == .linux) "\"libXext.so.6\"" else "",
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XFIXES = if (target.result.os.tag == .linux) "\"libXfixes.so.3\"" else "",
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XINPUT2 = if (target.result.os.tag == .linux) "\"libXi.so.6\"" else "",
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XRANDR = if (target.result.os.tag == .linux) "\"libXrandr.so.2\"" else "",
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XSS = if (target.result.os.tag == .linux) "\"libXss.so.1\"" else "",
            .SDL_VIDEO_DRIVER_X11_DYNAMIC_XTEST = if (target.result.os.tag == .linux) "\"libXtst.so.6\"" else "",
            .SDL_VIDEO_DRIVER_X11_HAS_XKBLIB = linux, // MARK
            .SDL_VIDEO_DRIVER_X11_SUPPORTS_GENERIC_EVENTS = linux, // MARK
            .SDL_VIDEO_DRIVER_X11_XCURSOR = linux, // MARK
            .SDL_VIDEO_DRIVER_X11_XDBE = linux, // MARK
            .SDL_VIDEO_DRIVER_X11_XFIXES = linux, // MARK
            .SDL_VIDEO_DRIVER_X11_XINPUT2 = linux, // MARK
            .SDL_VIDEO_DRIVER_X11_XINPUT2_SUPPORTS_MULTITOUCH = linux, // MARK
            .SDL_VIDEO_DRIVER_X11_XINPUT2_SUPPORTS_SCROLLINFO = linux, // MARK
            .SDL_VIDEO_DRIVER_X11_XINPUT2_SUPPORTS_GESTURE = linux,
            .SDL_VIDEO_DRIVER_X11_XRANDR = linux, // MARK
            .SDL_VIDEO_DRIVER_X11_XSCRNSAVER = linux, // MARK
            .SDL_VIDEO_DRIVER_X11_XSHAPE = linux, // MARK
            .SDL_VIDEO_DRIVER_X11_XSYNC = linux, // MARK
            .SDL_VIDEO_DRIVER_X11_XTEST = linux, // MARK
            .SDL_VIDEO_DRIVER_QNX = false, // MARK
            .SDL_VIDEO_DRIVER_PRIVATE = false, // MARK
            .SDL_VIDEO_RENDER_D3D = windows, // MARK
            .SDL_VIDEO_RENDER_D3D11 = windows, // MARK
            .SDL_VIDEO_RENDER_D3D12 = windows, // MARK
            .SDL_VIDEO_RENDER_GPU = windows or linux or macos,
            .SDL_VIDEO_RENDER_METAL = macos, // MARK
            .SDL_VIDEO_RENDER_VULKAN = windows or linux or macos,
            .SDL_VIDEO_RENDER_OGL = windows or linux or macos,
            .SDL_VIDEO_RENDER_OGL_ES2 = windows or linux or macos or emscripten, // MARK
            .SDL_VIDEO_RENDER_NGAGE = false, // MARK
            .SDL_VIDEO_RENDER_PS2 = false, // MARK
            .SDL_VIDEO_RENDER_PSP = false, // MARK
            .SDL_VIDEO_RENDER_VITA_GXM = false, // MARK
            .SDL_VIDEO_RENDER_PRIVATE = false, // MARK
            .SDL_VIDEO_OPENGL = windows or linux or macos,
            .SDL_VIDEO_OPENGL_ES = linux, // MARK
            .SDL_VIDEO_OPENGL_ES2 = windows or linux or macos or emscripten, // MARK
            .SDL_VIDEO_OPENGL_CGL = macos, // MARK
            .SDL_VIDEO_OPENGL_GLX = linux,
            .SDL_VIDEO_OPENGL_WGL = windows, // MARK
            .SDL_VIDEO_OPENGL_EGL = windows or linux or macos,
            .SDL_VIDEO_STATIC_ANGLE = false, // MARK
            .SDL_VIDEO_VULKAN = windows or linux or macos,
            .SDL_VIDEO_METAL = macos, // MARK
            .SDL_GPU_D3D11 = false, // MARK
            .SDL_GPU_D3D12 = windows, // MARK
            .SDL_GPU_VULKAN = windows or linux or macos, // MARK
            .SDL_GPU_METAL = macos, // MARK
            .SDL_GPU_PRIVATE = false, // MARK
            .SDL_POWER_ANDROID = false, // MARK
            .SDL_POWER_LINUX = linux,
            .SDL_POWER_WINDOWS = windows,
            .SDL_POWER_MACOSX = macos,
            .SDL_POWER_UIKIT = false, // MARK
            .SDL_POWER_HAIKU = false, // MARK
            .SDL_POWER_EMSCRIPTEN = emscripten, // MARK
            .SDL_POWER_HARDWIRED = false, // MARK
            .SDL_POWER_VITA = false, // MARK
            .SDL_POWER_PSP = false, // MARK
            .SDL_POWER_N3DS = false, // MARK
            .SDL_POWER_PRIVATE = false, // MARK
            .SDL_FILESYSTEM_ANDROID = false, // MARK
            .SDL_FILESYSTEM_HAIKU = false, // MARK
            .SDL_FILESYSTEM_COCOA = macos, // MARK
            .SDL_FILESYSTEM_DUMMY = false, // MARK
            .SDL_FILESYSTEM_RISCOS = false, // MARK
            .SDL_FILESYSTEM_UNIX = linux,
            .SDL_FILESYSTEM_WINDOWS = windows,
            .SDL_FILESYSTEM_EMSCRIPTEN = emscripten, // MARK
            .SDL_FILESYSTEM_VITA = false, // MARK
            .SDL_FILESYSTEM_PSP = false, // MARK
            .SDL_FILESYSTEM_PS2 = false, // MARK
            .SDL_FILESYSTEM_N3DS = false, // MARK
            .SDL_FILESYSTEM_PRIVATE = false, // MARK
            .SDL_STORAGE_STEAM = windows or linux or macos,
            .SDL_STORAGE_PRIVATE = false, // MARK
            .SDL_FSOPS_POSIX = linux or macos or emscripten,
            .SDL_FSOPS_WINDOWS = windows,
            .SDL_FSOPS_DUMMY = false, // MARK
            .SDL_FSOPS_PRIVATE = false, // MARK
            .SDL_CAMERA_DRIVER_DUMMY = windows or linux or macos or emscripten,
            .SDL_CAMERA_DRIVER_V4L2 = linux,
            .SDL_CAMERA_DRIVER_COREMEDIA = macos, // MARK
            .SDL_CAMERA_DRIVER_ANDROID = false, // MARK
            .SDL_CAMERA_DRIVER_EMSCRIPTEN = emscripten, // MARK
            .SDL_CAMERA_DRIVER_MEDIAFOUNDATION = windows, // MARK
            .SDL_CAMERA_DRIVER_PIPEWIRE = linux, // MARK
            .SDL_CAMERA_DRIVER_PIPEWIRE_DYNAMIC = if (target.result.os.tag == .linux) "\"libpipewire-0.3.so.0\"" else "",
            .SDL_CAMERA_DRIVER_VITA = false, // MARK
            .SDL_CAMERA_DRIVER_PRIVATE = false, // MARK
            .SDL_DIALOG_DUMMY = false, // MARK
            .SDL_TRAY_DUMMY = emscripten, // MARK
            .SDL_ALTIVEC_BLITTERS = false, // MARK
            .DYNAPI_NEEDS_DLOPEN = linux or macos or emscripten, // MARK
            .SDL_USE_IME = linux, // MARK
            .SDL_DISABLE_WINDOWS_IME = false, // MARK
            .SDL_GDK_TEXTINPUT = false, // MARK
            .SDL_IPHONE_KEYBOARD = false, // MARK
            .SDL_IPHONE_LAUNCHSCREEN = false, // MARK
            .SDL_VIDEO_VITA_PIB = false, // MARK
            .SDL_VIDEO_VITA_PVR = false, // MARK
            .SDL_VIDEO_VITA_PVR_OGL = false, // MARK
            .SDL_EMSCRIPTEN_PERSISTENT_PATH_STRING = null,
            // Temporarily set to a lower version as >= 1.10.0 is not yet widely available.
            // TODO: Uncomment after Ubuntu 26.04 LTS has been released?
            .SDL_XKBCOMMON_VERSION_MAJOR = @as(i64, 1),
            .SDL_XKBCOMMON_VERSION_MINOR = @as(i64, 6),
            .SDL_XKBCOMMON_VERSION_PATCH = @as(i64, 0),
            //.SDL_XKBCOMMON_VERSION_MAJOR = if (linux_deps_values) |x| @as(i64, @intCast(x.xkbcommon_version.major)) else null,
            //.SDL_XKBCOMMON_VERSION_MINOR = if (linux_deps_values) |x| @as(i64, @intCast(x.xkbcommon_version.major)) else null,
            //.SDL_XKBCOMMON_VERSION_PATCH = if (linux_deps_values) |x| @as(i64, @intCast(x.xkbcommon_version.major)) else null,
            .SDL_LIBDECOR_VERSION_MAJOR = @as(i64, 0),
            .SDL_LIBDECOR_VERSION_MINOR = @as(i64, 2),
            .SDL_LIBDECOR_VERSION_PATCH = @as(i64, 5),
            .SDL_DISABLE_SSE = !(x86 and std.Target.x86.featureSetHas(cpu.features, .sse)),
            .SDL_DISABLE_SSE2 = !(x86 and std.Target.x86.featureSetHas(cpu.features, .sse2)),
            .SDL_DISABLE_SSE3 = !(x86 and std.Target.x86.featureSetHas(cpu.features, .sse3)),
            .SDL_DISABLE_SSE4_1 = !(x86 and std.Target.x86.featureSetHas(cpu.features, .sse4_1)),
            .SDL_DISABLE_SSE4_2 = !(x86 and std.Target.x86.featureSetHas(cpu.features, .sse4_2)),
            .SDL_DISABLE_AVX = !(x86 and std.Target.x86.featureSetHas(cpu.features, .avx)),
            .SDL_DISABLE_AVX2 = !(x86 and std.Target.x86.featureSetHas(cpu.features, .avx2)),
            .SDL_DISABLE_AVX512F = !(x86 and std.Target.x86.featureSetHas(cpu.features, .avx512f)),
            .SDL_DISABLE_MMX = !(x86 and std.Target.x86.featureSetHas(cpu.features, .mmx)),
            .SDL_DISABLE_LSX = !(loongarch and std.Target.loongarch.featureSetHas(cpu.features, .lsx)), // MARK
            .SDL_DISABLE_LASX = !(loongarch and std.Target.loongarch.featureSetHas(cpu.features, .lasx)), // MARK
            .SDL_DISABLE_NEON = !(arm and std.Target.arm.featureSetHas(cpu.features, .neon) or aarch64 and std.Target.aarch64.featureSetHas(cpu.features, .neon)),
        });
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

    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .sanitize_c = sanitize_c,
        .pic = pic,
    });

    const sdl_lib = b.addLibrary(.{
        .linkage = if (emscripten) .static else preferred_linkage,
        .name = "SDL3",
        .root_module = module,
        .version = .{
            .major = parsed_version.major,
            .minor = parsed_version.minor,
            .patch = parsed_version.patch,
        },
        .use_llvm = if (emscripten) true else null,
    });
    sdl_lib.lto = lto;

    module.addCMacro("USING_GENERATED_CONFIG_H", "1");
    module.addCMacro("SDL_BUILD_MAJOR_VERSION", std.fmt.comptimePrint("{d}", .{ parsed_version.major }));
    module.addCMacro("SDL_BUILD_MINOR_VERSION", std.fmt.comptimePrint("{d}", .{ parsed_version.minor }));
    module.addCMacro("SDL_BUILD_MICRO_VERSION", std.fmt.comptimePrint("{d}", .{ parsed_version.patch }));

    module.addConfigHeader(build_config_h);
    module.addConfigHeader(revision);
    module.addIncludePath(include);
    module.addIncludePath(source);
    module.addSystemIncludePath(source.path(b, "video/khronos"));

    if (target.result.os.tag == .linux) {
        module.linkSystemLibrary("m", .{});
        module.linkSystemLibrary("dl", .{});
        module.linkSystemLibrary("pthread", .{});
    }

    if (windows and msvc) {
        module.addCMacro("_CRT_SECURE_NO_DEPRECATE", "1");
        module.addCMacro("_CRT_NONSTDC_NO_DEPRECATE", "1");
        module.addCMacro("_CRT_SECURE_NO_WARNINGS", "1");
    }
    if (emscripten and emscripten_pthreads) {
        module.addCMacro("__EMSCRIPTEN_PTHREADS__", "1");
        module.addCMacro("_REENTRANT", "1");
    }

    if (system_include_path) |path| {
        module.addSystemIncludePath(path);
    }
    if (system_framework_path) |path| {
        module.addSystemFrameworkPath(path);
    }
    if (library_path) |path| {
        module.addLibraryPath(path);
    }

    var cflags: std.ArrayList([]const u8) = .empty;
    cflags.appendSlice(b.allocator, &.{
        "-Wall",
        "-Wundef",
        "-Wfloat-conversion",
        "-fno-strict-aliasing",
        "-Wshadow",
        "-Wno-unused-local-typedefs",
        "-Wimplicit-fallthrough"
    }) catch @panic("out of memory");

    if (sdl_lib.linkage.? == .dynamic) {
        cflags.append(b.allocator, "-fvisibility=hidden");
    }
    if (linux) {
        cflags.append(b.allocator, "-pthread");
    }
    if (macos) {
        cflags.append(b.allocator, "-pthread");
        cflags.append(b.allocator, "-fobjc-arc");
    }
    if (emscripten and emscripten_pthreads) {
        cflags.append(b.allocator, "-pthread");
    }

    addPlatformSources(
        b,
        module,
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
        },
        cflags.items,
    );

    const install_sdl_lib = b.addInstallArtifact(sdl_lib, .{});

    const install_sdl = b.step("install_sdl", "Install SDL");
    install_sdl.dependOn(&install_sdl_lib.step);

    b.getInstallStep().dependOn(&install_sdl_lib.step);

    // const sdl_translate_c = b.addTranslateC(.{
    //     .root_source_file = sdl_dep.path("include/SDL3/SDL.h"),
    //     .target = target,
    //     .optimize = optimize,
    //     .link_libc = true,
    // });

    // sdl_translate_c.addIncludePath(sdl_dep.path("include"));

    // _ = sdl_translate_c.addModule("sdl");

    const translate = b.addTranslateC(.{
        .root_source_file = sdl_dep.path("include/SDL3/SDL.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(include);
    translate.addConfigHeader(build_config_h);
    translate.addConfigHeader(revision);
    // _ = translate.createModule();
    _ = translate.addModule("sdl");
}

fn pkgConfig(b: *std.Build, module: *std.Build.Module, name: []const u8) void {
    const result = std.process.run(b.allocator, b.graph.io, .{ .argv = &.{ "pkg-config", "--cflags-only-I", name } }) catch @panic("pkg-config is required for Linux SDL builds");
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) @panic("required Linux SDL package was not found through pkg-config");
    var it = std.mem.tokenizeAny(u8, result.stdout, " \r\n");
    while (it.next()) |flag| {
        if (std.mem.startsWith(u8, flag, "-I")) {
            module.addSystemIncludePath(.{ .cwd_relative = flag[2..] });
        }
    }
}

const platform_struct = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: ?bool,
    sanitize_c: ?bool,
    pic: ?bool,
    lto: ?bool,
    emscripten_pthreads: bool,
    build_configheader: *std.Build.Step.ConfigHeader,
    revision_configheader: *std.Build.Step.ConfigHeader,
    sdl_dep: *std.Build.Dependency,
    sdl_library: *std.Build.Step.Compile,
};

fn addPlatformSources(
    b: *std.Build,
    module: *std.Build.Module,
    platform: platform_struct,
    cflags: []const []const u8
) void {
    const source_lazypath = platform.sdl_dep.path("src");

    module.addCSourceFiles(.{
        .root = source_lazypath,
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
                .root = source_lazypath,
                .flags = cflags.items,
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
            sdl_uclibc_mod.addIncludePath(b.path("include"));
            sdl_uclibc_mod.addIncludePath(b.path("src"));

            sdl_uclibc_mod.addCSourceFiles(.{
                .root = source_lazypath,
                .flags = &(cflags ++ .{"-fvisibility=hidden"}),
                .files = &sdl_uclibc_c_files,
            });

            module.linkLibrary(sdl_uclibc_lib);
        },
    }

    switch (platform.target.result.os.tag) {
        .linux => {
            pkgConfig(b, module, "x11");
            pkgConfig(b, module, "xcursor");
            pkgConfig(b, module, "xext");
            pkgConfig(b, module, "xfixes");
            pkgConfig(b, module, "xi");
            pkgConfig(b, module, "xrandr");
            pkgConfig(b, module, "xss");
            pkgConfig(b, module, "xtst");
            pkgConfig(b, module, "wayland-client");
            pkgConfig(b, module, "wayland-cursor");
            pkgConfig(b, module, "wayland-egl");
            pkgConfig(b, module, "xkbcommon");

            module.addCSourceFiles(.{
                .root = source_lazypath,
                .flags = cflags.items,
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

            const io = b.graph.io;
            const wayland_protocols_lazypath = platform.sdl_dep.path("wayland-protocols");
            const wayland_protocols_path = try wayland_protocols_lazypath.getPath4(b, null);
            const dir = try wayland_protocols_path.openDir(io, "", .{ .iterate = true });
            defer dir.close(io);

            var iterator = dir.iterate();
            while (try iterator.next(io)) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.name, ".xml")) continue;

                const xml_path = b.pathJoin(&.{ wayland_protocols_lazypath, entry.name });
                const protocol_stem = std.fs.path.stem(entry.name);
                const header_name = b.fmt("{s}-client-protocol.h", .{protocol_stem});
                const source_name = b.fmt("{s}-protocol.c", .{protocol_stem});

                const header_step = b.addSystemCommand(&.{ "wayland-scanner", "client-header", xml_path });
                const header = header_step.addOutputFileArg(header_name);
                module.addIncludePath(header);
                const source_step = b.addSystemCommand(&.{ "wayland-scanner", "private-code", xml_path });
                const generated_source = source_step.addOutputFileArg(source_name);
                module.addCSourceFile(.{ .file = generated_source, .flags = cflags });
            }
        },
        .windows => {
            module.addCSourceFiles(.{
                .root = source_lazypath,
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
                    .root = source_lazypath,
                    .flags = cflags,
                    .files = &.{
                        "joystick/gdk/SDL_gameinputjoystick.cpp",
                    },
                });
            }
            if (platform.sdl_library.linkage.? == .dynamic) {
                module.addWin32ResourceFile(.{
                    .file = source_lazypath.path("core/windows/version.rc")
                });
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
                .root = source_lazypath,
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
                .root = source_lazypath,
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
                    .root = source_lazypath,
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
                    .root = source_lazypath,
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
}
