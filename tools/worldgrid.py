"""route 지도용 점 격자 만들기: Natural Earth(world-atlas 2.0.2) 육지·국가 → 메르카토르 0.5° 격자 RLE.

    npm pack world-atlas@2.0.2 && tar xzf world-atlas-2.0.2.tgz
    python3 tools/worldgrid.py package > WifiScan/WorldDotsData.swift

PIL(Pillow)이 필요하다. 칸 값: `.` 바다, `#` 땅, `k` `j` `u` `g` 나갈 국가(kr jp us uk = VPNRegion 순서).
"""
import json, math, sys
from PIL import Image, ImageDraw

STEP = 0.5                  # 칸 하나(경도°, 메르카토르°)
Y_TOP, Y_BOT = 120.0, -68.0 # 메르카토르° — 위도로 약 76°N ~ 56°S
COLS = int(360 / STEP)
ROWS = int((Y_TOP - Y_BOT) / STEP)
SS = 4                      # 칸 하나를 SS×SS로 쪼개서 덮인 비율을 잰다
TH = 64                     # 칸의 1/4 이상이 땅이면 점
COUNTRIES = {"410": "k", "392": "j", "840": "u", "826": "g"}   # ISO 숫자 코드: kr jp us uk


def merc(lat):
    lat = max(-85.0, min(85.0, lat))
    return math.degrees(math.log(math.tan(math.pi / 4 + math.radians(lat) / 2)))


def decode_arcs(topo):
    sx, sy = topo["transform"]["scale"]
    tx, ty = topo["transform"]["translate"]
    arcs = []
    for arc in topo["arcs"]:
        x = y = 0
        pts = []
        for dx, dy in arc:
            x += dx
            y += dy
            pts.append((x * sx + tx, y * sy + ty))
        arcs.append(pts)
    return arcs


def ring(arcs, idx):
    pts = []
    for i in idx:
        a = arcs[i] if i >= 0 else arcs[~i][::-1]
        pts.extend(a if not pts else a[1:])
    return pts


def polygons(geom, arcs):
    if geom["type"] == "Polygon":
        return [[ring(arcs, r) for r in geom["arcs"]]]
    if geom["type"] == "MultiPolygon":
        return [[ring(arcs, r) for r in p] for p in geom["arcs"]]
    return []


def coverage(polys):
    img = Image.new("L", (COLS * SS, ROWS * SS), 0)
    draw = ImageDraw.Draw(img)

    def px(p):
        lon, lat = p
        return ((lon + 180) / STEP * SS, (Y_TOP - merc(lat)) / STEP * SS)

    for poly in polys:
        for k, r in enumerate(poly):    # 첫 고리는 땅, 나머지는 구멍(호수)
            if len(r) >= 3:
                draw.polygon([px(p) for p in r], fill=0 if k else 255)
    return img.resize((COLS, ROWS), Image.BOX).load()


def rle(row):
    out, i = [], 0
    while i < len(row):
        k = i
        while k < len(row) and row[k] == row[i]:
            k += 1
        out.append(row[i] + (str(k - i) if k - i > 1 else ""))
        i = k
    return "".join(out)


def main(geo):
    land_topo = json.load(open(f"{geo}/land-50m.json"))
    arcs = decode_arcs(land_topo)
    land = coverage([p for g in land_topo["objects"]["land"]["geometries"] for p in polygons(g, arcs)])

    ctopo = json.load(open(f"{geo}/countries-50m.json"))
    carcs = decode_arcs(ctopo)
    masks = {COUNTRIES[g["id"]]: coverage(polygons(g, carcs))
             for g in ctopo["objects"]["countries"]["geometries"] if g.get("id") in COUNTRIES}

    lines = []
    for j in range(ROWS):
        row = []
        for i in range(COLS):
            cov = land[i, j]
            c = next((s for s, m in masks.items() if m[i, j] >= TH and m[i, j] >= cov * 0.5), None)
            row.append(c or ("#" if cov >= TH else "."))
        lines.append(rle(row))

    print("// tools/worldgrid.py로 만든 파일. 손으로 고치지 않는다.")
    print("// 지도 데이터: Natural Earth 1:50m (퍼블릭 도메인), world-atlas 2.0.2")
    print()
    print("extension WorldDots {")
    print(f"    static let cols = {COLS}")
    print(f"    static let rows = {ROWS}")
    print(f"    static let step = {STEP}")
    print(f"    static let yTop = {Y_TOP}")
    print()
    print("    /// 위에서 아래로 한 줄씩. `#12`는 땅 12칸, 숫자가 없으면 1칸")
    print('    static let rle = """')
    for line in lines:
        print("        " + line)
    print('        """')
    print("}")


if __name__ == "__main__":
    main(sys.argv[1])
