/* Rebuild the sparse Ogg trigger from the checked-in 91-byte Opus prefix. */
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

enum { PREFIX_SIZE = 91, DATA_SIZE = 255 * 255, LAST_SEQ = 66001 };
static uint32_t table[256];

static void init_crc(void)
{
    for (unsigned i = 0; i < 256; i++) {
        uint32_t x = i << 24;
        for (int j = 0; j < 8; j++)
            x = (x << 1) ^ ((x & 0x80000000U) ? 0x04c11db7U : 0);
        table[i] = x;
    }
}

static uint32_t crc_bytes(uint32_t crc, const uint8_t *buf, size_t size)
{
    for (size_t i = 0; i < size; i++)
        crc = (crc << 8) ^ table[(crc >> 24) ^ buf[i]];
    return crc;
}

static int copy_prefix(int outfd, const char *path)
{
    uint8_t prefix[PREFIX_SIZE];
    struct stat st;
    int fd = open(path, O_RDONLY);
    if (fd < 0 || fstat(fd, &st) || st.st_size != PREFIX_SIZE ||
        read(fd, prefix, sizeof(prefix)) != sizeof(prefix) ||
        write(outfd, prefix, sizeof(prefix)) != sizeof(prefix))
        return -1;
    return close(fd);
}

static int sparse_page(int fd, uint32_t seq)
{
    uint8_t hdr[27 + 255] = {0};
    static const uint8_t zeros[DATA_SIZE];
    uint32_t crc;

    memcpy(hdr, "OggS", 4);
    hdr[5] = seq == 2 ? 0 : 1; /* one continued packet */
    memset(hdr + 6, 0xff, 8); /* unknown granule position */
    hdr[14] = 1; /* stream serial number */
    for (int i = 0; i < 4; i++)
        hdr[18 + i] = seq >> (8 * i);
    hdr[26] = 255;
    memset(hdr + 27, 255, 255);
    crc = crc_bytes(0, hdr, sizeof(hdr));
    crc = crc_bytes(crc, zeros, sizeof(zeros));
    for (int i = 0; i < 4; i++)
        hdr[22 + i] = crc >> (8 * i);
    if (write(fd, hdr, sizeof(hdr)) != sizeof(hdr))
        return -1;
    return lseek(fd, sizeof(zeros), SEEK_CUR) < 0 ? -1 : 0;
}

int main(int argc, char **argv)
{
    int fd;
    off_t size;
    if (argc != 3)
        return 2;
    init_crc();
    fd = open(argv[2], O_CREAT | O_TRUNC | O_WRONLY, 0644);
    if (fd < 0 || copy_prefix(fd, argv[1]))
        return 3;
    for (uint32_t seq = 2; seq <= LAST_SEQ; seq++)
        if (sparse_page(fd, seq))
            return 4;
    size = lseek(fd, 0, SEEK_CUR);
    if (size < 0 || ftruncate(fd, size) || close(fd))
        return 5;
    printf("logical_size=%lld pages=%d\n", (long long)size, LAST_SEQ + 1);
    return 0;
}
