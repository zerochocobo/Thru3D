#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""批量下载 Poly Haven 全景图（Python 3.9+，只使用标准库）。

默认：从官方目录随机选取 100 个资源，下载它们的 Tonemapped JPG。
JPG 保留官方尺寸，不缩放；许多资源为 8192x4096，但以实际文件为准。
--resolution 仅适用于 HDR/EXR，不改变 JPG 尺寸。

Windows PowerShell 示例：
  python download_panoramas.py --limit 100 --out D:/Panoramas
  python download_panoramas.py --limit 300 --category indoor --out D:/IndoorPanos
  python download_panoramas.py --limit 0 --out D:/AllPanoramas
  python download_panoramas.py --limit 10 --format hdr --resolution 16k --out D:/Panos16K
  python download_panoramas.py --ids venice_sunset --out D:/PanoSample
  python download_panoramas.py --limit 100 --dry-run --out D:/PanoPlan

--limit 0 表示全部；如果匹配资源少于指定数量，只下载匹配到的资源。
--category 按分类、标签、属性关键词筛选，例如 indoor、outdoor、forest。
--seed 控制随机选择；同一目录快照和 seed 会得到同一组资源。
已完成文件通过大小和 MD5 校验后跳过；失败的单个文件重试，残缺文件重新下载。
每次运行在输出目录创建独立 CSV 清单（包含来源、大小、MD5 和结果）。
图片来自 Poly Haven，素材采用 CC0：https://polyhaven.com/license
脚本使用其公开 API：https://polyhaven.com/our-api
脚本不是 Poly Haven 官方产品。若将其 API 集成到产品中，请保留来源标识。
"""

import argparse
import csv
import hashlib
import json
import random
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

API = "https://api.polyhaven.com"
HEADERS = {"User-Agent": "PanoramaBatchDownloader/1.0 (Poly Haven panorama test assets)"}
FIELDS = ["asset_id", "name", "category", "format", "file", "size_bytes", "md5", "url", "status", "error"]
STOP = threading.Event()


def check_stop():
    if STOP.is_set():
        raise InterruptedError("下载已取消")


def pause_after_error(error, attempt):
    delay = 2 ** attempt
    if isinstance(error, HTTPError) and error.code == 429:
        try:
            delay = max(delay, float(error.headers.get("Retry-After", "0")))
        except ValueError:
            delay = max(delay, 10)
    STOP.wait(delay)
    check_stop()


def get_json(url):
    for attempt in range(3):
        check_stop()
        try:
            with urlopen(Request(url, headers=HEADERS), timeout=45) as response:
                return json.load(response)
        except (OSError, ValueError) as error:
            if attempt == 2:
                raise
            pause_after_error(error, attempt)


def is_complete(path, info):
    if not path.is_file() or path.stat().st_size != int(info["size"]):
        return False
    checksum = info.get("md5")
    if not checksum:
        return True
    digest = hashlib.md5()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().lower() == checksum.lower()


def download(info, path):
    check_stop()
    if is_complete(path, info):
        return "skipped"
    partial = path.with_name(path.name + ".part")
    for attempt in range(3):
        check_stop()
        try:
            with urlopen(Request(info["url"], headers=HEADERS), timeout=90) as response:
                with partial.open("wb") as target:
                    while True:
                        check_stop()
                        chunk = response.read(1024 * 1024)
                        if not chunk:
                            break
                        target.write(chunk)
            if not is_complete(partial, info):
                raise OSError("文件大小或 MD5 不匹配；将重试")
            partial.replace(path)
            return "downloaded"
        except (OSError, URLError) as error:
            if attempt == 2:
                raise
            pause_after_error(error, attempt)


def process_asset(asset_id, asset, args):
    suffix = ".jpg" if args.format == "jpg" else "_" + args.resolution + "." + args.format
    row = dict.fromkeys(FIELDS, "")
    row.update(asset_id=asset_id, name=asset.get("name", ""),
               category=asset.get("category") or ",".join(asset.get("categories", [])),
               format=args.format, file=asset_id + suffix)
    try:
        files = get_json(API + "/files/" + quote(asset_id, safe=""))
        if args.format == "jpg":
            info = files.get("tonemapped")
        else:
            info = files.get("hdri", {}).get(args.resolution, {}).get(args.format)
        if not info or not info.get("url"):
            row.update(status="missing", error="资源不提供所选格式或尺寸")
            return row
        row.update(size_bytes=info["size"], md5=info.get("md5", ""), url=info["url"])
        row["status"] = "planned" if args.dry_run else download(info, args.out / row["file"])
    except Exception as error:
        row.update(status="failed", error=str(error))
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--limit", "-n", type=int, default=100, help="资源数；0=全部，默认100")
    parser.add_argument("--out", "-o", type=Path, default=Path("panoramas"), help="输出目录")
    parser.add_argument("--format", choices=["jpg", "hdr", "exr"], default="jpg")
    parser.add_argument("--resolution", choices=["1k", "2k", "4k", "8k", "16k", "24k"], default="8k", help="只影响HDR/EXR")
    parser.add_argument("--category", default="", help="分类/标签/属性关键词（英文）")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--workers", type=int, choices=range(1, 5), default=2, help="并发数1到4，默认2")
    parser.add_argument("--ids", nargs="+", help="指定资源ID；使用此参数时忽略limit/category/seed")
    parser.add_argument("--dry-run", action="store_true", help="仅生成带大小、校验码、URL的CSV，不下载图片")
    args = parser.parse_args()
    if args.limit < 0:
        parser.error("--limit 不能小于0")
    print("Source: Poly Haven (CC0) | https://polyhaven.com", flush=True)
    print("正在读取官方资源目录...", flush=True)
    assets = get_json(API + "/assets?type=hdris")
    if args.ids:
        selected = list(dict.fromkeys(args.ids))
        unknown = [asset_id for asset_id in selected if asset_id not in assets]
        if unknown:
            parser.error("未找到资源ID: " + ", ".join(unknown))
    else:
        keyword = args.category.casefold().strip()
        selected = []
        for asset_id in sorted(assets):
            asset = assets[asset_id]
            searchable = json.dumps({k: asset.get(k) for k in ("categories", "category", "tags", "attributes")}, ensure_ascii=False).casefold()
            if not keyword or keyword in searchable:
                selected.append(asset_id)
        random.Random(args.seed).shuffle(selected)
        if args.limit:
            selected = selected[:args.limit]
    if not selected:
        print("没有匹配资源，请更换 --category 关键词。", file=sys.stderr)
        return 1
    args.out.mkdir(parents=True, exist_ok=True)
    manifest = args.out / ("download_manifest_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f") + ".csv")
    print(f"目录共 {len(assets)} 个资源，本次选择 {len(selected)} 个，格式 {args.format}。", flush=True)
    if args.format == "jpg":
        print("JPG 保留官方原图尺寸；--resolution 不改变 JPG 尺寸。", flush=True)
    counts = {}
    total_bytes = 0
    with manifest.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS)
        writer.writeheader()
        executor = ThreadPoolExecutor(max_workers=args.workers)
        try:
            futures = [executor.submit(process_asset, asset_id, assets[asset_id], args) for asset_id in selected]
            for index, future in enumerate(as_completed(futures), 1):
                row = future.result()
                writer.writerow(row)
                stream.flush()
                status = row["status"]
                counts[status] = counts.get(status, 0) + 1
                total_bytes += int(row["size_bytes"] or 0)
                detail = " | " + row["error"] if row["error"] else ""
                print(f"[{index}/{len(selected)}] {status}: {row['file']}{detail}", flush=True)
        except KeyboardInterrupt:
            STOP.set()
            executor.shutdown(wait=False, cancel_futures=True)
            raise
        else:
            executor.shutdown(wait=True)
    print("结果: " + json.dumps(counts, ensure_ascii=False), flush=True)
    print(f"已解析文件的总大小: {total_bytes / 1024 ** 3:.2f} GiB（含已存在文件）", flush=True)
    print("CSV清单: " + str(manifest.resolve()), flush=True)
    return 1 if counts.get("failed") or counts.get("missing") else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n已中断。重跑会校验并跳过已完成文件，未完成文件会重新下载。", file=sys.stderr)
        raise SystemExit(130)
    except Exception as error:
        print("错误: " + str(error), file=sys.stderr)
        raise SystemExit(1)
