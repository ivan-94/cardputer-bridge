#include <ApplicationServices/ApplicationServices.h>

#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    CFMachPortRef tap;
    int64_t expected_keycode;
    CGEventFlags expected_modifiers;
    bool saw_down;
    bool saw_up;
    bool timed_out;
} ConsumerState;

static const CGEventFlags kRelevantModifiers =
    kCGEventFlagMaskShift |
    kCGEventFlagMaskControl |
    kCGEventFlagMaskAlternate |
    kCGEventFlagMaskCommand;

static void timeout_callback(CFRunLoopTimerRef timer, void *context) {
    (void)timer;
    ConsumerState *state = context;
    state->timed_out = true;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static CGEventRef event_callback(
    CGEventTapProxy proxy,
    CGEventType type,
    CGEventRef event,
    void *context
) {
    (void)proxy;
    ConsumerState *state = context;
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        CGEventTapEnable(state->tap, true);
        return event;
    }
    if (type != kCGEventKeyDown && type != kCGEventKeyUp) {
        return event;
    }

    const int64_t keycode = CGEventGetIntegerValueField(
        event,
        kCGKeyboardEventKeycode
    );
    if (keycode != state->expected_keycode) {
        return event;
    }

    const CGEventFlags modifiers = CGEventGetFlags(event) & kRelevantModifiers;
    const char *phase = type == kCGEventKeyDown ? "down" : "up";
    printf(
        "{\"v\":1,\"event\":\"macos_key\",\"phase\":\"%s\","
        "\"keycode\":%lld,\"modifiers\":%llu}\n",
        phase,
        (long long)keycode,
        (unsigned long long)modifiers
    );
    fflush(stdout);

    if (type == kCGEventKeyDown) {
        state->saw_down = true;
    } else if (state->saw_down) {
        state->saw_up = true;
        CFRunLoopStop(CFRunLoopGetCurrent());
    }

    // This is an active safety tap. The expected event is consumed before it
    // can type into the focused app or invoke a global shortcut such as
    // Control-Command-Q. Unrelated input always passes through unchanged.
    return NULL;
}

static bool parse_modifiers(const char *value, CGEventFlags *result) {
    if (strcmp(value, "none") == 0) {
        *result = 0;
        return true;
    }
    if (strcmp(value, "control+command") == 0) {
        *result = kCGEventFlagMaskControl | kCGEventFlagMaskCommand;
        return true;
    }
    return false;
}

static void usage(const char *program) {
    fprintf(
        stderr,
        "usage: %s [--preflight] [--keycode N "
        "--modifiers none|control+command --timeout-ms N] "
        "[--request-permission]\n",
        program
    );
}

int main(int argc, char **argv) {
    ConsumerState state = {0};
    state.expected_keycode = -1;
    int timeout_ms = 3000;
    bool modifiers_set = false;
    bool request_permission = false;
    bool preflight_only = false;

    for (int index = 1; index < argc; ++index) {
        if (strcmp(argv[index], "--keycode") == 0 && index + 1 < argc) {
            state.expected_keycode = strtoll(argv[++index], NULL, 10);
        } else if (strcmp(argv[index], "--modifiers") == 0 && index + 1 < argc) {
            modifiers_set = parse_modifiers(
                argv[++index],
                &state.expected_modifiers
            );
        } else if (strcmp(argv[index], "--timeout-ms") == 0 && index + 1 < argc) {
            timeout_ms = (int)strtol(argv[++index], NULL, 10);
        } else if (strcmp(argv[index], "--request-permission") == 0) {
            request_permission = true;
        } else if (strcmp(argv[index], "--preflight") == 0) {
            preflight_only = true;
        } else {
            usage(argv[0]);
            return 2;
        }
    }
    if ((!preflight_only && (state.expected_keycode < 0 || !modifiers_set)) ||
        timeout_ms <= 0) {
        usage(argv[0]);
        return 2;
    }

    setvbuf(stdout, NULL, _IOLBF, 0);
    if (request_permission) {
        if (!CGPreflightListenEventAccess()) {
            (void)CGRequestListenEventAccess();
        }
        if (!CGPreflightPostEventAccess()) {
            (void)CGRequestPostEventAccess();
        }
    }
    if (!CGPreflightListenEventAccess()) {
        printf("{\"result\":\"BLOCKED\","
               "\"code\":\"input_monitoring_permission_required\"}\n");
        return 2;
    }
    if (!CGPreflightPostEventAccess()) {
        printf("{\"result\":\"BLOCKED\","
               "\"code\":\"accessibility_permission_required\"}\n");
        return 2;
    }

    const CGEventMask mask =
        CGEventMaskBit(kCGEventKeyDown) |
        CGEventMaskBit(kCGEventKeyUp);
    state.tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionDefault,
        mask,
        event_callback,
        &state
    );
    if (state.tap == NULL) {
        printf("{\"result\":\"BLOCKED\","
               "\"code\":\"active_event_tap_unavailable\"}\n");
        return 2;
    }
    if (preflight_only) {
        CFRelease(state.tap);
        printf("{\"result\":\"PASS\",\"event\":\"consumer_preflight\"}\n");
        return 0;
    }

    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(
        kCFAllocatorDefault,
        state.tap,
        0
    );
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);

    CFRunLoopTimerContext timer_context = {0, &state, NULL, NULL, NULL};
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(
        kCFAllocatorDefault,
        CFAbsoluteTimeGetCurrent() + ((double)timeout_ms / 1000.0),
        0,
        0,
        0,
        timeout_callback,
        &timer_context
    );
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);

    printf(
        "{\"v\":1,\"event\":\"consumer_ready\","
        "\"keycode\":%lld,\"modifiers\":%llu}\n",
        (long long)state.expected_keycode,
        (unsigned long long)state.expected_modifiers
    );
    CFRunLoopRun();

    CFRunLoopRemoveTimer(CFRunLoopGetCurrent(), timer, kCFRunLoopCommonModes);
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(timer);
    CFRelease(source);
    CFRelease(state.tap);

    if (state.saw_down && state.saw_up) {
        printf("{\"result\":\"PASS\"}\n");
        return 0;
    }
    printf(
        "{\"result\":\"FAIL\",\"code\":\"%s\"}\n",
        state.timed_out ? "event_timeout" : "incomplete_key_pair"
    );
    return 1;
}
