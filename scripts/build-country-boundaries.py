#!/usr/bin/env python3
"""Build the API's embedded country-boundary table.

"Your travels" counts distinct COUNTRIES beside its distinct cities, and the
only geographic fact the trips-list payload carries is a hub city's
coordinate (the pin the footprint map already draws). So the country is
derived from that coordinate, server side, by point-in-polygon against this
table — no per-city geocoding request, no new column, and every trip already
in the database gets its countries the moment the code ships.

Source: Natural Earth 1:50m Admin 0 – Countries. Public domain (no attribution
required, though the project asks nicely and we credit it in the spec).

Why 1:50m and not 1:110m — 110m drops every microstate a traveler actually
visits (Monaco, Vatican, San Marino, Liechtenstein, Malta, Singapore). Why not
1:10m — 25 MB of source for coastline detail that the nearest-land fallback in
country_lookup.go already covers.

Output: src/packages/api/data/country_boundaries.json.gz, gzipped compact JSON

    {"source": ..., "precision": 2, "countries": [
       {"c": "GR", "p": [{"o": [lng,lat,lng,lat,...], "h": [[...],...]}, ...]}
    ]}

Rings are FLAT coordinate arrays, not [[lng,lat],...] pairs: Go unmarshals a
flat array into one []float64 per ring (1.6k allocations) instead of one slice
per vertex (50k).

Run from anywhere; writes relative to the repo root:

    python3 scripts/build-country-boundaries.py
"""

import gzip
import json
import math
import pathlib
import sys
import urllib.request

SOURCE_URL = (
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/"
    "master/geojson/ne_50m_admin_0_countries.geojson"
)
SOURCE_NAME = "Natural Earth 1:50m Admin 0 – Countries (public domain)"

OUT_PATH = (
    pathlib.Path(__file__).resolve().parent.parent
    / "src/packages/api/data/country_boundaries.json.gz"
)

# Coordinate precision, decimal degrees. 2 ≈ 1.1 km, which is coarser than the
# rounding error but finer than 1:50m's own coastline generalisation — going to
# 3 costs 60% more bytes and changed nothing in the 34k-city validation.
PRECISION = 2

# Per-ring Douglas–Peucker tolerance: the ring's own bounding diagonal over
# DIVISOR, capped at CAP degrees. Scaling by the ring's size is the whole
# point — a fixed tolerance large enough to flatten Russia's coastline erases
# Monaco. Tuned against the validation set: at CAP=0.05 Monaco disappears.
SIMPLIFY_DIVISOR = 150
SIMPLIFY_CAP = 0.03

# Features Natural Earth ships without a usable ISO_A2. The first two get the
# ISO 3166-1 code of the state that ISO itself files them under — ISO assigns
# no code to either — because this table exists to COUNT countries, and a
# traveler who was in Hargeisa should not silently count zero.
ISO_OVERRIDES = {
    "Somaliland": "SO",
    "N. Cyprus": "CY",
}
# ISO_A2 for Taiwan in the source is the subdivision-style "CN-TW"; ISO
# 3166-1 alpha-2 for Taiwan is "TW", and this table only speaks alpha-2.
CODE_REWRITES = {"CN-TW": "TW"}
# Uninhabited disputed territory with no ISO code and no travel meaning. A pin
# there resolves through the nearest-land fallback instead.
DROP_FEATURES = {"Siachen Glacier"}


def iso_code(props):
    """ISO 3166-1 alpha-2 for a Natural Earth feature, or None to skip it."""
    name = props.get("NAME")
    if name in DROP_FEATURES:
        return None
    for key in ("ISO_A2", "ISO_A2_EH"):
        value = props.get(key)
        if value and value != "-99":
            return CODE_REWRITES.get(value, value)
    return ISO_OVERRIDES.get(name)


def polygons(geometry):
    """Every polygon of a feature, each as [outer_ring, *hole_rings]."""
    kind, coords = geometry["type"], geometry["coordinates"]
    if kind == "Polygon":
        return [coords]
    if kind == "MultiPolygon":
        return coords
    return []


def simplify(points, epsilon):
    """Douglas–Peucker, iterative so a 20k-point coastline can't blow the stack."""
    if len(points) < 4 or epsilon <= 0:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        i, j = stack.pop()
        if j <= i + 1:
            continue
        x1, y1 = points[i]
        x2, y2 = points[j]
        dx, dy = x2 - x1, y2 - y1
        span = math.hypot(dx, dy)
        worst, worst_at = -1.0, -1
        for k in range(i + 1, j):
            x, y = points[k]
            dist = (
                math.hypot(x - x1, y - y1)
                if span == 0
                else abs(dy * x - dx * y + x2 * y1 - y2 * x1) / span
            )
            if dist > worst:
                worst, worst_at = dist, k
        if worst > epsilon:
            keep[worst_at] = True
            stack.append((i, worst_at))
            stack.append((worst_at, j))
    return [p for p, k in zip(points, keep) if k]


def encode_ring(ring):
    """Simplify, round and flatten one ring; None if it collapsed to nothing."""
    points = [(x, y) for x, y in ring]
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    diagonal = math.hypot(max(xs) - min(xs), max(ys) - min(ys))
    points = simplify(points, min(SIMPLIFY_CAP, diagonal / SIMPLIFY_DIVISOR))

    rounded = [(round(x, PRECISION), round(y, PRECISION)) for x, y in points]
    deduped = [rounded[0]]
    for point in rounded[1:]:
        if point != deduped[-1]:
            deduped.append(point)
    # Under 4 distinct vertices there is no enclosed area left to test against.
    if len(deduped) < 4:
        return None
    return [value for point in deduped for value in point]


def main():
    print(f"fetching {SOURCE_URL}", file=sys.stderr)
    with urllib.request.urlopen(SOURCE_URL, timeout=180) as response:
        source = json.load(response)

    countries, ring_count, vertex_count = [], 0, 0
    for feature in source["features"]:
        code = iso_code(feature["properties"])
        if not code:
            continue
        shapes = []
        for polygon in polygons(feature["geometry"]):
            outer = encode_ring(polygon[0])
            if outer is None:
                continue
            shape = {"o": outer}
            holes = [h for h in (encode_ring(r) for r in polygon[1:]) if h]
            if holes:
                shape["h"] = holes
            shapes.append(shape)
            ring_count += 1 + len(holes)
            vertex_count += (len(outer) + sum(len(h) for h in holes)) // 2
        if shapes:
            countries.append({"c": code, "p": shapes})

    # One entry per ISO code: Natural Earth splits a few states across features
    # (mainland + dependency), and the lookup wants them under one key.
    merged = {}
    for entry in countries:
        merged.setdefault(entry["c"], []).extend(entry["p"])
    table = {
        "source": SOURCE_NAME,
        "precision": PRECISION,
        "countries": [
            {"c": code, "p": shapes} for code, shapes in sorted(merged.items())
        ],
    }

    payload = json.dumps(table, separators=(",", ":")).encode("utf-8")
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    # mtime=0 so a rebuild with unchanged input produces an identical file and
    # an empty git diff.
    with gzip.GzipFile(OUT_PATH, "wb", compresslevel=9, mtime=0) as out:
        out.write(payload)

    print(
        f"{len(table['countries'])} countries, {ring_count} rings, "
        f"{vertex_count} vertices — {len(payload) / 1024:.0f} KB raw, "
        f"{OUT_PATH.stat().st_size / 1024:.0f} KB gzipped\n"
        f"wrote {OUT_PATH}",
        file=sys.stderr,
    )


if __name__ == "__main__":
    main()
