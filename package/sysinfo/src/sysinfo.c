#include <stdio.h>
#include <unistd.h>
#include <sys/sysinfo.h>
#include <errno.h>
#include <string.h>


int main(void)
{
    char hostname[256];
    const int hostnameCall = gethostname(hostname, sizeof(hostname));
    if (hostnameCall == -1)
    {
        fprintf(stderr, "gethostname failed (errno %d): %s\n", errno, strerror(errno));
        return 1;
    }

    struct sysinfo info;
    const int sysInfoCall = sysinfo(&info);
    if (sysInfoCall == -1)
    {
        fprintf(stderr, "sysinfo failed (errno %d): %s\n", errno, strerror(errno));
        return 1;
    }

    const long pageSize = sysconf(_SC_PAGESIZE);
    if (pageSize == -1)
    {
        fprintf(stderr, "sysconf failed (errno %d): %s\n", errno, strerror(errno));
        return 1;
    }

    printf("Hostname: %s\n", hostname);
    printf("Uptime: %lu\n", info.uptime);
    printf("Process count: %d\n", info.procs);
    printf("Total RAM: %lu Byte\n", info.totalram * info.mem_unit);
    printf("Free RAM: %lu Byte\n", info.freeram * info.mem_unit);
    printf("Page size: %lu Byte \n", pageSize);
}
