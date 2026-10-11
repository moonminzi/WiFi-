#!/usr/bin/env python3
"""NAGO TL 시험용 가짜 망가 페이지 만들기.

흰 종이 + 칸 + 스크린톤 + 그림 선 위에, 둥근 말풍선(검은 테두리) 안 세로쓰기 일본어,
사각 나레이션 상자, 그림 위 효과음을 그린다. 정답(글자 픽셀이 실제로 차지하는 상자,
말풍선 타원, 원문)을 JSON으로 같이 남긴다.

출력: <out>/pageN.png(눈으로 보기), pageN.rgba(가로·세로 각 4바이트 + RGBA), pageN.json
"""
import json
import math
import os
import random
import struct
import sys

from PIL import Image, ImageDraw, ImageFont

FONT = "/usr/share/fonts/opentype/ipafont-gothic/ipag.ttf"

LINES = [
    ["おい、待てよ！", "どこへ行くんだ？"],
    ["今日こそ", "決着をつけてやる"],
    ["そんなこと", "知らないわ"],
    ["お腹すいた…"],
    ["先生！", "大変です！"],
    ["本当に", "大丈夫なの？"],
    ["ふざけるな！"],
    ["約束したじゃないか"],
]


def vertical_text(draw, x_right, y_top, columns, size, font, fill=255):
    """오른쪽 칸부터 왼쪽으로, 위에서 아래로 글자 하나씩 그린다(draw는 글자 마스크 레이어)."""
    gap = int(size * 0.25)
    x = x_right
    for col in columns:
        y = y_top
        for ch in col:
            # 구두점은 세로쓰기에서 오른쪽 위로 붙는다(대충 흉내)
            if ch in "、。":
                draw.text((x - size * 0.45, y - size * 0.55), ch, font=font, fill=fill)
            elif ch in "ー…":
                # 세로쓰기에서는 장음·말줄임표가 세로로 선다
                img = Image.new("L", (size * 2, size * 2), 0)
                d2 = ImageDraw.Draw(img)
                d2.text((size // 2, size // 2), ch, font=font, fill=255)
                img = img.rotate(-90, expand=False)
                draw.bitmap((x - size - size // 2, y - size // 2), img, fill=fill)
            else:
                draw.text((x - size, y), ch, font=font, fill=fill)
            y += size + 2
        x -= size + gap
    return None


def ink_box(img, region, threshold=110):
    """region 안에서 어두운 픽셀이 실제로 있는 상자"""
    x0, y0, x1, y1 = [int(v) for v in region]
    px = img.load()
    xs, ys = [], []
    for y in range(max(0, y0), min(img.height, y1)):
        for x in range(max(0, x0), min(img.width, x1)):
            r, g, b = px[x, y][:3]
            if (r + g + b) / 3 < threshold:
                xs.append(x)
                ys.append(y)
    if not xs:
        return None
    return [min(xs), min(ys), max(xs) - min(xs) + 1, max(ys) - min(ys) + 1]


class TextLayer:
    """글자만 따로 그리는 마스크. 다 그린 뒤 페이지에 검게 찍고, 정답 상자·마스크로 쓴다."""

    def __init__(self, w, h):
        self.all = Image.new("L", (w, h), 0)

    def element(self):
        layer = Image.new("L", self.all.size, 0)
        return layer, ImageDraw.Draw(layer)

    def commit(self, page, layer, color=(0, 0, 0, 255), stroke=None):
        bbox = layer.getbbox()
        if stroke is not None:
            # 흰 테두리(효과음): 마스크를 넓혀 흰색으로 먼저 찍는다
            from PIL import ImageFilter
            wide = layer.filter(ImageFilter.MaxFilter(stroke * 2 + 1))
            page.paste(Image.new("RGBA", page.size, (255, 255, 255, 255)), (0, 0), wide)
        page.paste(Image.new("RGBA", page.size, color), (0, 0), layer)
        self.all.paste(255, (0, 0), layer)
        return [bbox[0], bbox[1], bbox[2] - bbox[0], bbox[3] - bbox[1]] if bbox else None


def make_page(seed, out_dir, w=1200, h=1700):
    rnd = random.Random(seed)
    img = Image.new("RGBA", (w, h), (255, 255, 255, 255))
    d = ImageDraw.Draw(img)
    # 칸 나누기
    panels = [(40, 40, w - 40, 620), (40, 650, w // 2 - 15, 1200), (w // 2 + 15, 650, w - 40, 1200), (40, 1230, w - 40, h - 40)]
    for p in panels:
        d.rectangle(p, outline=(0, 0, 0, 255), width=5)
    # 스크린톤(점) 과 그림 선
    for p in panels[1:3]:
        x0, y0, x1, y1 = p
        for yy in range(y0 + 300, y1 - 5, 9):
            for xx in range(x0 + 5, x1 - 5, 9):
                d.ellipse((xx, yy, xx + 3, yy + 3), fill=(90, 90, 90, 255))
    for _ in range(25):
        p = rnd.choice(panels)
        x0, y0, x1, y1 = p
        pts = [(rnd.randint(x0 + 10, x1 - 10), rnd.randint(y0 + 10, y1 - 10)) for _ in range(3)]
        d.line(pts, fill=(20, 20, 20, 255), width=rnd.choice([2, 3, 4]))

    font_size = 34
    font = ImageFont.truetype(FONT, font_size)
    small = ImageFont.truetype(FONT, 15)
    blocks = []
    text = TextLayer(w, h)

    # 말풍선 4개(타원, 흰 바탕 + 검은 테두리)
    bubble_specs = [(300, 330), (850, 300), (330, 900), (880, 930)]
    for i, (cx, cy) in enumerate(bubble_specs):
        lines = LINES[(seed + i) % len(LINES)]
        cols = len(lines)
        longest = max(len(s) for s in lines)
        tw = cols * (font_size + int(font_size * 0.25))
        th = longest * (font_size + 2)
        rx = tw / 2 + 55 + rnd.randint(0, 20)
        ry = th / 2 + 60 + rnd.randint(0, 20)
        d.ellipse((cx - rx, cy - ry, cx + rx, cy + ry), fill=(255, 255, 255, 255), outline=(0, 0, 0, 255), width=4)
        # 꼬리
        d.polygon([(cx - 15, cy + ry - 8), (cx + 15, cy + ry - 8), (cx + 40, cy + ry + 45)], fill=(255, 255, 255, 255), outline=(0, 0, 0, 255))
        d.line([(cx - 15, cy + ry - 6), (cx + 40, cy + ry + 45), (cx + 15, cy + ry - 6)], fill=(0, 0, 0, 255), width=4)
        d.ellipse((cx - rx + 4, cy - ry + 4, cx + rx - 4, cy + ry - 4), fill=(255, 255, 255, 255))
        x_right = cx + tw / 2
        y_top = cy - th / 2
        layer, ld = text.element()
        vertical_text(ld, x_right, y_top, lines, font_size, font)
        # 첫 칸 옆에 후리가나(작은 글자) 몇 개
        if i % 2 == 0:
            for k in range(3):
                ld.text((x_right + 2, y_top + k * 18), "かな"[k % 2], font=small, fill=255)
        box = text.commit(img, layer)
        blocks.append({"kind": "speech", "box": box, "source": "".join(lines),
                       "bubble": {"cx": cx, "cy": cy, "rx": rx, "ry": ry}})

    # 나레이션 상자(사각, 가로쓰기)
    nx0, ny0, nx1, ny1 = 80, 1260, 560, 1340
    d.rectangle((nx0, ny0, nx1, ny1), fill=(255, 255, 255, 255), outline=(0, 0, 0, 255), width=3)
    layer, ld = text.element()
    ld.text((nx0 + 20, ny0 + 22), "そして三年後――", font=font, fill=255)
    blocks.append({"kind": "narration", "box": text.commit(img, layer),
                   "source": "そして三年後――", "bubble": {"rect": [nx0, ny0, nx1 - nx0, ny1 - ny0]}})

    # 효과음: 회색 그림 위에 큰 글자
    d.rectangle((640, 1300, w - 60, h - 70), fill=(150, 150, 150, 255))
    for _ in range(40):
        x = rnd.randint(640, w - 60)
        d.line([(x, 1300), (x + rnd.randint(-60, 60), h - 70)], fill=(110, 110, 110, 255), width=2)
    big = ImageFont.truetype(FONT, 90)
    layer, ld = text.element()
    ld.text((700, 1380), "ドドド", font=big, fill=255)
    blocks.append({"kind": "sfx", "box": text.commit(img, layer, stroke=4), "source": "ドドド", "bubble": None})

    name = f"page{seed}"
    img.convert("RGB").save(os.path.join(out_dir, name + ".png"))
    with open(os.path.join(out_dir, name + ".rgba"), "wb") as f:
        f.write(struct.pack("<II", w, h))
        f.write(img.tobytes())
    with open(os.path.join(out_dir, name + ".mask"), "wb") as f:
        f.write(struct.pack("<II", w, h))
        f.write(bytes(1 if v > 127 else 0 for v in text.all.tobytes()))
    with open(os.path.join(out_dir, name + ".json"), "w") as f:
        json.dump({"width": w, "height": h, "blocks": blocks}, f, ensure_ascii=False, indent=1)
    return name


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else "fixtures"
    os.makedirs(out, exist_ok=True)
    for s in range(3):
        print(make_page(s, out))
