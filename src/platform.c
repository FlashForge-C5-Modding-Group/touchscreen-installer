#include <errno.h>
#include <fcntl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include "platform.h"

static int fb_fd = -1, input_fd = -1;
static uint8_t *fb_map;
static size_t fb_size;
static struct fb_var_screeninfo var;
static struct fb_fix_screeninfo fix;
static int x_min, x_max, y_min, y_max;
static int x_raw, y_raw;
static int touching;

static unsigned int channel(unsigned int value, struct fb_bitfield field)
{
    if (field.length == 0) return 0;
    unsigned int max = (1u << field.length) - 1u;
    return ((value * max + 127u) / 255u) << field.offset;
}

static int read_axis(int axis, int *min_value, int *max_value)
{
    struct input_absinfo info;
    if (ioctl(input_fd, EVIOCGABS(axis), &info) != 0 ||
        info.maximum <= info.minimum) return -1;
    *min_value = info.minimum;
    *max_value = info.maximum;
    return 0;
}

int platform_init(const char *framebuffer, const char *input,
                  uint32_t *width, uint32_t *height)
{
    fb_fd = open(framebuffer, O_RDWR | O_CLOEXEC);
    if (fb_fd < 0 || ioctl(fb_fd, FBIOGET_VSCREENINFO, &var) != 0 ||
        ioctl(fb_fd, FBIOGET_FSCREENINFO, &fix) != 0) return -1;
    if ((var.bits_per_pixel != 16 && var.bits_per_pixel != 32) ||
        !var.xres || !var.yres) return -1;
    fb_size = fix.smem_len;
    fb_map = mmap(NULL, fb_size, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
    if (fb_map == MAP_FAILED) return -1;
    input_fd = open(input, O_RDONLY | O_NONBLOCK | O_CLOEXEC);
    if (input_fd < 0) return -1;
    if (read_axis(ABS_MT_POSITION_X, &x_min, &x_max) != 0 ||
        read_axis(ABS_MT_POSITION_Y, &y_min, &y_max) != 0) {
        if (read_axis(ABS_X, &x_min, &x_max) != 0 ||
            read_axis(ABS_Y, &y_min, &y_max) != 0) return -1;
    }
    *width = var.xres;
    *height = var.yres;
    return 0;
}

void platform_flush(lv_disp_drv_t *drv, const lv_area_t *area,
                    lv_color_t *pixels)
{
    int width = area->x2 - area->x1 + 1;
    for (int y = area->y1; y <= area->y2; y++) {
        if (y < 0 || y >= (int)var.yres) continue;
        for (int x = area->x1; x <= area->x2; x++) {
            if (x < 0 || x >= (int)var.xres) continue;
            size_t offset = ((size_t)(y + (int)var.yoffset) * fix.line_length +
                             (size_t)(x + (int)var.xoffset) * (var.bits_per_pixel / 8));
            if (offset + var.bits_per_pixel / 8 > fb_size) continue;
            lv_color_t color = pixels[(size_t)(y - area->y1) * width + (x - area->x1)];
            uint32_t packed = channel(color.ch.red, var.red) |
                              channel(color.ch.green, var.green) |
                              channel(color.ch.blue, var.blue);
            if (var.bits_per_pixel == 16) {
                uint16_t value = (uint16_t)packed;
                memcpy(fb_map + offset, &value, sizeof(value));
            } else {
                memcpy(fb_map + offset, &packed, sizeof(packed));
            }
        }
    }
    lv_disp_flush_ready(drv);
}

static int scale(int value, int minimum, int maximum, int extent)
{
    if (maximum <= minimum) return 0;
    if (value < minimum) value = minimum;
    if (value > maximum) value = maximum;
    return (value - minimum) * (extent - 1) / (maximum - minimum);
}

void platform_touch(lv_indev_drv_t *drv, lv_indev_data_t *data)
{
    (void)drv;
    struct input_event event;
    while (read(input_fd, &event, sizeof(event)) == sizeof(event)) {
        if (event.type == EV_ABS) {
            if (event.code == ABS_X || event.code == ABS_MT_POSITION_X)
                x_raw = event.value;
            else if (event.code == ABS_Y || event.code == ABS_MT_POSITION_Y)
                y_raw = event.value;
            else if (event.code == ABS_MT_TRACKING_ID)
                touching = event.value >= 0;
            else if (event.code == ABS_PRESSURE)
                touching = event.value > 0;
        } else if (event.type == EV_KEY && event.code == BTN_TOUCH) {
            touching = event.value != 0;
        }
    }
    data->point.x = scale(x_raw, x_min, x_max, (int)var.xres);
    data->point.y = scale(y_raw, y_min, y_max, (int)var.yres);
    data->state = touching ? LV_INDEV_STATE_PRESSED : LV_INDEV_STATE_RELEASED;
}
