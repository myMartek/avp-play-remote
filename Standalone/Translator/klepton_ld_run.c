// See include/klepton_ld_run.h. The translator's own files are compiled with main renamed to klepton_ld_main and
// exit renamed to klepton_ld_exit (scripts/build.sh), so that giving up ends the call and not the app.
#include "klepton_ld_run.h"
#include <fcntl.h>
#include <setjmp.h>
#include <stdio.h>
#include <unistd.h>

int klepton_ld_main(int argc, char **argv);

static jmp_buf g_leave;
static int g_code;

__attribute__((noreturn)) void klepton_ld_exit(int code) {
    g_code = code;
    longjmp(g_leave, 1);
}

int klepton_ld_run(int argc, char **argv, const char *error_log) {
    fflush(stderr);
    int saved = dup(STDERR_FILENO);
    int log = open(error_log, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (log >= 0) { dup2(log, STDERR_FILENO); close(log); }
    int code;
    if (setjmp(g_leave) == 0) code = klepton_ld_main(argc, argv);
    else code = g_code;
    fflush(stderr);
    if (saved >= 0) { dup2(saved, STDERR_FILENO); close(saved); }
    return code;
}
