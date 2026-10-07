"""Fetch the exact release dependency set and lock downloaded archive bytes."""
import os
from pathlib import Path
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cache", type=Path, default=Path(str(Path(os.environ.get('THRU3D_TOOL_ROOT', str(Path.home() / '.cache/thru3d-toolchain'))) / 'linux-build/downloads')))
    args = parser.parse_args()
    plan = json.loads((ROOT / "third_party/mpv/source-plan.json").read_text(encoding="utf-8"))
    lock_path = ROOT / "third_party/mpv/source-lock.json"
    previous = json.loads(lock_path.read_text(encoding="utf-8")) if lock_path.exists() else {"sources": []}
    known = {p["name"]: p for p in previous["sources"]}
    records = {name: record for name, record in known.items()
               if name in {item["name"] for item in plan["sources"]}}
    for item in plan["sources"]:
        old = records.get(item["name"])
        if old and any(old[key] != item[key] for key in ("revision", "url", "archive")):
            raise ValueError(f"Source plan differs from the existing lock: {item['name']}")
    args.cache.mkdir(parents=True, exist_ok=True)
    for item in plan["sources"]:
        target = args.cache / item["archive"]
        if not target.exists():
            temporary = target.with_suffix(target.suffix + ".download")
            subprocess.run([os.environ.get('THRU3D_CURL', 'curl'), "--silent", "--show-error", "-L", "--fail", "--retry", "2",
                            "--connect-timeout", "20", "--max-time", "240",
                            "-o", str(temporary), item["url"]], check=True)
            # Check archive structure before accepting a successful HTTP response.
            with tarfile.open(temporary) as archive:
                if not archive.getmembers():
                    raise ValueError(f"Empty source archive: {item['name']}")
            temporary.replace(target)
        digest = hashlib.sha256(target.read_bytes()).hexdigest()
        old = known.get(item["name"])
        if old and (digest != old["sha256"] or old["revision"] != item["revision"] or old["url"] != item["url"]):
            raise ValueError(f"Locked source bytes or revision differ: {item['name']}")
        records[item["name"]] = {**item, "sha256": digest, "bytes": target.stat().st_size}
        # Keep existing pins on interruption and publish the lock atomically.
        temporary_lock = lock_path.with_suffix(".json.tmp")
        temporary_lock.write_text(json.dumps({**plan, "sources": [records[p["name"]]
            for p in plan["sources"] if p["name"] in records],
            "hash_provenance": "Project hashes of exact revision/version archives fetched from upstream TLS endpoints"},
            indent=2) + "\n", encoding="utf-8")
        temporary_lock.replace(lock_path)
        print(f"{item['name']}: {item['revision']} sha256={digest}", flush=True)


if __name__ == "__main__":
    main()
