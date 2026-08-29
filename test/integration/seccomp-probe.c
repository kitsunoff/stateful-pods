/*
 * What a container may actually call.
 *
 * Every check below makes a raw system call with arguments chosen so that a
 * kernel which lets the call through fails it for an ordinary reason - a path
 * that does not exist, a file descriptor that is not one, a length that is not
 * allowed. Nothing here can succeed and nothing here changes the node.
 *
 * That matters because the whole point is to tell EPERM apart from everything
 * else. A seccomp filter with SCMP_ACT_ERRNO returns EPERM before the call
 * reaches the kernel, so "EPERM" means the filter stopped it and any other
 * errno means it did not. The pod running this has to be granted the
 * capabilities these calls need - otherwise the capability check returns EPERM
 * too and the assertion proves nothing at all.
 *
 * Output is one `name=value` line per check, plus the seccomp mode the kernel
 * reports for this process, so the caller can also see whether any filter is
 * loaded at all.
 */
#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/syscall.h>
#include <unistd.h>

static const char *errname(int number)
{
	switch (number) {
	case EPERM:   return "EPERM";
	case ENOENT:  return "ENOENT";
	case EBADF:   return "EBADF";
	case EACCES:  return "EACCES";
	case EFAULT:  return "EFAULT";
	case EBUSY:   return "EBUSY";
	case EINVAL:  return "EINVAL";
	case ENOEXEC: return "ENOEXEC";
	case ENOSYS:  return "ENOSYS";
	case ENOMEM:  return "ENOMEM";
	case ENOTDIR: return "ENOTDIR";
	case ELOOP:   return "ELOOP";
	default:      return NULL;
	}
}

static void report(const char *name, long result)
{
	if (result >= 0) {
		printf("%s=ok\n", name);
		return;
	}
	const char *known = errname(errno);
	if (known != NULL) {
		printf("%s=%s\n", name, known);
	} else {
		printf("%s=errno%d\n", name, errno);
	}
}

/* The mode the kernel reports: 0 is no filter, 2 is a seccomp BPF filter. */
static void report_seccomp_mode(void)
{
	FILE *status = fopen("/proc/self/status", "r");
	if (status == NULL) {
		printf("seccomp_mode=unknown\n");
		return;
	}
	char line[256];
	while (fgets(line, sizeof(line), status) != NULL) {
		int mode;
		if (sscanf(line, "Seccomp: %d", &mode) == 1) {
			printf("seccomp_mode=%d\n", mode);
			fclose(status);
			return;
		}
	}
	fclose(status);
	printf("seccomp_mode=unknown\n");
}

int main(void)
{
	report_seccomp_mode();

	/* The call the guest container makes to become the machine. Both paths are
	   absent, so a kernel that runs this reports ENOENT. */
	report("pivot_root", syscall(SYS_pivot_root, "/nonexistent", "/nonexistent"));

	/* The five LXC's own profile denies. */
	report("init_module", syscall(SYS_init_module, (void *)0, (unsigned long)0, ""));
	report("finit_module", syscall(SYS_finit_module, -1, "", 0));
	report("delete_module", syscall(SYS_delete_module, "stateful_pods_absent", 0));
	/* An invalid flags word, so a kernel that runs this rejects it rather than
	   touching whatever kexec image the node may hold. */
	report("kexec_load", syscall(SYS_kexec_load, (unsigned long)0, (unsigned long)0,
				     (void *)0, (unsigned long)0xffff0000));
	struct file_handle handle;
	memset(&handle, 0, sizeof(handle));
	report("open_by_handle_at", syscall(SYS_open_by_handle_at, -1, &handle, O_RDONLY));

	/* The sixth rule is an argument filter, not a whole call: umount2 is denied
	   only when MNT_FORCE is set. Both of these name a path that is not mounted
	   and not present, so a kernel that runs either reports ENOENT. */
	report("umount2_force", syscall(SYS_umount2, "/nonexistent", MNT_FORCE));
	report("umount2_plain", syscall(SYS_umount2, "/nonexistent", 0));

	/* A call no profile here denies, so that an allow-by-default profile is
	   distinguishable from one that denies everything. */
	report("getpid", syscall(SYS_getpid));

	return 0;
}
