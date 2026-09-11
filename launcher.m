#import <Foundation/Foundation.h>
#import <ServiceManagement/ServiceManagement.h>
#include <unistd.h>
#include <stdio.h>
#include <sys/stat.h>
#include <time.h>

static void launcher_log(const char *fmt, ...) {
    const char *home = getenv("HOME");
    if (!home) return;
    char path[1024];
    snprintf(path, sizeof path, "%s/DisableScreen/launcher.log", home);
    FILE *f = fopen(path, "a");
    if (!f) return;
    time_t t = time(NULL);
    char ts[32]; strftime(ts, sizeof ts, "%F %T", localtime(&t));
    fprintf(f, "[%s] ", ts);
    va_list ap; va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static NSString * statusString(SMAppServiceStatus s) {
    switch (s) {
        case SMAppServiceStatusNotRegistered: return @"notRegistered";
        case SMAppServiceStatusEnabled: return @"enabled";
        case SMAppServiceStatusRequiresApproval: return @"requiresApproval";
        case SMAppServiceStatusNotFound: return @"notFound";
    }
    return @"unknown";
}

static int handleSM(int argc, const char *argv[]) {
    @autoreleasepool {
        NSBundle *b = [NSBundle mainBundle];
        launcher_log("SM: bundle=%s id=%s",
                     [[b bundlePath] UTF8String],
                     [[b bundleIdentifier] UTF8String]);
        SMAppService *svc = [SMAppService mainAppService];
        if (argc >= 2 && strcmp(argv[1], "--status") == 0) {
            printf("%s\n", [statusString(svc.status) UTF8String]);
            return 0;
        }
        NSError *err = nil;
        BOOL ok = NO;
        if (strcmp(argv[1], "--register") == 0) {
            ok = [svc registerAndReturnError:&err];
        } else {
            ok = [svc unregisterAndReturnError:&err];
        }
        launcher_log("SM action=%s ok=%d status=%s err=%s",
                     argv[1], ok, [statusString(svc.status) UTF8String],
                     err ? [[err localizedDescription] UTF8String] : "nil");
        fprintf(ok ? stdout : stderr, "%s\n", [statusString(svc.status) UTF8String]);
        return ok ? 0 : 1;
    }
}

int main(int argc, const char *argv[]) {
    if (argc >= 2 &&
        (strcmp(argv[1], "--register") == 0 ||
         strcmp(argv[1], "--unregister") == 0 ||
         strcmp(argv[1], "--status") == 0)) {
        return handleSM(argc, argv);
    }

    @autoreleasepool {
        NSBundle *b = [NSBundle mainBundle];
        NSString *mainpy = [[b bundlePath] stringByAppendingPathComponent:@"Contents/Resources/main.py"];

        // Absolute python paths; first existing wins. Hardcoded because PATH at
        // login (loginwindow) is /usr/bin:/bin:/usr/sbin:/sbin — /usr/bin/python3
        // is the Apple stub WITHOUT PyObjC, so we must not fall through to it.
        const char *candidates[] = {
            "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3",
            "/Library/Frameworks/Python.framework/Versions/Current/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            NULL
        };
        const char *py = NULL;
        struct stat st;
        for (int i = 0; candidates[i]; i++) {
            if (stat(candidates[i], &st) == 0 && (st.st_mode & S_IXUSR)) {
                py = candidates[i];
                break;
            }
        }
        if (!py) {
            launcher_log("LAUNCH FAILED: no python3 found at any candidate path");
            return 127;
        }
        launcher_log("exec %s %s", py, [mainpy UTF8String]);
        char *const args[] = { (char *)py, (char *)[mainpy UTF8String], NULL };
        execv(py, args);
        launcher_log("execv failed for %s (errno=%d)", py, errno);
        return 126;
    }
}
