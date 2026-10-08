"""Archive license texts from the project's pinned local dependencies for the About reader."""
import argparse
from pathlib import Path
from zipfile import ZipFile
import shutil
import os


def prepare(tool_root: Path):
    root = Path(__file__).resolve().parents[1]
    output = root / "third_party/player-licenses"
    output.mkdir(exist_ok=True)
    copies = {
        "mnn.txt": tool_root / "mnn/source-3.6.1-vrpp/LICENSE.txt",
        "rvm.txt": root / "models/licenses/RVM_GPL-3.0.txt",
        "depth.txt": root / "models/licenses/DepthAnythingV2_Apache-2.0.txt",
        "media3.txt": root / "third_party/gradle/LICENSE.txt",
        "jcifs.txt": root / "third_party/mpv/LICENSE.LGPL",
        "panorama-notice.txt": root / "app/godot/backgrounds/NOTICE.txt",
    }
    for name, source in copies.items():
        shutil.copyfile(source, output / name)
    (output / "hands.txt").write_bytes(
        (root / "app/godot/models/hands/NOTICE.txt").read_bytes() + b"\n\n" +
        (root / "app/godot/models/hands/LICENSE.txt").read_bytes())
    with ZipFile(tool_root / "downloads/ncnn-1.0.20260526-cp313-cp313-win_amd64.whl") as archive:
        (output / "ncnn.txt").write_bytes(archive.read("ncnn-1.0.20260526.dist-info/licenses/LICENSE.txt"))
    with ZipFile(tool_root / "downloads/godotopenxrvendorsaddon-5.1.0.zip") as archive:
        entries = sorted(n for n in archive.namelist() if "LICENSE" in n and not n.endswith("/"))
        (output / "vendors.txt").write_bytes(b"\n\n".join(n.encode() + b"\n\n" + archive.read(n) for n in entries).rstrip(b"\r\n") + b"\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--tool-root", type=Path, default=Path(os.environ.get("THRU3D_TOOL_ROOT", str(Path.home() / ".cache/thru3d-toolchain"))))
    prepare(parser.parse_args().tool_root)
