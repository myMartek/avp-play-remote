// Klepton's translator (tools/klepton_ld.c: Android .so in, signable Mach-O out) as a function instead of a program.
#include <stddef.h>

/// Runs the translator with a command line (argv[0] is the program name, as for main). Returns its exit code.
/// What it wrote to standard error ends up in the file `error_log`.
/// One call at a time: the translator keeps its state in globals and leaves through a jump when it gives up.
int klepton_ld_run(int argc, char **argv, const char *error_log);
