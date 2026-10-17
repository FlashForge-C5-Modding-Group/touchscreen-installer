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
            PAGE_RUNNING, PAGE_DONE, PAGE_ERROR, PAGE_RESTORE, PAGE_KERNEL,
            PAGE_INSTALLED, PAGE_ROLLBACK, PAGE_UPDATE };
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
static char installer_version[32] = "?";
static char mcu_drive[48] = "none", mcu_boards[48] = "none";
static lv_obj_t *version_label;
static uint64_t running_since, splash_until;
/* The running step (from install.sh's "Running NN-name.sh" and PROGRESS
 * lines), shown next to the Log button; run_secs is the finished run's time. */
static char step_name[48];
static int step_done, step_total;
static unsigned run_secs;
static char machine[32] = "unknown";
static bool model_known;
static char backup_found[512];
static char stock_found[512];
/* From the install record. When it was made by this installer version,
 * the start page offers Recovery (the full setup) or Update Configs (only
 * what changed, via the "reconfigure" action). */
static char prev_version[32], prev_mode[16], prev_web[16], prev_touch[8];
static bool installed_same, update_configs;
/* An install record from a different installer version: the start page is
 * "Update available", which reinstalls with the recorded setup. */
static bool update_available;
static bool space_low;
/* FlashForge firmware version; Tunneled needs 1.9.9 or newer. */
static char ff_version[32] = "unknown";
static bool tunnel_blocked;
static int space_mb;
static char warn_text[1024];
static char log_text[12288];
static size_t log_len;
static FILE *log_files[2];

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
    case PAGE_RESTORE:
    case PAGE_ROLLBACK: return LV_SYMBOL_LOOP;
    case PAGE_UPDATE: return LV_SYMBOL_UPLOAD;
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

/* "15-install-moonraker.sh" -> "Moonraker" for the label next to Log. */
static void set_step_name(const char *script)
{
    static const char *const names[][2] = {
        {"install-entware", "Entware"}, {"install-loopscript", "LoopScript"},
        {"install-python", "Python"}, {"install-stack", "Kalico"},
        {"install-moonraker", "Moonraker"}, {"install-web", "Web UI"},
        {"install-grumpyscreen", "Touchscreen"}, {"install-tunnel", "Tunnel bridge"},
        {"enable-root", "Root login"}, {"activate-loopscript", "Activating"},
        {"flash-mcu-firmware", "MCU firmware"},
    };
    const char *base = strrchr(script, '/');
    base = base ? base + 1 : script;
    const char *dash = strchr(base, '-');
    if (dash && dash - base <= 3) base = dash + 1;   /* drop the "NN-" order prefix */
    size_t len = strcspn(base, ".");
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        if (strlen(names[i][0]) == len && strncmp(base, names[i][0], len) == 0) {
            snprintf(step_name, sizeof(step_name), "%s", names[i][1]);
            return;
        }
    }
    snprintf(step_name, sizeof(step_name), "%.*s", (int)(len < 40 ? len : 40), base);
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
static uint64_t log_synced;

static void sync_log_files(void)
{
    for (int i = 0; i < 2; i++)
        if (log_files[i]) fsync(fileno(log_files[i]));
    log_synced = now_ms();
}

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
    time_t t = time(NULL);
    struct tm tm;
    localtime_r(&t, &tm);
    bool urgent = strncmp(line, "ERROR ", 6) == 0;
    for (int i = 0; i < 2; i++) {
        if (!log_files[i]) continue;
        fprintf(log_files[i], "%04d-%02d-%02d %02d:%02d:%02d [%s] %.*s\n",
                tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour,
                tm.tm_min, tm.tm_sec, current_action, (int)n, line);
        fflush(log_files[i]);
    }
    if (urgent || now_ms() - log_synced > 2000) sync_log_files();
    refresh_log_view();
}

/* The log on the USB drive (FAT, page cache) is fsync'd so it survives the
 * drive being pulled or the printer being switched off after an error; the
 * copy on /usr/data (mounted with sync) is written through immediately. */
static void open_log_file(void)
{
    char path[512];
    snprintf(path, sizeof(path), "%s/opencreator-installer.log", backup_path);
    log_files[0] = fopen(path, "a");
    if (!log_files[0]) log_files[0] = fopen("/tmp/opencreator-installer.log", "a");
#ifndef OC_DEMO
    log_files[1] = fopen("/usr/data/logs/opencreator-installer.log", "a");
#endif
}

static void clear_buttons(void)
{
    lv_obj_clean(button_row);
}

static void show_page(enum page next);
static void format_duration(char *buf, size_t size, unsigned secs);

static void update_brand(void)
{
    static char buf[64];
    snprintf(buf, sizeof(buf), "OPENCREATOR  |  %s", model_name());
    lv_label_set_text(brand_label, buf);
}

static void update_version(void)
{
    static char buf[256];
    char boards[64] = "";
    if (strcmp(mcu_boards, "none") != 0)
        snprintf(boards, sizeof(boards), " (boards %.8s)", mcu_boards);
    snprintf(buf, sizeof(buf), "Installer %s  |  MCU firmware %.8s%s  |  Kernel %.40s  |  Built %s",
             installer_version, mcu_drive, boards, kernel_text, __DATE__);
    lv_label_set_text(version_label, buf);
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
        stock_found[0] = '\0';
        installed_same = update_configs = update_available = space_low = tunnel_blocked = false;
        prev_version[0] = '\0';
    } else {
        lv_bar_set_range(progress_bar, 0, 1);
        lv_bar_set_value(progress_bar, 0, LV_ANIM_OFF);
        step_name[0] = '\0';
        step_done = step_total = 0;
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
    } else if (strcmp(action, "install") == 0) {
        demo_root = NULL; unsetenv("OC_SKIP_BACKUP"); start_action("install");
    } else if (strcmp(action, "install-nobackup") == 0) {
        demo_root = NULL; setenv("OC_SKIP_BACKUP", "1", 1); start_action("install");
    } else if (strcmp(action, "demo-install") == 0) {
        demo_root = OC_DEMO_INSTALL_ROOT; unsetenv("OC_SKIP_BACKUP"); start_action("install");
    } else if (strcmp(action, "update") == 0 || strcmp(action, "update-nobackup") == 0) {
        /* Same setup as the install record, no questions asked. */
        mode = prev_mode; web = prev_web; touchscreen = prev_touch;
        demo_root = NULL;
        if (strcmp(action, "update") == 0) unsetenv("OC_SKIP_BACKUP");
        else setenv("OC_SKIP_BACKUP", "1", 1);
        start_action("install");
    } else if (strcmp(action, "update-home") == 0) show_page(PAGE_UPDATE);
    else if (strcmp(action, "recovery") == 0 || strcmp(action, "change-setup") == 0) {
        update_configs = false; show_page(PAGE_MODE);
    } else if (strcmp(action, "update-configs") == 0) {
        update_configs = true;
        mode = prev_mode; web = prev_web; touchscreen = prev_touch;
        show_page(PAGE_MODE);
    } else if (strcmp(action, "reconfigure") == 0) {
        demo_root = NULL; unsetenv("OC_SKIP_BACKUP"); start_action("reconfigure");
    } else if (strcmp(action, "home") == 0) show_page(PAGE_INSTALLED);
    else if (strcmp(action, "back") == 0) show_page(PAGE_MODE);
    else if (strcmp(action, "restore-confirm") == 0) show_page(PAGE_RESTORE);
    else if (strcmp(action, "rollback-confirm") == 0) show_page(PAGE_ROLLBACK);
    else if (strcmp(action, "rollback") == 0) { demo_root = NULL; start_action("rollback"); }
    else if (strcmp(action, "start") == 0)
        show_page(installed_same && model_known ? PAGE_INSTALLED
                  : update_available && model_known ? PAGE_UPDATE : PAGE_MODE);
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

/* "Back", "No", "Restore", "Mainsail" and "Install without backup" are
 * secondary; every other action is the page's primary (forward-moving) action. */
static lv_obj_t *add_button(const char *text, const char *action)
{
    bool secondary = strcmp(action, "back") == 0 || strcmp(action, "touch-no") == 0 ||
                     strcmp(action, "home") == 0 || strcmp(action, "recovery") == 0 ||
                     strcmp(action, "rollback-confirm") == 0 || strcmp(action, "start") == 0 ||
                     strcmp(action, "restore-confirm") == 0 || strcmp(action, "mainsail") == 0 ||
                     strcmp(action, "install-nobackup") == 0 ||
                     strcmp(action, "update-nobackup") == 0 ||
                     strcmp(action, "update-home") == 0 || strcmp(action, "change-setup") == 0;
    return make_button(button_row, text, action, !secondary, 220, 58);
}

/* Greyed out and not clickable. */
static void disable_button(lv_obj_t *button)
{
    lv_obj_add_state(button, LV_STATE_DISABLED);
    lv_obj_set_style_bg_color(button, lv_color_hex(OC_COLOR_TRACK), LV_STATE_DISABLED);
    lv_obj_set_style_border_width(button, 0, LV_STATE_DISABLED);
    lv_obj_set_style_text_color(lv_obj_get_child(button, 0), lv_color_hex(OC_COLOR_MUTED), 0);
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
    if ((next == PAGE_DONE || next == PAGE_ERROR) && strcmp(current_action, "check") != 0) {
        char took[16];
        format_duration(took, sizeof(took), run_secs);
        snprintf(step_buf, sizeof(step_buf), "%s %s",
                 next == PAGE_DONE ? "Finished in" : "Stopped after", took);
    }
    lv_label_set_text(step_label, step_buf);
    bool restoring = strcmp(current_action, "restore") == 0;
    bool reconfiguring = strcmp(current_action, "reconfigure") == 0;
    bool rolling_back = strcmp(current_action, "rollback") == 0;

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
    case PAGE_UPDATE:
        {
            static char title[96], from_to[80], setup[96];
            bool tunnel = strcmp(prev_mode, "tunnel") == 0;
            snprintf(title, sizeof(title), "Update available:  %s  " LV_SYMBOL_RIGHT "  %s",
                     prev_version, installer_version);
            set_title(next, title);
            lv_label_set_text(body_label,
                "Updates OpenCreator in place with your current setup. Your configs and "
                "files are kept; OpenCreator files you changed are saved to the backup.");
            lv_obj_clear_flag(summary_box, LV_OBJ_FLAG_HIDDEN);
            add_summary_row("Installed", prev_version);
            snprintf(from_to, sizeof(from_to), "%s (new)", installer_version);
            add_summary_row("This installer", from_to);
            snprintf(setup, sizeof(setup), "%s%s%s, touchscreen %s",
                     tunnel ? "Tunneled" : "Printer SoC", tunnel ? "" : ", ",
                     tunnel ? "" : prev_web, strcmp(prev_touch, "yes") == 0 ? "on" : "off");
            add_summary_row("Setup kept", setup);
            if (warn_text[0]) {
                lv_label_set_text_static(notice_label, warn_text);
                lv_obj_clear_flag(notice_label, LV_OBJ_FLAG_HIDDEN);
            }
            add_button("Change setup", "change-setup");
            lv_obj_t *nobackup = add_button("Update without backup", "update-nobackup");
            lv_obj_t *update = add_button(LV_SYMBOL_UPLOAD "  Back up and update", "update");
            /* Tunneled needs FlashForge 1.9.9; the backend refuses it too. */
            if (tunnel && tunnel_blocked) {
                disable_button(nobackup);
                disable_button(update);
            }
            if (stock_found[0]) add_button(LV_SYMBOL_REFRESH "  Rollback to stock", "rollback-confirm");
        }
        break;
    case PAGE_INSTALLED:
        set_title(next, "OpenCreator is up to date");
        {
            static char buf[400];
            snprintf(buf, sizeof(buf),
                     "OpenCreator %s is already installed: %s, web UI %s, touchscreen %s.\n"
                     "Recovery runs the whole setup again. Update Configs lets you pick the "
                     "settings again and only changes what is different.",
                     prev_version, strcmp(prev_mode, "soc") == 0 ? "printer SoC" : "tunneled",
                     prev_web, prev_touch);
            lv_label_set_text(body_label, buf);
        }
        add_button("Recovery", "recovery");
        add_button("Update Configs", "update-configs");
        if (backup_found[0]) add_button(LV_SYMBOL_LOOP "  Restore backup", "restore-confirm");
        if (stock_found[0]) add_button(LV_SYMBOL_REFRESH "  Rollback to stock", "rollback-confirm");
        break;
    case PAGE_MODE:
        set_title(next, "Where should Klipper run?");
        {
            static char buf[320];
            snprintf(buf, sizeof(buf), "%s%s%s%s",
                     update_configs
                         ? (strcmp(prev_mode, "soc") == 0 ? "Currently: on the printer SoC."
                                                           : "Currently: tunneled to another host.")
                         : "Choose on-device installation or tunnel to another host.",
                     tunnel_blocked ? "\nTunneled needs FlashForge firmware 1.9.9 (this printer has " : "",
                     tunnel_blocked ? ff_version : "",
                     tunnel_blocked ? "). Update the printer to 1.9.9 to use it." : "");
            lv_label_set_text(body_label, buf);
        }
        if (warn_text[0]) {
            lv_label_set_text_static(notice_label, warn_text);
            lv_obj_clear_flag(notice_label, LV_OBJ_FLAG_HIDDEN);
        }
        if (installed_same) add_button("Back", "home");
        else if (update_available && model_known) add_button("Back", "update-home");
        add_button("On printer SoC", "soc");
        {
            lv_obj_t *tunnel = add_button("Tunneled", "tunnel");
            if (tunnel_blocked) disable_button(tunnel);
        }
        if (backup_found[0] && !installed_same)
            add_button(LV_SYMBOL_LOOP "  Restore backup", "restore-confirm");
        if (stock_found[0] && !installed_same)
            add_button(LV_SYMBOL_REFRESH "  Rollback to stock", "rollback-confirm");
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
        if (update_configs) {
            static char rows[3][96];
            int changes = 0;
            set_title(next, "Update Configs");
            lv_obj_clear_flag(summary_box, LV_OBJ_FLAG_HIDDEN);
            if (strcmp(mode, prev_mode) != 0) {
                snprintf(rows[changes], sizeof(rows[0]), "%s  " LV_SYMBOL_RIGHT "  %s",
                         strcmp(prev_mode, "soc") == 0 ? "Printer SoC" : "Tunneled",
                         strcmp(mode, "soc") == 0 ? "Printer SoC" : "Tunneled");
                add_summary_row("Mode", rows[changes++]);
            }
            if (strcmp(mode, "soc") == 0 && strcmp(web, prev_web) != 0) {
                snprintf(rows[changes], sizeof(rows[0]), "%s  " LV_SYMBOL_RIGHT "  %s",
                         prev_web, web);
                add_summary_row("Web UI", rows[changes++]);
            }
            if (strcmp(touchscreen, prev_touch) != 0) {
                snprintf(rows[changes], sizeof(rows[0]), "%s  " LV_SYMBOL_RIGHT "  %s",
                         strcmp(prev_touch, "yes") == 0 ? "GrumpyScreen" : "None",
                         strcmp(touchscreen, "yes") == 0 ? "GrumpyScreen" : "None");
                add_summary_row("Touchscreen", rows[changes++]);
            }
            lv_label_set_text(body_label, changes == 0
                ? "Nothing is different from the current setup."
                : "Only these changes are applied; nothing is backed up or reinstalled. "
                  "Anything the new setup needs that is not on the printer yet is "
                  "downloaded, so the printer needs internet.");
            add_button("Back", "back");
            if (changes > 0 && model_known) add_button("Apply changes", "reconfigure");
            break;
        }
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
        if (warn_text[0]) {
            lv_label_set_text_static(notice_label, warn_text);
            lv_obj_clear_flag(notice_label, LV_OBJ_FLAG_HIDDEN);
        }
        add_button("Back", "back");
#ifdef OC_DEMO
        add_button("Demo install", "demo-install");
#endif
        /* A new install (no previous OpenCreator) needs 2 GB free. */
        if (space_low && !prev_version[0]) {
            static char buf[256];
            snprintf(buf, sizeof(buf),
                     "Not enough free space: only %d MB free on the printer, and a new install "
                     "needs 2 GB. Free up space on /usr/data, then check again.", space_mb);
            lv_label_set_text(body_label, buf);
            add_button("Check again", "restart");
            break;
        }
#ifndef OC_DEMO
        if (model_known) add_button("Install without backup", "install-nobackup");
#endif
        if (model_known) add_button("Back up and install", "install");
        break;
    case PAGE_RESTORE:
        set_title(next, "Restore previous backup?");
        {
            static char buf[700];
            snprintf(buf, sizeof(buf),
                     "FlashForge's firmwareExe, Klipper, config and web UI folders will be replaced with "
                     "the copies in:\n%s\nMCU firmware is not rolled back.", backup_found);
            lv_label_set_text(body_label, buf);
        }
        add_button("Back", "back");
        add_button("Restore now", "restore");
        break;
    case PAGE_ROLLBACK:
        set_title(next, "Roll back to stock?");
        {
            static char buf[1024];
            snprintf(buf, sizeof(buf),
                     "Only FlashForge's firmwareExe is put back, from:\n%s\n"
                     "Everything OpenCreator runs is started by its own firmwareExe, so "
                     "after a reboot the printer runs the stock firmware. OpenCreator's "
                     "files stay on the printer; install again to go back. MCU firmware "
                     "is not rolled back.", stock_found);
            lv_label_set_text(body_label, buf);
        }
        add_button("Back", "start");
        add_button("Roll back now", "rollback");
        break;
    case PAGE_RUNNING:
        set_title(next, restoring ? "Restoring backup"
                        : rolling_back ? "Rolling back to stock"
                        : reconfiguring ? "Applying changes"
                        : demo_root ? "Demo installing" : "Installing");
        lv_label_set_text(body_label, demo_root
            ? "Follow the live status below. Writing to " OC_DEMO_INSTALL_ROOT
              ", not the real system -- safe to power off."
            : rolling_back ? "Putting FlashForge's firmwareExe back. Do not power off."
            : reconfiguring
            ? "Follow the live status below and do not power off. Anything the new "
              "setup needs that is not on the printer yet is downloaded first."
            : "This may take a while (often 30 minutes or more): Entware, Python "
              "packages and the MCU firmware are installed one after another. "
              "Follow the live status below and do not power off.");
        lv_obj_clear_flag(spinner, LV_OBJ_FLAG_HIDDEN);
        lv_obj_clear_flag(progress_bar, LV_OBJ_FLAG_HIDDEN);
        break;
    case PAGE_DONE:
        if (restoring) {
            set_title(next, "Restore complete");
            lv_label_set_text(body_label, "The backed-up folders are back in place. Reboot to start the restored stack.");
        } else if (rolling_back) {
            set_title(next, "Rolled back to stock");
            lv_label_set_text(body_label, "FlashForge's firmwareExe is back. Unplug the installer "
                              "USB drive and reboot to start the stock firmware.");
        } else {
            set_title(next, demo_root ? "Demo install complete"
                            : reconfiguring ? "Changes applied" : "Installation complete");
            lv_label_set_text(body_label, demo_root
                ? "Nothing on the real system was touched. Inspect the files it would "
                  "have written at " OC_DEMO_INSTALL_ROOT "."
                : reconfiguring
                ? "Reboot to start with the new settings, and unplug the installer USB drive."
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
        set_title(next, restoring ? "Restore stopped"
                        : rolling_back ? "Rollback stopped" : "Installation stopped");
        lv_label_set_text(body_label, "No later stages were run. Open the log for details and check the backup before retrying.");
        add_button("Start over", "restart");
        if (backup_found[0] && strcmp(current_action, "install") == 0 && !demo_root)
            add_button(LV_SYMBOL_LOOP "  Restore backup", "restore-confirm");
        break;
    }

    /* Buttons are 220 px wide; narrow them (labels wrap) when more than
     * three share the row. */
    uint32_t count = lv_obj_get_child_cnt(button_row);
    if (count > 0) {
        lv_obj_update_layout(button_row);
        lv_coord_t w = (lv_obj_get_content_width(button_row) - (lv_coord_t)(count - 1) * 16) /
                       (lv_coord_t)count;
        if (w > 220) w = 220;
        for (uint32_t i = 0; i < count; i++) {
            lv_obj_t *button = lv_obj_get_child(button_row, (int32_t)i);
            lv_obj_t *label = lv_obj_get_child(button, 0);
            lv_obj_set_width(button, w);
            lv_label_set_long_mode(label, LV_LABEL_LONG_WRAP);
            lv_obj_set_width(label, w - 16);
            lv_obj_set_style_text_align(label, LV_TEXT_ALIGN_CENTER, 0);
            lv_obj_center(label);
        }
    }
}

static void process_line(char *line)
{
    log_line(line);
    if (strncmp(line, "KERNEL ", 7) == 0) {
        kernel_ok = strncmp(line + 7, "OK ", 3) == 0;
        const char *ver = strchr(line + 7, ' ');
        snprintf(kernel_text, sizeof(kernel_text), "%.150s", ver ? ver + 1 : "unknown");
        update_version();
    } else if (strncmp(line, "VERSION ", 8) == 0) {
        snprintf(installer_version, sizeof(installer_version), "%.30s", line + 8);
        update_version();
    } else if (strncmp(line, "MCU ", 4) == 0) {
        sscanf(line + 4, "%47s %47s", mcu_drive, mcu_boards);
        update_version();
    }
    if (strncmp(line, "STAGE Running ", 14) == 0) set_step_name(line + 14);
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
    } else if (strncmp(line, "PREVIOUS ", 9) == 0) {
        sscanf(line + 9, "%31s %15s %15s %7s", prev_version, prev_mode, prev_web, prev_touch);
        bool valid = (strcmp(prev_mode, "soc") == 0 || strcmp(prev_mode, "tunnel") == 0) &&
                     (strcmp(prev_touch, "yes") == 0 || strcmp(prev_touch, "no") == 0) &&
                     (strcmp(prev_mode, "tunnel") == 0 || strcmp(prev_web, "fluidd") == 0 ||
                      strcmp(prev_web, "mainsail") == 0);
        installed_same = valid && strcmp(prev_version, installer_version) == 0;
        update_available = valid && !installed_same;
    } else if (strncmp(line, "FIRMWARE ", 9) == 0) {
        int a = 0, b = 0, c = 0;
        snprintf(ff_version, sizeof(ff_version), "%.30s", line + 9);
        tunnel_blocked = sscanf(ff_version, "%d.%d.%d", &a, &b, &c) >= 2 &&
                         a * 1000000 + b * 1000 + c < 1009009;
    } else if (strncmp(line, "SPACE LOW ", 10) == 0) {
        space_low = true;
        space_mb = atoi(line + 10);
    } else if (strncmp(line, "STOCK ", 6) == 0) {
        snprintf(stock_found, sizeof(stock_found), "%.500s", line + 6);
    } else if (strncmp(line, "BACKUP ", 7) == 0) {
        snprintf(backup_found, sizeof(backup_found), "%.500s", line + 7);
    } else if (strncmp(line, "PROGRESS ", 9) == 0) {
        int n, total;
        if (sscanf(line + 9, "%d %d", &n, &total) == 2 && total > 0 && n >= 0) {
            lv_bar_set_range(progress_bar, 0, total);
            lv_bar_set_value(progress_bar, n > total ? total : n, LV_ANIM_ON);
            step_done = n;
            step_total = total;
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
    run_secs = (unsigned)((now_ms() - running_since) / 1000u);
    sync_log_files();
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        show_page(PAGE_ERROR);
    } else if (strcmp(current_action, "check") == 0) {
        show_page(!kernel_ok ? PAGE_KERNEL
                  : installed_same && model_known ? PAGE_INSTALLED
                  : update_available && model_known ? PAGE_UPDATE : PAGE_MODE);
    } else {
        show_page(PAGE_DONE);
    }
}

/* m:ss, or h:mm:ss from an hour on. */
static void format_duration(char *buf, size_t size, unsigned secs)
{
    if (secs >= 3600u)
        snprintf(buf, size, "%u:%02u:%02u", secs / 3600u, secs / 60u % 60u, secs % 60u);
    else
        snprintf(buf, size, "%u:%02u", secs / 60u, secs % 60u);
}

/* "Moonraker · Step 5/10 · 12:34" next to the Log button while running. */
static void update_elapsed(void)
{
    static char buf[128];
    char took[16];
    format_duration(took, sizeof(took), (unsigned)((now_ms() - running_since) / 1000u));
    if (step_total > 0) {
        /* PROGRESS n means n steps are done, so step n + 1 is running. */
        int step = step_done < step_total ? step_done + 1 : step_total;
        snprintf(buf, sizeof(buf), "%s%sStep %d/%d  " LV_SYMBOL_BULLET "  %s", step_name,
                 step_name[0] ? "  " LV_SYMBOL_BULLET "  " : "", step, step_total, took);
    } else {
        snprintf(buf, sizeof(buf), "Elapsed %s", took);
    }
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

/* The Creator 5 panel is a portrait framebuffer; the UI is drawn landscape
 * and rotated (display_rotate: 1).
 * OC_DISPLAY_ROTATE=0..3 overrides it. */
static lv_disp_rot_t display_rotation(uint32_t width, uint32_t height)
{
    const char *env = getenv("OC_DISPLAY_ROTATE");
    if (env && env[0] >= '0' && env[0] <= '3' && env[1] == '\0')
        return (lv_disp_rot_t)(env[0] - '0');
    return width < height ? LV_DISP_ROT_90 : LV_DISP_ROT_NONE;
}

/* Registers the framebuffer and returns the (rotated) UI size. */
static void register_display(uint32_t *width, uint32_t *height)
{
    static lv_disp_draw_buf_t draw_buf;
    static lv_disp_drv_t display;
    uint32_t longest = *width > *height ? *width : *height;
    lv_color_t *buffer = calloc(longest * 32, sizeof(lv_color_t));
    if (!buffer) exit(1);
    lv_disp_draw_buf_init(&draw_buf, buffer, NULL, longest * 32);
    lv_disp_drv_init(&display);
    display.draw_buf = &draw_buf;
    display.flush_cb = platform_flush;
    display.hor_res = *width;
    display.ver_res = *height;
    display.rotated = display_rotation(*width, *height);
    display.sw_rotate = display.rotated != LV_DISP_ROT_NONE;
    lv_disp_drv_register(&display);
    *width = lv_disp_get_hor_res(NULL);
    *height = lv_disp_get_ver_res(NULL);
}

#ifndef OC_DEMO
/* Draws the logo (and an optional status line) to the framebuffer and
 * exits; runFirmwareExe.sh shows it while the printer gets ready. */
static int show_splash(const char *message)
{
    lv_init();
    uint32_t width = 800, height = 480;
    if (platform_init("/dev/fb0", NULL, &width, &height) != 0) {
        fprintf(stderr, "framebuffer unavailable\n");
        return 1;
    }
    register_display(&width, &height);
    lv_obj_t *screen = lv_scr_act();
    lv_obj_set_style_bg_color(screen, lv_color_hex(OC_COLOR_BG), 0);
    lv_obj_t *logo = lv_img_create(screen);
    lv_img_set_src(logo, &oc_logo_large);
    lv_obj_set_style_img_recolor(logo, lv_color_hex(OC_COLOR_LOGO), 0);
    lv_obj_set_style_img_recolor_opa(logo, LV_OPA_COVER, 0);
    lv_obj_align(logo, LV_ALIGN_CENTER, 0, message ? -24 : 0);
    if (message) {
        lv_obj_t *label = lv_label_create(screen);
        lv_label_set_text(label, message);
        lv_obj_set_style_text_color(label, lv_color_hex(OC_COLOR_MUTED), 0);
        lv_obj_align_to(label, logo, LV_ALIGN_OUT_BOTTOM_MID, 0, 24);
    }
    lv_refr_now(NULL);
    return 0;
}
#endif

int main(int argc, char **argv)
{
#ifndef OC_DEMO
    if (argc >= 2 && strcmp(argv[1], "--splash") == 0)
        return show_splash(argc > 2 ? argv[2] : NULL);
#endif
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
    register_display(&width, &height);
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

    version_label = lv_label_create(screen);
    lv_obj_set_width(version_label, width - 40);
    lv_label_set_long_mode(version_label, LV_LABEL_LONG_DOT);
    lv_obj_set_style_text_align(version_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_color(version_label, lv_color_hex(OC_COLOR_MUTED), 0);
    lv_obj_align(version_label, LV_ALIGN_BOTTOM_MID, 0, -4);
    update_version();

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
