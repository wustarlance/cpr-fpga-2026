#!/usr/bin/env python3
"""Pack 1..4 supported BMPs into a sector-aligned image file; never writes a device."""
from __future__ import annotations

import argparse
from pathlib import Path
import struct

SECTOR = 512
MAX_SCAN_BYTES = 131072 * SECTOR


def read_supported_bmp(path: Path) -> bytes:
    data = path.read_bytes()
    if len(data) < 54 or data[:2] != b"BM":
        raise ValueError(f"{path}: 不是有效 BMP")
    length, = struct.unpack_from("<I", data, 2)
    offset, dib = struct.unpack_from("<II", data, 10)
    width, height, planes, bpp, compression = struct.unpack_from("<iiHHI", data, 18)
    if not (40 <= dib <= 124 and offset >= 14 + dib):
        raise ValueError(f"{path}: 不支持的 DIB 头或像素偏移")
    if not (1 <= width <= 2048 and 1 <= height <= 1536):
        raise ValueError(f"{path}: 要求正高度 BMP，宽1..2048、高1..1536")
    if (planes, bpp, compression) != (1, 24, 0):
        raise ValueError(f"{path}: 要求24位、无压缩 BMP")
    required = offset + ((width * 3 + 3) & ~3) * height
    if not (required <= length <= len(data)):
        raise ValueError(f"{path}: 文件长度不足，或文件头长度不一致")
    return data[:length]


def pack(images: list[Path], output: Path) -> list[tuple[Path, int, int]]:
    if not 1 <= len(images) <= 4:
        raise ValueError("需要1至4张BMP；建议4张，避免扫描剩余空区")
    payloads = [read_supported_bmp(path) for path in images]
    total = sum((len(data) + SECTOR - 1) // SECTOR * SECTOR for data in payloads)
    if total > MAX_SCAN_BYTES:
        raise ValueError("打包结果超过当前64MiB扫描范围")
    # Exclusive creation rejects existing files, symlinks and device nodes.
    # No block-device write or flashing operation is implemented here.
    records = []
    with output.open("xb") as stream:
        sector = 0
        for path, data in zip(images, payloads):
            sectors = (len(data) + SECTOR - 1) // SECTOR
            records.append((path, sector, sectors))
            stream.write(data)
            stream.write(bytes(sectors * SECTOR - len(data)))
            sector += sectors
    return records


def main() -> None:
    parser = argparse.ArgumentParser(description="把不同尺寸BMP打包成原始扇区镜像文件；不写SD卡。")
    parser.add_argument("images", nargs="+", type=Path, help="按显示顺序提供1至4张BMP")
    parser.add_argument("--output", required=True, type=Path, help="新建的.img文件，禁止覆盖已有文件")
    args = parser.parse_args()
    try:
        records = pack(args.images, args.output)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    for path, sector, count in records:
        print(f"{path}: LBA {sector}, {count} sectors")
    print(f"Created {args.output} ({args.output.stat().st_size} bytes); no device was written.")


if __name__ == "__main__":
    main()
