#ifndef FD_BLOCKDEV_H_
#define FD_BLOCKDEV_H_

#include <stdint.h>
#include "ext4_blockdev.h"
#include "ext4_errno.h"

/* Read-only block device over a file descriptor. Reads use pread();
 * short reads yield EIO, writes yield EROFS. The fd is NOT owned. */
struct ext4_blockdev *fd_blockdev_create(int fd, uint32_t ph_bsize, uint64_t ph_bcnt);
void fd_blockdev_destroy(struct ext4_blockdev *bd);

#endif
