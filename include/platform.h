#ifndef OC_PLATFORM_H
#define OC_PLATFORM_H
#include <stdint.h>
#include "lvgl/lvgl.h"
int platform_init(const char *framebuffer, const char *input,
                  uint32_t *width, uint32_t *height);
void platform_flush(lv_disp_drv_t *drv, const lv_area_t *area,
                    lv_color_t *pixels);
void platform_touch(lv_indev_drv_t *drv, lv_indev_data_t *data);
#endif
