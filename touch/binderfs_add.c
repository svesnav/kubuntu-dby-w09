#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>

#define BINDERFS_MAX_NAME 255
struct binderfs_device {
    char name[BINDERFS_MAX_NAME + 1];
    uint32_t major;
    uint32_t minor;
};
#define BINDER_CTL_ADD _IOWR('b', 1, struct binderfs_device)

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: binderfs_add CONTROL DEVICE_NAME\n");
        return 2;
    }
    struct binderfs_device device = {0};
    if (strlen(argv[2]) > BINDERFS_MAX_NAME) return 2;
    strcpy(device.name, argv[2]);
    int fd = open(argv[1], O_RDWR | O_CLOEXEC);
    if (fd < 0) { perror("open binder-control"); return 1; }
    int rc = ioctl(fd, BINDER_CTL_ADD, &device);
    if (rc < 0) { perror("BINDER_CTL_ADD"); close(fd); return 1; }
    printf("%s %u:%u\n", device.name, device.major, device.minor);
    close(fd);
    return 0;
}
