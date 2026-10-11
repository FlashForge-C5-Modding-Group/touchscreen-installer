#include <SDL.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "platform.h"

static SDL_Window *window;
static SDL_Renderer *renderer;
static SDL_Texture *texture;
static int pointer_x, pointer_y, pressed;

int platform_init(const char *framebuffer, const char *input,
                  uint32_t *width, uint32_t *height)
{
    (void)framebuffer;
    (void)input;
    *width = 800;
    *height = 480;
    if (SDL_Init(SDL_INIT_VIDEO) != 0) return -1;
    window = SDL_CreateWindow("OpenCreator installer demo", SDL_WINDOWPOS_CENTERED,
                              SDL_WINDOWPOS_CENTERED, (int)*width, (int)*height, 0);
    if (!window) return -1;
    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    if (!renderer) renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE);
    if (!renderer) return -1;
    texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                                SDL_TEXTUREACCESS_STREAMING, (int)*width, (int)*height);
    return texture ? 0 : -1;
}

void platform_flush(lv_disp_drv_t *drv, const lv_area_t *area,
                    lv_color_t *pixels)
{
    SDL_Rect rect = { area->x1, area->y1,
                      area->x2 - area->x1 + 1, area->y2 - area->y1 + 1 };
    SDL_UpdateTexture(texture, &rect, pixels, rect.w * (int)sizeof(lv_color_t));
    SDL_RenderClear(renderer);
    SDL_RenderCopy(renderer, texture, NULL, NULL);
    SDL_RenderPresent(renderer);
    lv_disp_flush_ready(drv);
}

void platform_touch(lv_indev_drv_t *drv, lv_indev_data_t *data)
{
    (void)drv;
    SDL_Event event;
    while (SDL_PollEvent(&event)) {
        if (event.type == SDL_QUIT) exit(0);
        if (event.type == SDL_MOUSEBUTTONDOWN && event.button.button == SDL_BUTTON_LEFT)
            pressed = 1;
        else if (event.type == SDL_MOUSEBUTTONUP && event.button.button == SDL_BUTTON_LEFT)
            pressed = 0;
        if (event.type == SDL_MOUSEMOTION) {
            pointer_x = event.motion.x;
            pointer_y = event.motion.y;
        } else if (event.type == SDL_MOUSEBUTTONDOWN || event.type == SDL_MOUSEBUTTONUP) {
            pointer_x = event.button.x;
            pointer_y = event.button.y;
        }
    }
    data->point.x = pointer_x;
    data->point.y = pointer_y;
    data->state = pressed ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}
