#!/usr/bin/env python3
"""Generate `apple-health-zip64-descriptors.zip`, a tiny synthetic archive that
exercises two ZIP features a real Apple Health export can carry:

  * a ZIP64 end-of-central-directory record (and locator), and
  * a local file header that uses a data descriptor (general-purpose bit 3),
    with the CRC and both sizes left zero in the local header.

Why a hand-rolled generator instead of Info-ZIP: for content this small,
Info-ZIP cannot produce both features at once. `zip -fz` forces ZIP64 only when
it can seek back over its output; when the output is non-seekable it omits the
ZIP64 records while still writing the `0xFFFFFFFF` sentinel central-directory
offset into the 32-bit EOCD, which is malformed. Verified against Zip 3.0
(Apple's build). No real workout data is involved: the payload is invented.

Regenerate with:

    python3 make_zip64_descriptor_fixture.py apple-health-zip64-descriptors.zip

The archive holds exactly one entry, `apple_health_export/export.xml`, whose
content is the invented document below. It is stored with deflate.
"""

import struct
import sys
import zlib

ENTRY_NAME = b"apple_health_export/export.xml"

DOCUMENT = (
    b'<?xml version="1.0" encoding="UTF-8"?>\n'
    b'<HealthData locale="en_US">\n'
    b'<Record type="HKQuantityTypeIdentifierHeartRate" value="141" '
    b'startDate="2026-09-01 08:30:00 +0000" endDate="2026-09-01 08:30:00 +0000"/>\n'
    b'<Workout workoutActivityType="HKWorkoutActivityTypeRunning" '
    b'startDate="2026-09-01 08:00:00 +0000" endDate="2026-09-01 09:00:00 +0000"/>\n'
    b"</HealthData>\n"
)

ZIP64_EXTRA_ID = 0x0001
DATA_DESCRIPTOR_SIGNATURE = 0x08074B50
VERSION_ZIP64 = 45
METHOD_DEFLATE = 8
FLAG_DATA_DESCRIPTOR = 0x0008
DOS_DATE_1980_01_01 = 0x0021


def deflate(payload: bytes) -> bytes:
    compressor = zlib.compressobj(9, zlib.DEFLATED, -15)
    return compressor.compress(payload) + compressor.flush()


def build() -> bytes:
    compressed = deflate(DOCUMENT)
    checksum = zlib.crc32(DOCUMENT) & 0xFFFFFFFF
    uncompressed_size = len(DOCUMENT)
    compressed_size = len(compressed)

    # Local header: CRC and sizes are zero because bit 3 defers them to the
    # data descriptor, and no ZIP64 extra field is written here — the descriptor
    # and the central directory carry the real values.
    local_header = struct.pack(
        "<IHHHHHIIIHH",
        0x04034B50,             # local file header signature
        VERSION_ZIP64,          # version needed to extract
        FLAG_DATA_DESCRIPTOR,   # general purpose bit flag
        METHOD_DEFLATE,
        0,                      # last mod time
        DOS_DATE_1980_01_01,    # last mod date
        0,                      # CRC-32 (deferred)
        0,                      # compressed size (deferred)
        0,                      # uncompressed size (deferred)
        len(ENTRY_NAME),
        0,                      # extra field length
    )

    # Data descriptor, signed and with 8-byte sizes to match the ZIP64 header.
    data_descriptor = struct.pack(
        "<IIQQ",
        DATA_DESCRIPTOR_SIGNATURE,
        checksum,
        compressed_size,
        uncompressed_size,
    )

    central_directory_offset = len(local_header) + len(ENTRY_NAME) + len(compressed) + len(data_descriptor)

    # Central directory: the sizes live in a ZIP64 extra field because their
    # 32-bit slots hold the sentinel. The local header offset (0 — this entry
    # starts the file) is small enough for its 32-bit slot, so per the ZIP spec
    # it is *not* repeated in the extra field: the extra field carries a value
    # for a field only when that field's 32-bit slot is the sentinel.
    central_extra = struct.pack(
        "<HHQQ",
        ZIP64_EXTRA_ID,
        16,                     # data size: two 8-byte values
        uncompressed_size,
        compressed_size,
    )
    central_entry = struct.pack(
        "<IHHHHHHIIIHHHHHII",
        0x02014B50,             # central directory file header signature
        VERSION_ZIP64,          # version made by
        VERSION_ZIP64,          # version needed to extract
        FLAG_DATA_DESCRIPTOR,
        METHOD_DEFLATE,
        0,
        DOS_DATE_1980_01_01,
        checksum,
        0xFFFFFFFF,             # compressed size -> extra field
        0xFFFFFFFF,             # uncompressed size -> extra field
        len(ENTRY_NAME),
        len(central_extra),
        0,                      # comment length
        0,                      # disk number start
        0,                      # internal attributes
        0,                      # external attributes
        0,                      # local header offset (fits in 32 bits)
    ) + ENTRY_NAME + central_extra

    central_directory_size = len(central_entry)

    zip64_eocd = struct.pack(
        "<IQHHIIQQQQ",
        0x06064B50,             # ZIP64 end of central directory signature
        44,                     # size of the remainder of this record
        VERSION_ZIP64,
        VERSION_ZIP64,
        0,                      # this disk
        0,                      # disk with central directory
        1,                      # entries on this disk
        1,                      # total entries
        central_directory_size,
        central_directory_offset,
    )
    zip64_locator = struct.pack(
        "<IIQI",
        0x07064B50,             # ZIP64 end of central directory locator
        0,                      # disk with the ZIP64 EOCD
        len(local_header) + len(ENTRY_NAME) + len(compressed) + len(data_descriptor)
        + central_directory_size,
        1,                      # total disks
    )
    end_of_central_directory = struct.pack(
        "<IHHHHIIH",
        0x06054B50,             # end of central directory signature
        0,
        0,
        1,
        1,
        central_directory_size,
        0xFFFFFFFF,             # central directory offset -> ZIP64 EOCD
        0,
    )

    return (
        local_header
        + ENTRY_NAME
        + compressed
        + data_descriptor
        + central_entry
        + zip64_eocd
        + zip64_locator
        + end_of_central_directory
    )


def main() -> None:
    destination = sys.argv[1] if len(sys.argv) > 1 else "apple-health-zip64-descriptors.zip"
    payload = build()
    with open(destination, "wb") as handle:
        handle.write(payload)
    print(f"wrote {destination} ({len(payload)} bytes, {len(DOCUMENT)} uncompressed)")


if __name__ == "__main__":
    main()
