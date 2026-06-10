/* Reboot with the Pi firmware one-shot tryboot flag: the next boot uses the
 * [tryboot] section of autoboot.txt (staged A/B slot), exactly once.
 * busybox reboot cannot pass the RESTART2 argument, hence this tool. */
#include <stdio.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/reboot.h>

int main(void)
{
	sync();
	syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
		LINUX_REBOOT_CMD_RESTART2, "0 tryboot");
	perror("tryboot-reboot: reboot(RESTART2)");
	return 1;
}
