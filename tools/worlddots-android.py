#!/usr/bin/env python3
"""iOS의 WifiScan/WorldDotsData.swift(tools/worldgrid.py로 만든 점 지도)를 안드로이드 앱 asset으로 옮긴다.

같은 데이터를 두 번 만들지 않으려고 Swift 파일을 그대로 읽는다.
  python3 tools/worlddots-android.py   →   android/app/src/main/assets/worlddots.txt

형식: 첫 줄 "cols rows step yTop", 그 아래로 RLE 한 줄씩(`#12`는 땅 12칸, 소문자는 나라(kjugsdfewcbai), `.`은 바다).
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "WifiScan" / "WorldDotsData.swift"
OUT = ROOT / "android" / "app" / "src" / "main" / "assets" / "worlddots.txt"


def main():
    text = SRC.read_text()
    value = {k: re.search(rf"static let {k} = ([0-9.]+)", text).group(1) for k in ("cols", "rows", "step", "yTop")}
    body = text.split('static let rle = """', 1)[1].split('"""', 1)[0]
    lines = [line.strip() for line in body.splitlines() if line.strip()]
    assert len(lines) == int(value["rows"]), (len(lines), value["rows"])
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(f'{value["cols"]} {value["rows"]} {value["step"]} {value["yTop"]}\n' + "\n".join(lines) + "\n")
    print(f"{OUT.relative_to(ROOT)}: {len(lines)} rows")


if __name__ == "__main__":
    main()
