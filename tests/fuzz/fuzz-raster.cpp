/* SPDX-License-Identifier: AGPL-3.0-or-later
 * Copyright (C) 2026 Gamunu Balagalla
 */

/* libFuzzer harness: CUPS raster in, hpcups filter out.
 *
 * The filter reads raster from whoever prints to the queue, so every header
 * field and every row is attacker data. The first input byte picks one of the
 * PPDs in $FUZZ_PPD_DIR (one per print language, see scripts/fuzz-seed.sh),
 * the rest is the raster stream. Printer output goes to /dev/null.
 *
 * Built by `make fuzz-build` with the filter's main() renamed to hpcups_main.
 */

#include <dirent.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <string>
#include <vector>
#include <algorithm>

#include "HPCupsFilter.h"

extern "C" const char *__asan_default_options() { return "detect_leaks=0"; }

static std::vector<std::string> ppds;
static char rasterPath[] = "/tmp/hpcups-fuzz-XXXXXX";

extern "C" int LLVMFuzzerInitialize(int *, char ***)
{
    const char *dir = getenv("FUZZ_PPD_DIR");
    if (!dir) {
        fprintf(stderr, "set FUZZ_PPD_DIR to a folder of .ppd files\n");
        exit(1);
    }
    if (DIR *d = opendir(dir)) {
        while (struct dirent *e = readdir(d)) {
            size_t n = strlen(e->d_name);
            if (n > 4 && strcmp(e->d_name + n - 4, ".ppd") == 0)
                ppds.push_back(std::string(dir) + "/" + e->d_name);
        }
        closedir(d);
    }
    if (ppds.empty()) {
        fprintf(stderr, "no .ppd files in %s\n", dir);
        exit(1);
    }
    std::sort(ppds.begin(), ppds.end());

    int fd = mkstemp(rasterPath);
    if (fd < 0) {
        perror("mkstemp");
        exit(1);
    }
    close(fd);

    // The filter writes the print job to stdout. Its stderr chatter is
    // silenced with -close_fd_mask=2, which keeps libFuzzer's own reports.
    int null = open("/dev/null", O_WRONLY);
    dup2(null, STDOUT_FILENO);
    close(null);
    return 0;
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if (size < 1)
        return 0;
    const std::string &ppd = ppds[data[0] % ppds.size()];

    FILE *f = fopen(rasterPath, "wb");
    if (!f)
        return 0;
    fwrite(data + 1, 1, size - 1, f);
    fclose(f);

    setenv("PPD", ppd.c_str(), 1);
    char job[] = "1", user[] = "fuzz", title[] = "fuzz", copies[] = "1", options[] = "";
    char prog[] = "hpcups";
    char *argv[] = { prog, job, user, title, copies, options, rasterPath, NULL };

    HPCupsFilter *filter = new HPCupsFilter();
    filter->StartPrintJob(7, argv);
    delete filter;
    return 0;
}
