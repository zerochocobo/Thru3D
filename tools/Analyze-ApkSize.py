"""Report actual compressed APK costs and compare two APKs without extracting them."""
import argparse
import hashlib
import json
from collections import defaultdict
from pathlib import Path
from zipfile import ZipFile


def inspect(path):
    groups = defaultdict(lambda: {"stored_bytes": 0, "uncompressed_bytes": 0, "entries": 0})
    with path.open("rb") as source:
        sha256 = hashlib.file_digest(source, "sha256").hexdigest()
    with ZipFile(path) as archive:
        entries = archive.infolist()
        for entry in entries:
            parts = entry.filename.split("/")
            group = "/".join(parts[:2]) if parts[0] == "assets" else parts[0]
            if entry.filename.startswith("assets/rvm/reference/"):
                group = "assets/rvm/reference"
            groups[group]["stored_bytes"] += entry.compress_size
            groups[group]["uncompressed_bytes"] += entry.file_size
            groups[group]["entries"] += 1
        diagnostics = [e.filename for e in entries if e.filename.startswith(("assets/media/", "assets/rvm/reference/"))]
        runtime = {}
        for entry in entries:
            name = entry.filename
            if (name.startswith("lib/") and name.endswith(".so")) or (
                name.startswith(("assets/rvm/", "assets/rvm-mnn/", "assets/depth-mnn/"))
                and name.endswith((".bin", ".param", ".mnn"))
            ) or (name.startswith("assets/.godot/imported/belfast_sunset_puresky") and name.endswith(".ctex")):
                with archive.open(entry) as source:
                    runtime[name] = hashlib.file_digest(source, "sha256").hexdigest()
        return {
            "apk": str(path.resolve()),
            "sha256": sha256,
            "bytes": path.stat().st_size,
            "groups": dict(sorted(groups.items(), key=lambda item: item[1]["stored_bytes"], reverse=True)),
            "diagnostic_entries": diagnostics,
            "runtime_payload_sha256": runtime,
            "largest_entries": [{"path": e.filename, "stored_bytes": e.compress_size, "uncompressed_bytes": e.file_size}
                                for e in sorted(entries, key=lambda e: e.compress_size, reverse=True)[:20]],
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("apk", type=Path)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = {"current": inspect(args.apk)}
    if args.baseline:
        result["baseline"] = inspect(args.baseline)
        result["saved_bytes"] = result["baseline"]["bytes"] - result["current"]["bytes"]
        result["saved_percent"] = 100 * result["saved_bytes"] / result["baseline"]["bytes"]
        result["runtime_payload_unchanged"] = result["baseline"]["runtime_payload_sha256"] == result["current"]["runtime_payload_sha256"]
    output = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(output, encoding="utf-8")
    print(output)


if __name__ == "__main__":
    main()
