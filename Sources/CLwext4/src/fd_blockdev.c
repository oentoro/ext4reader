#include "fd_blockdev.h"
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>

struct fd_ctx {
    int fd;
    struct ext4_blockdev_iface iface;
    struct ext4_blockdev bdev;
    uint8_t *buf;
};

static int fd_open(struct ext4_blockdev *bdev) { (void)bdev; return EOK; }
static int fd_close(struct ext4_blockdev *bdev) { (void)bdev; return EOK; }

static int fd_bread(struct ext4_blockdev *bdev, void *buf, uint64_t blk_id, uint32_t blk_cnt)
{
    struct fd_ctx *c = bdev->bdif->p_user;
    size_t len = (size_t)blk_cnt * bdev->bdif->ph_bsize;
    off_t off = (off_t)(blk_id * bdev->bdif->ph_bsize);
    uint8_t *p = buf;
    size_t done = 0;
    while (done < len) {
        ssize_t n = pread(c->fd, p + done, len - done, off + (off_t)done);
        if (n < 0) {
            if (errno == EINTR) continue;
            return errno ? errno : EIO;   /* errno asli (mis. ENXIO saat disk dicabut) */
        }
        if (n == 0) return EIO;           /* baca pendek: di luar akhir perangkat */
        done += (size_t)n;
    }
    return EOK;
}

static int fd_bwrite(struct ext4_blockdev *bdev, const void *buf, uint64_t blk_id, uint32_t blk_cnt)
{
    (void)bdev; (void)buf; (void)blk_id; (void)blk_cnt;
    return EROFS;
}

struct ext4_blockdev *fd_blockdev_create(int fd, uint32_t ph_bsize, uint64_t ph_bcnt)
{
    struct fd_ctx *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    c->buf = malloc(ph_bsize);
    if (!c->buf) { free(c); return NULL; }
    c->fd = fd;
    c->iface.open = fd_open;
    c->iface.bread = fd_bread;
    c->iface.bwrite = fd_bwrite;
    c->iface.close = fd_close;
    c->iface.ph_bsize = ph_bsize;
    c->iface.ph_bcnt = ph_bcnt;
    c->iface.ph_bbuf = c->buf;
    c->iface.p_user = c;
    c->bdev.bdif = &c->iface;
    c->bdev.part_offset = 0;
    c->bdev.part_size = ph_bcnt * ph_bsize;
    return &c->bdev;
}

void fd_blockdev_destroy(struct ext4_blockdev *bd)
{
    if (!bd) return;
    struct fd_ctx *c = bd->bdif->p_user;
    free(c->buf);
    free(c);
}
