// host_inject_bootstrap.c
#include <stdio.h>
#include <mach/mach.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    if (argc != 2) {
        printf("Usage: %s <chroot_pid>\n", argv[0]);
        return 1;
    }

    pid_t chroot_pid = atoi(argv[1]);

    // 1. Get host bootstrap port
    mach_port_t host_bootstrap = MACH_PORT_NULL;
    kern_return_t kr = task_get_bootstrap_port(mach_task_self(), &host_bootstrap);
    if (kr != KERN_SUCCESS) {
        printf("task_get_bootstrap_port failed: %d\n", kr);
        return 1;
    }
    printf("Host bootstrap port: 0x%x\n", host_bootstrap);

    // 2. Get chrooted process task port
    mach_port_t chroot_task = MACH_PORT_NULL;
    kr = task_for_pid(mach_task_self(), chroot_pid, &chroot_task);
    if (kr != KERN_SUCCESS) {
        printf("task_for_pid failed: %d\n", kr);
        return 1;
    }

    // 3. Set chroot bootstrap port
    kr = task_set_bootstrap_port(chroot_task, host_bootstrap);
    if (kr != KERN_SUCCESS) {
        printf("task_set_bootstrap_port failed: %d\n", kr);
        return 1;
    }

    printf("Successfully injected host bootstrap port into chroot PID %d\n", chroot_pid);
    return 0;
}

