"""Independent text demux/decode checks; does not claim Android MPV/SMB execution."""
import os
from pathlib import Path
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "artifacts/subtitle-formats"
ASS = """[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360
[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\b1}字幕测试{\\b0}\\NSecond line
"""
SSA = """[Script Info]
ScriptType: v4.00
[V4 Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
Style: Default,Arial,28,16777215,255,0,0,0,0,1,2,0,2,10,10,10,0,1
[Events]
Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0,0,0,,字幕测试\\NSecond line
"""
SAMI = """<SAMI>
<HEAD><TITLE>Subtitle test</TITLE></HEAD>
<BODY>
<SYNC Start=1000><P Class=ZHCC>字幕测试<br>Second line
<SYNC Start=2000><P Class=ZHCC>&nbsp;
</BODY></SAMI>
"""
CASES = {
    "srt": ("subrip", "1\n00:00:01,000 --> 00:00:02,000\n字幕测试\nSecond line\n"),
    "vtt": ("webvtt", "WEBVTT\n\ncue-1\n00:00:01.000 --> 00:00:02.000 align:center\n字幕测试\nSecond line\n"),
    "ass": ("ass", ASS),
    "ssa": ("ass", SSA),
    "smi": ("sami", SAMI),
    "sami": ("sami", SAMI),
    "sub": ("microdvd", "{1}{1}25.0\n{25}{50}字幕测试|Second line\n{75}{100}Final cue\n"),
}


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    results = []
    for extension, (codec, content) in CASES.items():
        source = OUT / f"clip.{extension}"
        source.write_text(content, encoding="utf-8")
        probe = subprocess.run([os.environ.get('THRU3D_FFPROBE', 'ffprobe'), "-v", "error", "-show_streams", "-of", "json", str(source)],
                               check=True, capture_output=True)
        streams = json.loads(probe.stdout)["streams"]
        assert len(streams) == 1 and streams[0]["codec_name"] == codec, (extension, streams)
        decoded = subprocess.run([os.environ.get('THRU3D_FFMPEG', 'ffmpeg'), "-v", "error", "-i", str(source), "-map", "0:s:0",
                                  "-c:s", "srt", "-f", "srt", "pipe:1"], check=True, capture_output=True).stdout.decode("utf-8")
        assert "字幕测试" in decoded and "Second line" in decoded, (extension, decoded)
        assert "00:00:01,000 --> 00:00:02,000" in decoded, (extension, decoded)
        results.append({"extension": extension, "detected_codec": codec, "unicode_and_timing": "passed"})
    report = {"state": "passed", "cases": results,
              "scope": "Desktop FFmpeg demux/decode; Android MPV, SMB network, ASS styling and Quest composition not exercised"}
    (OUT / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, ensure_ascii=False))


if __name__ == "__main__":
    main()
