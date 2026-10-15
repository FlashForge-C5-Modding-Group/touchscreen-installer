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
#include "logo.h"
#include "platform.h"

enum page { PAGE_CHECK, PAGE_MODE, PAGE_WEB, PAGE_TOUCHSCREEN, PAGE_READY,
            PAGE_RUNNING, PAGE_DONE, PAGE_ERROR, PAGE_RESTORE, PAGE_KERNEL };
static enum page page_now;
static const char *payload_path, *backup_path, *script_path;
static const char *mode = "soc", *web = "fluidd";
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
static lv_obj_t *brand_label, *splash_logo, *notice_label, *progress_bar;
static lv_obj_t *log_panel, *log_view, *log_label;
static pid_t child_pid = -1;
static int child_fd = -1;
static char linebuf[1024];
static size_t line_len;
static char current_action[16];
static bool kernel_ok;
static char kernel_text[160] = "unknown";
static uint64_t running_since, splash_until;
static char machine[32] = "unknown";
static bool model_known;
static char backup_found[512];
static char warn_text[1024];
static char log_text[12288];
static size_t log_len;
static FILE *log_file;

#define OC_COLOR_BG       0x151a22
#define OC_COLOR_CARD     0x1f2630
#define OC_COLOR_TRACK    0x2d3644
#define OC_COLOR_ACCENT   0x4fd1a5
#define OC_COLOR_PRIMARY  0x3d8bfd
#define OC_COLOR_DANGER   0xef5b5b
#define OC_COLOR_WARN     0xf2c14e
#define OC_COLOR_MUTED    0x8894a3
#define OC_COLOR_TEXT     0xe9edf2
#define OC_COLOR_LOGO     0xf5f2ec

/* Steps shown in the breadcrumb depend on the branch taken: Tunnel
 * skips the web UI and touchscreen questions that SoC mode asks. */
static void step_info(enum page p, int *step, int *total)
{
    bool soc = strcmp(mode, "soc") == 0;
    *total = soc ? 5 : 4;
    switch (p) {
    case PAGE_MODE:     *step = 1; break;
    case PAGE_WEB:        *step = 2; break;
    case PAGE_TOUCHSCREEN: *step = soc ? 3 : 2; break;
    case PAGE_READY:    *step = soc ? 4 : 3; break;
    case PAGE_RUNNING:
    case PAGE_DONE:
    case PAGE_ERROR:    *step = *total; break;
    default:            *step = 0; break;
    }
}

static const char *page_icon(enum page p)
{
    switch (p) {
    case PAGE_DONE:  return LV_SYMBOL_OK;
    case PAGE_ERROR:
    case PAGE_KERNEL: return LV_SYMBOL_WARNING;
    case PAGE_RUNNING: return LV_SYMBOL_DOWNLOAD;
    case PAGE_MODE:  return LV_SYMBOL_SETTINGS;
    case PAGE_WEB:
    case PAGE_TOUCHSCREEN: return LV_SYMBOL_EDIT;
    case PAGE_READY: return LV_SYMBOL_PLAY;
    case PAGE_RESTORE: return LV_SYMBOL_LOOP;
    default:         return LV_SYMBOL_HOME;
    }
}

static const char *model_name(void)
{
    if (strcmp(machine, "Creator5Pro") == 0) return "Creator 5 Pro";
    if (strcmp(machine, "Creator5") == 0) return "Creator 5";
    return "Unknown model";
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

static void refresh_log_view(void)
{
    if (lv_obj_has_flag(log_panel, LV_OBJ_FLAG_HIDDEN)) return;
    lv_label_set_text_static(log_label, log_text);
    lv_obj_update_layout(log_view);
    lv_obj_scroll_to_y(log_view, LV_COORD_MAX, LV_ANIM_OFF);
}

/* Keeps the newest output on screen and appends everything to the log file. */
static void log_line(const char *line)
{
    size_t n = strnlen(line, 512);
    if (log_len + n + 2 > sizeof(log_text)) {
        char *cut = memchr(log_text + log_len / 2, '\n', log_len - log_len / 2);
        size_t drop = cut ? (size_t)(cut - log_text) + 1 : log_len;
        memmove(log_text, log_text + drop, log_len - drop);
        log_len -= drop;
    }
    memcpy(log_text + log_len, line, n);
    log_len += n;
    log_text[log_len++] = '\n';
    log_text[log_len] = '\0';
    if (log_file) {
        time_t t = time(NULL);
        struct tm tm;
        localtime_r(&t, &tm);
        fprintf(log_file, "%04d-%02d-%02d %02d:%02d:%02d [%s] %.*s\n",
                tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour,
                tm.tm_min, tm.tm_sec, current_action, (int)n, line);
        fflush(log_file);
    }
    refresh_log_view();
}

static void open_log_file(void)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/opencreator-installer.log", backup_path);
    log_file = fopen(path, "a");
    if (!log_file) log_file = fopen("/tmp/opencreator-installer.log", "a");
}

static void clear_buttons(void)
{
    lv_obj_clean(button_row);
}

static void show_page(enum page next);

static void update_brand(void)
{
    static char buf[64];
    snprintf(buf, sizeof(buf), "OPENCREATOR  |  %s", model_name());
    lv_label_set_text(brand_label, buf);
}

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
        execl("/bin/sh", "sh", script_path, action,
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
    if (strcmp(action, "check") == 0) {
        warn_text[0] = '\0';
        splash_until = now_ms() + 1500;
        backup_found[0] = '\0';
    } else {
        lv_bar_set_range(progress_bar, 0, 1);
        lv_bar_set_value(progress_bar, 0, LV_ANIM_OFF);
        running_since = now_ms();
        show_page(PAGE_RUNNING);
    }
}

static void request_reboot(void)
{
#ifdef OC_DEMO
    set_status("Demo mode: reboot skipped");
#else
    set_status("Rebooting...");
    lv_refr_now(NULL);
    sync();
    execl("/sbin/reboot", "reboot", (char *)NULL);
    set_status_error("Automatic reboot failed; reboot manually");
#endif
}

static void action_button(lv_event_t *event)
{
    const char *action = lv_event_get_user_data(event);
    if (strcmp(action, "soc") == 0) { mode = "soc"; show_page(PAGE_WEB); }
    else if (strcmp(action, "tunnel") == 0) {
        mode = "tunnel"; web = "none"; show_page(PAGE_TOUCHSCREEN);
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
    else if (strcmp(action, "restore-confirm") == 0) show_page(PAGE_RESTORE);
    else if (strcmp(action, "restore") == 0) { demo_root = NULL; start_action("restore"); }
    else if (strcmp(action, "restart") == 0) {
        demo_root = NULL; show_page(PAGE_CHECK); start_action("check");
    } else if (strcmp(action, "reboot") == 0) request_reboot();
    else if (strcmp(action, "log-open") == 0) {
        lv_obj_clear_flag(log_panel, LV_OBJ_FLAG_HIDDEN);
        refresh_log_view();
    } else if (strcmp(action, "log-close") == 0) {
        lv_obj_add_flag(log_panel, LV_OBJ_FLAG_HIDDEN);
    }
}

static lv_obj_t *make_button(lv_obj_t *parent, const char *text, const char *action,
                             bool primary, lv_coord_t w, lv_coord_t h)
{
    lv_obj_t *button = lv_btn_create(parent);
    lv_obj_set_size(button, w, h);
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
    return button;
}

/* "Back", "No", "Restore" and "Mainsail" are secondary; every other action is the
 * page's primary (forward-moving) action. */
static void add_button(const char *text, const char *action)
{
    bool secondary = strcmp(action, "back") == 0 || strcmp(action, "touch-no") == 0 ||
                     strcmp(action, "restore-confirm") == 0 || strcmp(action, "mainsail") == 0;
    make_button(button_row, text, action, !secondary, 220, 58);
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
    lv_obj_add_flag(progress_bar, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(notice_label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_add_flag(splash_logo, LV_OBJ_FLAG_HIDDEN);
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
    bool restoring = strcmp(current_action, "restore") == 0;

    switch (next) {
    case PAGE_CHECK:
        set_title(next, "OpenCreator installer");
        lv_label_set_text(body_label, "Checking the printer...");
        lv_obj_clear_flag(splash_logo, LV_OBJ_FLAG_HIDDEN);
        break;
    case PAGE_KERNEL:
        set_title(next, "Unsupported FlashForge firmware");
        {
            static char buf[480];
            snprintf(buf, sizeof(buf),
                     "This printer's kernel package is %s. OpenCreator needs kernel package "
                     "2.0.1 to 2.0.7 to enable legacy NaN for Entware (FlashForge 1.9.9 has 2.0.7). "
                     "Install the stock 1.9.9 update from FlashForge, then run this installer again. "
                     "Nothing has been changed.", kernel_text);
            lv_label_set_text(body_label, buf);
        }
        add_button("Check again", "restart");
        break;
    case PAGE_MODE:
        set_title(next, "Where should Klipper run?");
        lv_label_set_text(body_label, "Choose on-device installation or tunnel to another host.");
        if (warn_text[0]) {
            lv_label_set_text_static(notice_label, warn_text);
            lv_obj_clear_flag(notice_label, LV_OBJ_FLAG_HIDDEN);
        }
        add_button("On printer SoC", "soc");
        add_button("Tunneled", "tunnel");
        if (backup_found[0]) add_button(LV_SYMBOL_LOOP "  Restore backup", "restore-confirm");
        break;
    case PAGE_WEB:
        set_title(next, "Choose web interface");
        lv_label_set_text(body_label, "This selection is for the on-printer installation.");
        add_button("Fluidd (recommended)", "fluidd");
        add_button("Mainsail", "mainsail");
        break;
    case PAGE_TOUCHSCREEN:
        set_title(next, "Install touchscreen UI?");
        lv_label_set_text(body_label, strcmp(mode, "soc") == 0
            ? "GrumpyScreen is recommended for on-printer control."
            : "GrumpyScreen runs on the printer's screen and controls Klipper on your SBC. "
              "After installing, point its config in /usr/data/grumpyscreen/ at the SBC.");
        add_button("Yes (recommended)", "touch-yes");
        add_button("No", "touch-no");
        break;
    case PAGE_READY:
        set_title(next, "Ready to install");
        lv_label_set_text(body_label, !model_known
            ? "The printer model could not be detected, so installation is blocked. "
              "/usr/prog/app_startup.sh must declare Creator5 (PID 0028) or "
              "Creator5Pro (PID 0029)."
#ifdef OC_DEMO
            : "Existing program and config directories are backed up first. "
              "\"Demo install\" runs every step for real but writes under "
              OC_DEMO_INSTALL_ROOT " instead of the real system, so you can "
              "inspect exactly what it does first."
#else
            : "Existing program and config directories are backed up first. The printer "
              "needs internet: Entware and everything else is downloaded during install."
#endif
        );
        lv_obj_clear_flag(summary_box, LV_OBJ_FLAG_HIDDEN);
        add_summary_row("Printer", model_name());
        add_summary_row("Mode", strcmp(mode, "soc") == 0 ? "Printer SoC" : "Tunneled SBC");
        if (strcmp(mode, "soc") == 0) add_summary_row("Web UI", web);
        add_summary_row("Touchscreen",
                         strcmp(touchscreen, "yes") == 0 ? "GrumpyScreen" : "None");
        add_button("Back", "back");
#ifdef OC_DEMO
        add_button("Demo install", "demo-install");
#endif
        if (model_known) add_button("Back up and install", "install");
        break;
    case PAGE_RESTORE:
        set_title(next, "Restore previous backup?");
        {
            static char buf[700];
            snprintf(buf, sizeof(buf),
                     "Klipper, PROGRAM, config and web UI folders will be replaced with "
                     "the copies in:\n%s\nMCU firmware is not rolled back.", backup_found);
            lv_label_set_text(body_label, buf);
        }
        add_button("Back", "back");
        add_button("Restore now", "restore");
        break;
    case PAGE_RUNNING:
        set_title(next, restoring ? "Restoring backup"
                        : demo_root ? "Demo installing" : "Installing");
        lv_label_set_text(body_label, demo_root
            ? "Follow the live status below. Writing to " OC_DEMO_INSTALL_ROOT
              ", not the real system -- safe to power off."
            : "Follow the live status below. Do not power off.");
        lv_obj_clear_flag(spinner, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(progress_bar, LV_OBJ_FLAG_HIDDEN);
        break;
    case PAGE_DONE:
        if (restoring) {
            set_title(next, "Restore complete");
            lv_label_set_text(body_label, "The backed-up folders are back in place. Reboot to start the restored stack.");
        } else {
            set_title(next, demo_root ? "Demo install complete" : "Installation complete");
            lv_label_set_text(body_label, demo_root
                ? "Nothing on the real system was touched. Inspect the files it would "
                  "have written at " OC_DEMO_INSTALL_ROOT "."
                : "Reboot to start OpenCreator. Unplug the installer USB drive once you're "
                  "done -- leaving it plugged in risks it being picked up again on the next boot.");
            if (strcmp(mode, "tunnel") == 0 && strcmp(touchscreen, "yes") == 0) {
                lv_label_set_text_static(notice_label,
                    "Touchscreen: edit /usr/data/grumpyscreen/grumpyscreen.cfg and set "
                    "host under [moonraker] to your SBC's IP address, then reboot. "
                    "Until then the screen can't reach Klipper.");
                lv_obj_clear_flag(notice_label, LV_OBJ_FLAG_HIDDEN);
            }
        }
        if (!demo_root) add_button(LV_SYMBOL_POWER "  Reboot now", "reboot");
        break;
    case PAGE_ERROR:
        set_title(next, restoring ? "Restore stopped" : "Installation stopped");
        lv_label_set_text(body_label, "No later stages were run. Open the log for details and check the backup before retrying.");
        add_button("Start over", "restart");
        if (backup_found[0] && strcmp(current_action, "install") == 0 && !demo_root)
            add_button(LV_SYMBOL_LOOP "  Restore backup", "restore-confirm");
        break;
    }
}

static void process_line(char *line)
{
    log_line(line);
    if (strncmp(line, "KERNEL ", 7) == 0) {
        kernel_ok = strncmp(line + 7, "OK ", 3) == 0;
        const char *ver = strchr(line + 7, ' ');
        snprintf(kernel_text, sizeof(kernel_text), "%.150s", ver ? ver + 1 : "unknown");
    }
    if (strncmp(line, "STAGE ", 6) == 0) set_status(line + 6);
    else if (strncmp(line, "ERROR ", 6) == 0) set_status_error(line + 6);
    else if (strncmp(line, "MODEL ", 6) == 0) {
        char m[32] = "", p[16] = "";
        sscanf(line + 6, "%31s %15s", m, p);
        model_known = (strcmp(m, "Creator5Pro") == 0 && strcmp(p, "0029") == 0) ||
                      (strcmp(m, "Creator5") == 0 && strcmp(p, "0028") == 0);
        snprintf(machine, sizeof(machine), "%s", model_known ? m : "unknown");
        update_brand();
    } else if (strncmp(line, "WARN ", 5) == 0) {
        size_t len = strlen(warn_text);
        snprintf(warn_text + len, sizeof(warn_text) - len, "%s" LV_SYMBOL_WARNING "  %.200s",
                 len ? "\n" : "", line + 5);
    } else if (strncmp(line, "BACKUP ", 7) == 0) {
        snprintf(backup_found, sizeof(backup_found), "%.500s", line + 7);
    } else if (strncmp(line, "PROGRESS ", 9) == 0) {
        int n, total;
        if (sscanf(line + 9, "%d %d", &n, &total) == 2 && total > 0 && n >= 0) {
            lv_bar_set_range(progress_bar, 0, total);
            lv_bar_set_value(progress_bar, n > total ? total : n, LV_ANIM_ON);
        }
    }
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
    if (strcmp(current_action, "check") == 0 && now_ms() < splash_until) return;
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
        show_page(kernel_ok ? PAGE_MODE : PAGE_KERNEL);
    } else {
        show_page(PAGE_DONE);
    }
}

static void update_elapsed(void)
{
    static char buf[32];
    unsigned secs = (unsigned)((now_ms() - running_since) / 1000u);
    snprintf(buf, sizeof(buf), "Elapsed %u:%02u", secs / 60u, secs % 60u);
    if (strcmp(lv_label_get_text(step_label), buf) != 0)
        lv_label_set_text(step_label, buf);
}

/* The touchscreen (goodix-ts) is not always event0; OC_TOUCH_DEV overrides. */
static const char *touch_device(void)
{
    static char path[64] = "/dev/input/event0";
    const char *env = getenv("OC_TOUCH_DEV");
    if (env && env[0]) return env;
    FILE *devices = fopen("/proc/bus/input/devices", "r");
    if (!devices) return path;
    char line[256];
    bool touch = false;
    while (fgets(line, sizeof(line), devices)) {
        if (strncmp(line, "N: Name=", 8) == 0) {
            touch = strstr(line, "goodix") || strstr(line, "ouch");
        } else if (touch && strncmp(line, "H: Handlers=", 12) == 0) {
            const char *event = strstr(line, "event");
            int n;
            if (event && sscanf(event, "event%d", &n) == 1) {
                snprintf(path, sizeof(path), "/dev/input/event%d", n);
                break;
            }
        }
    }
    fclose(devices);
    return path;
}

static void build_log_panel(lv_obj_t *screen, uint32_t width, uint32_t height)
{
    log_panel = lv_obj_create(screen);
    lv_obj_set_size(log_panel, width, height);
    lv_obj_set_pos(log_panel, 0, 0);
    lv_obj_set_style_bg_color(log_panel, lv_color_hex(OC_COLOR_BG), 0);
    lv_obj_set_style_border_width(log_panel, 0, 0);
    lv_obj_set_style_radius(log_panel, 0, 0);
    lv_obj_set_style_pad_all(log_panel, 0, 0);
    lv_obj_clear_flag(log_panel, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_add_flag(log_panel, LV_OBJ_FLAG_HIDDEN);

    lv_obj_t *title = lv_label_create(log_panel);
    lv_label_set_text(title, LV_SYMBOL_LIST "  Installer log");
    lv_obj_set_style_text_color(title, lv_color_white(), 0);
    lv_obj_set_style_text_font(title, &lv_font_montserrat_24, 0);
    lv_obj_align(title, LV_ALIGN_TOP_LEFT, 30, 22);

    lv_obj_t *close = make_button(log_panel, LV_SYMBOL_CLOSE "  Close", "log-close",
                                  true, 130, 44);
    lv_obj_align(close, LV_ALIGN_TOP_RIGHT, -20, 14);

    log_view = lv_obj_create(log_panel);
    lv_obj_set_size(log_view, width - 40, height - 90);
    lv_obj_align(log_view, LV_ALIGN_BOTTOM_MID, 0, -16);
    lv_obj_set_style_bg_color(log_view, lv_color_hex(OC_COLOR_CARD), 0);
    lv_obj_set_style_border_width(log_view, 0, 0);
    lv_obj_set_style_radius(log_view, 10, 0);
    lv_obj_set_style_pad_all(log_view, 12, 0);

    log_label = lv_label_create(log_view);
    lv_obj_set_width(log_label, lv_pct(100));
    lv_label_set_long_mode(log_label, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_color(log_label, lv_color_hex(OC_COLOR_TEXT), 0);
    lv_label_set_text_static(log_label, log_text);
}

int main(int argc, char **argv)
{
#ifdef OC_DEMO
    (void)argc;
    (void)argv;
    payload_path = "payload-template";
    backup_path = "/tmp/opencreator-installer-demo";
    script_path = "scripts/demo.sh";
#else
    if (argc != 4) {
        fprintf(stderr, "usage: %s PAYLOAD_DIR BACKUP_DIR INSTALL_SCRIPT\n", argv[0]);
        return 2;
    }
    payload_path = argv[1];
    backup_path = argv[2];
    script_path = argv[3];
#endif
    open_log_file();
    lv_init();
    uint32_t width = 800, height = 480;
    if (platform_init("/dev/fb0", touch_device(), &width, &height) != 0) {
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

    lv_obj_t *header_logo = lv_img_create(screen);
    lv_img_set_src(header_logo, &oc_logo_small);
    lv_obj_set_style_img_recolor(header_logo, lv_color_hex(OC_COLOR_LOGO), 0);
    lv_obj_set_style_img_recolor_opa(header_logo, LV_OPA_COVER, 0);
    lv_obj_align(header_logo, LV_ALIGN_TOP_LEFT, 30, 10);

    brand_label = lv_label_create(screen);
    lv_obj_set_style_text_color(brand_label, lv_color_hex(OC_COLOR_MUTED), 0);
    update_brand();
    lv_obj_align_to(brand_label, header_logo, LV_ALIGN_OUT_RIGHT_MID, 12, 0);

    lv_obj_t *log_button = make_button(screen, LV_SYMBOL_LIST "  Log", "log-open",
                                       false, 90, 36);
    lv_obj_align(log_button, LV_ALIGN_TOP_RIGHT, -20, 8);

    step_label = lv_label_create(screen);
    lv_obj_set_style_text_color(step_label, lv_color_hex(OC_COLOR_MUTED), 0);
    lv_obj_align(step_label, LV_ALIGN_TOP_RIGHT, -124, 18);

    title_label = lv_label_create(screen);
    lv_obj_set_width(title_label, width - 60);
    lv_obj_set_style_text_color(title_label, lv_color_white(), 0);
    lv_obj_set_style_text_font(title_label, &lv_font_montserrat_24, 0);
    lv_obj_align(title_label, LV_ALIGN_TOP_LEFT, 30, 54);

    body_label = lv_label_create(screen);
    lv_obj_set_width(body_label, width - 60);
    lv_label_set_long_mode(body_label, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_color(body_label, lv_color_hex(OC_COLOR_TEXT), 0);
    lv_obj_align(body_label, LV_ALIGN_TOP_LEFT, 30, 100);

    splash_logo = lv_img_create(screen);
    lv_img_set_src(splash_logo, &oc_logo_large);
    lv_obj_set_style_img_recolor(splash_logo, lv_color_hex(OC_COLOR_LOGO), 0);
    lv_obj_set_style_img_recolor_opa(splash_logo, LV_OPA_COVER, 0);
    lv_obj_align(splash_logo, LV_ALIGN_CENTER, 0, 14);
    lv_obj_add_flag(splash_logo, LV_OBJ_FLAG_HIDDEN);

    notice_label = lv_label_create(screen);
    lv_obj_set_width(notice_label, width - 60);
    lv_label_set_long_mode(notice_label, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_color(notice_label, lv_color_hex(OC_COLOR_WARN), 0);
    lv_obj_align(notice_label, LV_ALIGN_TOP_LEFT, 30, 150);
    lv_obj_add_flag(notice_label, LV_OBJ_FLAG_HIDDEN);

    summary_box = lv_obj_create(screen);
    lv_obj_set_size(summary_box, width - 60, 140);
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

    progress_bar = lv_bar_create(screen);
    lv_obj_set_size(progress_bar, width - 110, 14);
    lv_obj_align(progress_bar, LV_ALIGN_TOP_LEFT, 80, 171);
    lv_obj_set_style_bg_color(progress_bar, lv_color_hex(OC_COLOR_TRACK), LV_PART_MAIN);
    lv_obj_set_style_bg_color(progress_bar, lv_color_hex(OC_COLOR_ACCENT), LV_PART_INDICATOR);
    lv_obj_add_flag(progress_bar, LV_OBJ_FLAG_HIDDEN);

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

    build_log_panel(screen, width, height);

    set_status("Preparing...");
    show_page(PAGE_CHECK);
    start_action("check");
    uint64_t last = now_ms();
    for (;;) {
        uint64_t now = now_ms();
        lv_tick_inc((uint32_t)(now - last));
        last = now;
        poll_child();
        if (page_now == PAGE_RUNNING) update_elapsed();
        lv_timer_handler();
        struct timespec nap = { .tv_sec = 0, .tv_nsec = 20000000 };
        nanosleep(&nap, NULL);
    }
}
