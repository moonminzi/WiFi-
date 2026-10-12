#!/usr/bin/env python3
"""NAGO TL 앱 아이콘: NAGO DL과 같은 어두운 바탕 + 초록 말풍선, 안에 굵은 획으로 그린 '가'."""
import sys
from PIL import Image, ImageDraw

S = 1024
BG = (13, 17, 23)
GREEN = (63, 185, 80)


def stroke(d, pts, w, color):
    """둥근 끝 굵은 선(여러 점)"""
    d.line(pts, fill=color, width=w, joint="curve")
    r = w // 2
    for x, y in (pts[0], pts[-1]):
        d.ellipse((x - r, y - r, x + r, y + r), fill=color)


def main(out):
    # 4배로 그려 줄이면 가장자리가 매끈하다
    k = 4
    img = Image.new("RGB", (S * k, S * k), BG)
    d = ImageDraw.Draw(img)
    # 말풍선: 둥근 사각 + 왼쪽 아래 꼬리
    x0, y0, x1, y1 = 170 * k, 210 * k, 854 * k, 730 * k
    d.rounded_rectangle((x0, y0, x1, y1), radius=150 * k, fill=GREEN)
    d.polygon([(300 * k, 700 * k), (450 * k, 700 * k), (250 * k, 860 * k)], fill=GREEN)
    # '가': ㄱ(가로 긋고 아래로 휘어 내림) + ㅏ
    w = 78 * k
    stroke(d, [(330 * k, 360 * k), (560 * k, 360 * k), (548 * k, 470 * k), (500 * k, 560 * k), (420 * k, 630 * k)], w, BG)
    stroke(d, [(660 * k, 320 * k), (660 * k, 640 * k)], w, BG)
    stroke(d, [(660 * k, 480 * k), (745 * k, 480 * k)], w, BG)
    img = img.resize((S, S), Image.LANCZOS)
    img.save(out)


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "icon.png")
