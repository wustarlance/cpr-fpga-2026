#!/usr/bin/env python3
"""Place a complete tutorial image inside the training OSD's reserved viewport."""
import argparse
from pathlib import Path
import struct


def prepare(source, destination):
    from PIL import Image, ImageOps
    with Image.open(source) as original:
        original.load()
        original = ImageOps.exif_transpose(original).convert("RGBA")
        background = Image.new("RGBA", original.size, (16, 32, 48, 255))
        background.alpha_composite(original)
        fitted = ImageOps.contain(background.convert("RGB"), (352, 400), Image.Resampling.LANCZOS)
    canvas = Image.new("RGB", (640, 480), (16, 32, 48))
    canvas.paste(fitted, (16 + (352-fitted.width)//2, 32 + (400-fitted.height)//2))
    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(destination, format="BMP")
    header = destination.read_bytes()[:54]
    assert header[:2] == b"BM"
    assert struct.unpack_from("<iiHHI", header, 18) == (640, 480, 1, 24, 0)
    return fitted.size


def main():
    parser = argparse.ArgumentParser(description="将完整教程图等比例放入训练画面左侧，输出兼容现有播放器的640×480、24位无压缩BMP。")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    if args.source.resolve() == args.destination.resolve():
        parser.error("输入与输出不能为同一文件；请保留原始教程图。")
    if not args.source.is_file():
        parser.error("输入图片不存在。")
    if args.destination.exists():
        parser.error("输出已存在；请使用新的输出文件名。")
    try:
        size = prepare(args.source, args.destination)
    except ImportError:
        parser.error("需要Pillow：python -m pip install Pillow")
    print(f"Prepared {args.destination}: 640x480 RGB24 BMP, tutorial {size[0]}x{size[1]} inside x16..367/y32..431")


if __name__ == "__main__":
    main()
