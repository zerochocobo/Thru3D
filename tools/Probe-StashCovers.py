"""Read-only Stash cover audit. Checks actual image bytes, not just HTTP 200.

Only GraphQL queries and bounded GETs are sent. No media generation or playback.
Reports contain scene IDs and resource metadata, never titles or API keys.
"""
import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import urllib.error
import urllib.parse
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    base = args.url.rstrip("/")
    origin = urllib.parse.urlsplit(base)
    if origin.scheme not in ("http", "https") or not origin.hostname or origin.username or origin.password:
        parser.error("Use an HTTP(S) server address without credentials")

    def get(url, data=None):
        target = urllib.parse.urlsplit(url)
        if (target.scheme, target.netloc) != (origin.scheme, origin.netloc):
            return {"status": 0, "error": "different_origin"}
        # LAN diagnosis must not silently use the desktop's HTTP proxy.
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, req, fp, code, msg, headers, newurl):
                return None
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        headers = {"Content-Type": "application/json"} if data else {"Range": "bytes=0-4095"}
        try:
            with opener.open(urllib.request.Request(url, data=data, headers=headers), timeout=15) as response:
                body = response.read(4 * 1024 * 1024 if data else 4096)
                if data:
                    return json.loads(body)
                return {"status": response.status, "type": response.headers.get_content_type(),
                        "length": response.headers.get("Content-Range") or response.headers.get("Content-Length"),
                        "jpeg": body.startswith(b"\xff\xd8\xff"), "png": body.startswith(b"\x89PNG"),
                        "webp": body[:4] == b"RIFF" and body[8:12] == b"WEBP",
                        "svg": b"<svg" in body[:1024], "vtt": body.lstrip().startswith(b"WEBVTT")}
        except urllib.error.HTTPError as error:
            return {"status": error.code}
        except (OSError, ValueError):
            return {"status": 0, "error": "request_failed"}

    query = {"query": 'query { version { version } findScenes(filter: {per_page: -1}) { count scenes { id paths { screenshot vtt } } } }'}
    catalog = get(base + "/graphql", json.dumps(query).encode())
    if "data" not in catalog or catalog.get("errors"):
        raise RuntimeError("Stash catalog query failed; check authentication and address")

    def audit(scene):
        result = {"id": scene["id"], "screenshot": get(urllib.parse.urljoin(base + "/", scene["paths"]["screenshot"]))}
        image = result["screenshot"]
        result["real_image"] = any(image.get(kind) for kind in ("jpeg", "png", "webp"))
        if not result["real_image"] and scene["paths"].get("vtt"):
            result["fallback_vtt"] = get(urllib.parse.urljoin(base + "/", scene["paths"]["vtt"]))
        return result

    found = catalog["data"]["findScenes"]
    with ThreadPoolExecutor(max_workers=4) as workers:
        rows = list(workers.map(audit, found["scenes"]))
    counts = Counter("real_image" if row["real_image"] else "svg_placeholder" if row["screenshot"].get("svg") else "other" for row in rows)
    summary = {"server_version": catalog["data"]["version"]["version"], "catalog_count": found["count"],
               "checked": len(rows), **counts,
               "missing_with_vtt": sum(bool(row.get("fallback_vtt", {}).get("vtt")) for row in rows),
               "missing_vtt_404": sum(row.get("fallback_vtt", {}).get("status") == 404 for row in rows)}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps({"summary": summary, "scenes": rows}, indent=2), encoding="utf8")
    print(json.dumps(summary))


if __name__ == "__main__":
    main()
