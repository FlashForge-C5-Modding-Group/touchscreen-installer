#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "lvgl/lvgl.h"
#include "platform.h"

enum page { PAGE_CHECK, PAGE_ROOTFS, PAGE_MODE, PAGE_WEB, PAGE_TOUCHSCREEN, PAGE_READY,
            PAGE_RUNNING, PAGE_REBOOT, PAGE_DONE, PAGE_ERROR };
static enum page page_now;
static const char *rootfs_path, *payload_path, *backup_path, *script_path;
static const char *mode = "soc", *web = "mainsail";
static const char *touchscreen = "yes";
/* NULL for a real install; otherwise the install runs with
 * OC_DEMO_ROOT set to this path, so every payload script writes under
 * it instead of the real system (see payload-template/common and
 * scripts/install.sh) -- distinct from the OC_DEMO build-time flag
 * above, which fakes the whole flow for the SDL dev build and never
 * touches a filesystem at all. */
static const char *demo_root;
#define OC_DEMO_INSTALL_ROOT "/tmp/opencreator-demo"
static lv_obj_t *step_label, *title_label, *body_label, *summary_box;
static lv_obj_t *spinner, *status_label, *button_row;
static pid_t child_pid = -1;
static int child_fd = -1;
static char linebuf[1024];
static size_t line_len;
static char current_action[16];
static bool rootfs_current;
static uint64_t reboot_at;

#define OC_COLOR_BG       0x151a22
#define OC_COLOR_CARD     0x1f2630
#define OC_COLOR_ACCENT   0x4fd1a5
#define OC_COLOR_PRIMARY  0x3d8bfd
#define OC_COLOR_DANGER   0xef5b5b
#define OC_COLOR_MUTED    0x8894a3
#define OC_COLOR_TEXT     0xe9edf2

/* Steps shown in the breadcrumb depend on the branch taken: Tunnel
 * skips the web UI and touchscreen questions that SoC mode asks. */
static void step_info(enum page p, int *step, int *total)
{
    bool soc = strcmp(mode, "soc") == 0;
    *total = soc ? 5 : 3;
    switch (p) {
    case PAGE_CHECK:
    case PAGE_ROOTFS:   *step = 0; break;
    case PAGE_MODE:     *step = 1; break;
    case PAGE_WEB:        *step = 2; break;
    case PAGE_TOUCHSCREEN: *step = 3; break;
    case PAGE_READY:    *step = soc ? 4 : 2; break;
    case PAGE_RUNNING:
    case PAGE_REBOOT:
    case PAGE_DONE:
    case PAGE_ERROR:    *step = *total; break;
    default:            *step = 0; break;
    }
}

static const char *page_icon(enum page p)
{
    switch (p) {
    case PAGE_DONE:  return LV_SYMBOL_OK;
    case PAGE_ERROR: return LV_SYMBOL_WARNING;
    case PAGE_ROOTFS:
    case PAGE_REBOOT: return LV_SYMBOL_REFRESH;
    case PAGE_RUNNING: return LV_SYMBOL_DOWNLOAD;
    case PAGE_MODE:  return LV_SYMBOL_SETTINGS;
    case PAGE_WEB:
    case PAGE_TOUCHSCREEN: return LV_SYMBOL_EDIT;
    case PAGE_READY: return LV_SYMBOL_PLAY;
    default:         return LV_SYMBOL_HOME;
    }
}

static void set_title(enum page p, const char *text)
{
    static char buf[160];
    snprintf(buf, sizeof(buf), "%s  %s", page_icon(p), text);
    lv_label_set_text(title_label, buf);
}

static uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static void set_status(const char *message)
{
    lv_label_set_text(status_label, message);
    lv_obj_set_style_text_color(status_label, lv_color_hex(OC_COLOR_ACCENT), 0);
}

static void set_status_error(const char *message)
{
    lv_label_set_text(status_label, message);
    lv_obj_set_style_text_color(status_label, lv_color_hex(OC_COLOR_DANGER), 0);
}

static void clear_buttons(void)
{
    lv_obj_clean(button_row);
}

static void show_page(enum page next);

static void start_action(const char *action)
{
    int fds[2];
    if (pipe(fds) != 0) {
        show_page(PAGE_ERROR);
        set_status("Cannot open status pipe");
        return;
    }
    if (demo_root) setenv("OC_DEMO_ROOT", demo_root, 1);
    else unsetenv("OC_DEMO_ROOT");
    pid_t pid = fork();
    if (pid == 0) {
        close(fds[0]);
        dup2(fds[1], STDOUT_FILENO);
        dup2(fds[1], STDERR_FILENO);
        close(fds[1]);
        execl("/bin/sh", "sh", script_path, action, rootfs_path,
              payload_path, backup_path, mode, web, touchscreen, (char *)NULL);
        _exit(127);
    }
    close(fds[1]);
    if (pid < 0) {
        close(fds[0]);
        show_page(PAGE_ERROR);
        set_status("Cannot start installer script");
        return;
    }
    child_pid = pid;
    child_fd = fds[0];
    fcntl(child_fd, F_SETFL, fcntl(child_fd, F_GETFL, 0) | O_NONBLOCK);
    snprintf(current_action, sizeof(current_action), "%s", action);
    line_len = 0;
    if (strcmp(action, "check") != 0)
        show_page(PAGE_RUNNING);
}

static void action_button(lv_event_t *event)
{
    const char *action = lv_event_get_user_data(event);
    if (strcmp(action, "rootfs") == 0) start_action("rootfs");
    else if (strcmp(action, "soc") == 0) { mode = "soc"; show_page(PAGE_WEB); }
    else if (strcmp(action, "tunnel") == 0) {
        mode = "tunnel"; web = "none"; touchscreen = "no"; show_page(PAGE_READY);
    } else if (strcmp(action, "mainsail") == 0 || strcmp(action, "fluidd") == 0) {
        web = action; show_page(PAGE_TOUCHSCREEN);
    } else if (strcmp(action, "touch-yes") == 0) {
        touchscreen = "yes"; show_page(PAGE_READY);
    } else if (strcmp(action, "touch-no") == 0) {
        touchscreen = "no"; show_page(PAGE_READY);
    } else if (strcmp(action, "install") == 0) { demo_root = NULL; start_action("install"); }
    else if (strcmp(action, "demo-install") == 0) {
        demo_root = OC_DEMO_INSTALL_ROOT; start_action("install");
    } else if (strcmp(action, "back") == 0) show_page(PAGE_MODE);
}

static void add_button_styled(const char *text, const char *action, bool primary)
{
    lv_obj_t *button = lv_btn_create(button_row);
    lv_obj_set_size(button, 220, 58);
    lv_obj_set_style_radius(button, 10, 0);
    lv_obj_set_style_bg_color(button,
        lv_color_hex(primary ? OC_COLOR_PRIMARY : OC_COLOR_CARD), 0);
    lv_obj_set_style_border_width(button, primary ? 0 : 1, 0);
    lv_obj_set_style_border_color(button, lv_color_hex(OC_COLOR_MUTED), 0);
    lv_obj_add_event_cb(button, action_button, LV_EVENT_CLICKED, (void *)action);
    lv_obj_t *label = lv_label_create(button);
    lv_label_set_text(label, text);
    lv_obj_set_style_text_color(label,
        lv_color_hex(primary ? 0xffffff : OC_COLOR_TEXT), 0);
    lv_obj_center(label);
}

/* "Back" and "No" are secondary; every other action is the page's
 * primary (forward-moving) action. */
static void add_button(const char *text, const char *action)
{
    bool secondary = strcmp(action, "back") == 0 || strcmp(action, "touch-no") == 0;
    add_button_styled(text, action, !secondary);
}

static void add_summary_row(const char *label, const char *value)
{
    lv_obj_t *row = lv_label_create(summary_box);
    static char buf[128];
    snprintf(buf, sizeof(buf), "%s  " LV_SYMBOL_RIGHT "  %s", label, value);
    lv_label_set_text(row, buf);
    lv_obj_set_style_text_color(row, lv_color_hex(OC_COLOR_TEXT), 0);
    lv_obj_set_style_pad_bottom(row, 6, 0);
}

static void show_page(enum page next)
{
    page_now = next;
    clear_buttons();
    lv_obj_add_flag(summary_box, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(spinner, LV_OBJ_FLAG_HIDDEN);
    lv_obj_clean(summary_box);

    int step, total;
    step_info(next, &step, &total);
    static char step_buf[32];
    if (step > 0 && step < total) {
        snprintf(step_buf, sizeof(step_buf), "Step %d of %d", step, total);
    } else {
        step_buf[0] = '\0';
    }
    lv_label_set_text(step_label, step_buf);

    switch (next) {
    case PAGE_CHECK:
        set_title(next, "OpenCreator installer");
        lv_label_set_text(body_label, "Checking the supplied root filesystem...");
        break;
    case PAGE_ROOTFS:
        set_title(next, "Root filesystem update");
        lv_label_set_text(body_label, "A different squashfs was supplied. The vendor OTA path will update the inactive rootfs slot, then reboot. Do not interrupt power.");
        add_button("Update and reboot", "rootfs");
        break;
    case PAGE_MODE:
        set_title(next, "Where should Klipper run?");
        lv_label_set_text(body_label, "Choose on-device installation or tunnel to another host.");
        add_button("On printer SoC", "soc");
        add_button("Tunneled", "tunnel");
        break;
    case PAGE_WEB:
        set_title(next, "Choose web interface");
        lv_label_set_text(body_label, "This selection is for the on-printer installation.");
        add_button("Mainsail", "mainsail");
        add_button("Fluidd", "fluidd");
        break;
    case PAGE_TOUCHSCREEN:
        set_title(next, "Install touchscreen UI?");
        lv_label_set_text(body_label, "GrumpyScreen is recommended for on-printer control. Tunnel installs skip it.");
        add_button("Yes (recommended)", "touch-yes");
        add_button("No", "touch-no");
        break;
    case PAGE_READY:
        set_title(next, "Ready to install");
        lv_label_set_text(body_label,
#ifdef OC_DEMO
            "Existing program and config directories are backed up first. "
            "\"Demo install\" runs every step for real but writes under "
            OC_DEMO_INSTALL_ROOT " instead of the real system, so you can "
            "inspect exactly what it does first."
#else
            "Existing program and config directories are backed up first."
#endif
        );
        lv_obj_clear_flag(summary_box, LV_OBJ_FLAG_HIDDEN);
        add_summary_row("Mode", strcmp(mode, "soc") == 0 ? "Printer SoC" : "Tunneled SBC");
        if (strcmp(mode, "soc") == 0) {
            add_summary_row("Web UI", web);
            add_summary_row("Touchscreen",
                             strcmp(touchscreen, "yes") == 0 ? "GrumpyScreen" : "None");
        }
        add_button("Back", "back");
#ifdef OC_DEMO
        add_button("Demo install", "demo-install");
#endif
        add_button("Back up and install", "install");
        break;
    case PAGE_RUNNING:
        set_title(next, demo_root ? "Demo installing" : "Installing");
        lv_label_set_text(body_label, demo_root
            ? "Follow the live status below. Writing to " OC_DEMO_INSTALL_ROOT
              ", not the real system -- safe to power off."
            : "Follow the live status below. Do not power off.");
        lv_obj_clear_flag(spinner, LV_OBJ_FLAG_HIDDEN);
        break;
    case PAGE_REBOOT:
        set_title(next, "Rootfs update staged");
        lv_label_set_text(body_label, "Restarting in five seconds. Reopen the installer after boot; it will skip the completed rootfs step.");
        reboot_at = now_ms() + 5000;
        break;
    case PAGE_DONE:
        set_title(next, demo_root ? "Demo install complete" : "Installation complete");
        lv_label_set_text(body_label, demo_root
            ? "Nothing on the real system was touched. Inspect the files it would "
              "have written at " OC_DEMO_INSTALL_ROOT "."
            : "Review the installer status and reboot when your installation scripts "
              "require it. Unplug the installer USB drive once you're done -- leaving "
              "it plugged in risks it being picked up again on the next boot.");
        break;
    case PAGE_ERROR:
        set_title(next, "Installation stopped");
        lv_label_set_text(body_label, "No later stages were run. Review the error and backup before retrying.");
        break;
    }
}

static void process_line(char *line)
{
    if (strncmp(line, "STATE CURRENT", 13) == 0) rootfs_current = true;
    if (strncmp(line, "STATE NEEDED", 12) == 0) rootfs_current = false;
    if (strncmp(line, "STAGE ", 6) == 0) set_status(line + 6);
    else if (strncmp(line, "ERROR ", 6) == 0) set_status_error(line + 6);
}

static void poll_child(void)
{
    if (child_pid < 0) return;
    char buf[256];
    ssize_t count;
    while ((count = read(child_fd, buf, sizeof(buf))) > 0) {
        for (ssize_t i = 0; i < count; i++) {
            if (buf[i] == '\n') {
                linebuf[line_len] = '\0';
                process_line(linebuf);
                line_len = 0;
            } else if (line_len + 1 < sizeof(linebuf)) {
                linebuf[line_len++] = buf[i];
            }
        }
    }
    int status;
    pid_t result = waitpid(child_pid, &status, WNOHANG);
    if (result != child_pid) return;
    if (line_len) {
        linebuf[line_len] = '\0';
        process_line(linebuf);
        line_len = 0;
    }
    close(child_fd);
    child_fd = -1;
    child_pid = -1;
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        show_page(PAGE_ERROR);
    } else if (strcmp(current_action, "check") == 0) {
        show_page(rootfs_current ? PAGE_MODE : PAGE_ROOTFS);
    } else if (strcmp(current_action, "rootfs") == 0) {
        show_page(PAGE_REBOOT);
    } else {
        show_page(PAGE_DONE);
    }
}

int main(int argc, char **argv)
{
#ifdef OC_DEMO
    (void)argc;
    (void)argv;
    rootfs_path = "-";
    payload_path = "payload-template";
    backup_path = "/tmp/opencreator-installer-demo";
    script_path = "scripts/demo.sh";
#else
    if (argc != 5) {
        fprintf(stderr, "usage: %s ROOTFS.squashfs PAYLOAD_DIR BACKUP_DIR INSTALL_SCRIPT\n", argv[0]);
        return 2;
    }
    rootfs_path = argv[1];
    payload_path = argv[2];
    backup_path = argv[3];
    script_path = argv[4];
#endif
    lv_init();
    uint32_t width = 800, height = 480;
    if (platform_init("/dev/fb0", "/dev/input/event0", &width, &height) != 0) {
        fprintf(stderr, "framebuffer or touch input unavailable\n");
        return 1;
    }
    lv_color_t *buffer = calloc(width * 32, sizeof(lv_color_t));
    if (!buffer) return 1;
    lv_disp_draw_buf_t draw_buf;
    lv_disp_draw_buf_init(&draw_buf, buffer, NULL, width * 32);
    lv_disp_drv_t display;
    lv_disp_drv_init(&display);
    display.draw_buf = &draw_buf;
    display.flush_cb = platform_flush;
    display.hor_res = width;
    display.ver_res = height;
    lv_disp_drv_register(&display);
    lv_indev_drv_t input;
    lv_indev_drv_init(&input);
    input.type = LV_INDEV_TYPE_POINTER;
    input.read_cb = platform_touch;
    lv_indev_drv_register(&input);
    lv_obj_t *screen = lv_scr_act();
    lv_obj_set_style_bg_color(screen, lv_color_hex(OC_COLOR_BG), 0);

    lv_obj_t *brand_label = lv_label_create(screen);
    lv_label_set_text(brand_label, "OPENCREATOR");
    lv_obj_set_style_text_color(brand_label, lv_color_hex(OC_COLOR_MUTED), 0);
    lv_obj_align(brand_label, LV_ALIGN_TOP_LEFT, 30, 18);

    step_label = lv_label_create(screen);
    lv_obj_set_style_text_color(step_label, lv_color_hex(OC_COLOR_MUTED), 0);
    lv_obj_align(step_label, LV_ALIGN_TOP_RIGHT, -30, 18);

    title_label = lv_label_create(screen);
    lv_obj_set_width(title_label, width - 60);
    lv_obj_set_style_text_color(title_label, lv_color_white(), 0);
    lv_obj_set_style_text_font(title_label, &lv_font_montserrat_24, 0);
    lv_obj_align(title_label, LV_ALIGN_TOP_LEFT, 30, 42);

    body_label = lv_label_create(screen);
    lv_obj_set_width(body_label, width - 60);
    lv_label_set_long_mode(body_label, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_color(body_label, lv_color_hex(OC_COLOR_TEXT), 0);
    lv_obj_align(body_label, LV_ALIGN_TOP_LEFT, 30, 100);

    summary_box = lv_obj_create(screen);
    lv_obj_set_size(summary_box, width - 60, 110);
    lv_obj_align(summary_box, LV_ALIGN_TOP_LEFT, 30, 160);
    lv_obj_set_style_bg_color(summary_box, lv_color_hex(OC_COLOR_CARD), 0);
    lv_obj_set_style_border_width(summary_box, 0, 0);
    lv_obj_set_style_radius(summary_box, 10, 0);
    lv_obj_set_style_pad_all(summary_box, 14, 0);
    lv_obj_set_flex_flow(summary_box, LV_FLEX_FLOW_COLUMN);
    lv_obj_clear_flag(summary_box, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(summary_box, LV_SCROLLBAR_MODE_OFF);
    lv_obj_add_flag(summary_box, LV_OBJ_FLAG_HIDDEN);

    spinner = lv_spinner_create(screen, 1000, 80);
    lv_obj_set_size(spinner, 36, 36);
    lv_obj_align(spinner, LV_ALIGN_TOP_LEFT, 30, 160);
    lv_obj_set_style_arc_color(spinner, lv_color_hex(OC_COLOR_ACCENT), LV_PART_INDICATOR);
    lv_obj_add_flag(spinner, LV_OBJ_FLAG_HIDDEN);

    button_row = lv_obj_create(screen);
    lv_obj_set_size(button_row, width - 40, 90);
    lv_obj_align(button_row, LV_ALIGN_BOTTOM_MID, 0, -20);
    lv_obj_set_style_bg_opa(button_row, LV_OPA_TRANSP, 0);
    lv_obj_set_style_border_width(button_row, 0, 0);
    lv_obj_set_flex_flow(button_row, LV_FLEX_FLOW_ROW);
    lv_obj_set_style_pad_column(button_row, 16, 0);
    lv_obj_clear_flag(button_row, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scrollbar_mode(button_row, LV_SCROLLBAR_MODE_OFF);

    status_label = lv_label_create(screen);
    lv_obj_set_width(status_label, width - 60);
    lv_label_set_long_mode(status_label, LV_LABEL_LONG_WRAP);
    lv_obj_align(status_label, LV_ALIGN_BOTTOM_LEFT, 30, -125);
    set_status("Preparing...");
    show_page(PAGE_CHECK);
    start_action("check");
    uint64_t last = now_ms();
    for (;;) {
        uint64_t now = now_ms();
        lv_tick_inc((uint32_t)(now - last));
        last = now;
        poll_child();
        lv_timer_handler();
        if (page_now == PAGE_REBOOT && now >= reboot_at) {
#ifdef OC_DEMO
            show_page(PAGE_MODE);
            set_status("Demo reboot complete; no host reboot was performed");
#else
            sync();
            execl("/sbin/reboot", "reboot", (char *)NULL);
            show_page(PAGE_ERROR);
            set_status("Automatic reboot failed; reboot manually");
#endif
        }
        struct timespec nap = { .tv_sec = 0, .tv_nsec = 20000000 };
        nanosleep(&nap, NULL);
    }
}
