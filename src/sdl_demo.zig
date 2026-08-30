const sdl = @import("sdl");

fn sdlError() error{SdlError} {
    return error.SdlError;
}

pub fn main() !void {
    if (!sdl.SDL_Init(sdl.SDL_INIT_VIDEO)) return sdlError();
    defer sdl.SDL_Quit();

    const window = sdl.SDL_CreateWindow("Zig SDL3", 800, 600, 0) orelse return sdlError();
    defer sdl.SDL_DestroyWindow(window);

    const renderer = sdl.SDL_CreateRenderer(window, null) orelse return sdlError();
    defer sdl.SDL_DestroyRenderer(renderer);

    var running = true;
    while (running) {
        var event: sdl.SDL_Event = undefined;
        while (sdl.SDL_PollEvent(&event)) {
            if (event.type == sdl.SDL_EVENT_QUIT or
                (event.type == sdl.SDL_EVENT_KEY_DOWN and event.key.key == sdl.SDLK_ESCAPE))
            {
                running = false;
            }
        }

        _ = sdl.SDL_SetRenderDrawColor(renderer, 24, 28, 38, 255);
        _ = sdl.SDL_RenderClear(renderer);

        const rectangle = sdl.SDL_FRect{ .x = 250, .y = 175, .w = 300, .h = 250 };
        _ = sdl.SDL_SetRenderDrawColor(renderer, 70, 180, 120, 255);
        _ = sdl.SDL_RenderFillRect(renderer, &rectangle);
        _ = sdl.SDL_RenderPresent(renderer);
    }
}
