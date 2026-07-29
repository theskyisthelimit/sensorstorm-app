#!/usr/bin/env python3
"""Fetch swissALTI3D terrain for a Sensorstorm scene bundle.

    python3 Tools/blender/fetch_swissalti3d.py <bundle-dir> [--radius 300] [--resolution 2]

Writes `terrain.npz` and `terrain.json` next to `scene.json`. Blender reads those with its
bundled numpy — no GeoTIFF reader, no GDAL, nothing to install.

Uses the ASCII XYZ assets rather than the GeoTIFFs on purpose: a 2 m tile is a 1 MB zip that
the standard library can open, whereas the cloud-optimized GeoTIFFs would drag in a raster
stack for data that is, in the end, three columns of numbers.

Data: swisstopo swissALTI3D, open government data (opendata.swiss). Heights are LN02
orthometric — the same system the bundle's `h_lv95` column uses, which is why the terrain and
the camera track end up at the same altitude.
"""

from __future__ import annotations

import argparse
import io
import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.request
import zipfile

import numpy as np

STAC = ("https://data.geo.admin.ch/api/stac/v0.9/collections/"
        "ch.swisstopo.swissalti3d/items")
TIMEOUT = 120


def _ssl_context() -> "ssl.SSLContext | None":
    """A context that can actually verify data.geo.admin.ch.

    The python.org macOS builds ship with an empty trust store unless somebody ran
    `Install Certificates.command`, so the default context fails on every HTTPS call.
    certifi is what that installer wires up anyway, so use it directly.
    """
    try:
        import certifi
    except ImportError:
        return None
    return ssl.create_default_context(cafile=certifi.where())


def _get(url: str) -> bytes:
    try:
        with urllib.request.urlopen(url, timeout=TIMEOUT,
                                    context=_ssl_context()) as response:
            return response.read()
    except (urllib.error.URLError, ssl.SSLError):
        # Last resort: curl carries the system trust store and is on every Mac. Better than
        # telling somebody to repair their Python installation to download a heightmap.
        return subprocess.run(["curl", "-sSfL", "--max-time", str(TIMEOUT), url],
                              check=True, capture_output=True).stdout


def tile_urls(bbox: tuple[float, float, float, float], resolution: int) -> list[str]:
    """Newest asset per tile covering `bbox` (WGS84 west, south, east, north).

    swisstopo keeps every survey year in the same collection, so the same square comes back
    several times and only the most recent one is wanted.
    """
    query = f"{STAC}?bbox={','.join(f'{v:.6f}' for v in bbox)}&limit=100"
    features = json.loads(_get(query)).get("features", [])

    newest: dict[str, tuple[int, str]] = {}
    suffix = f"_{resolution}_2056_5728.xyz.zip"
    for feature in features:
        parts = feature["id"].split("_")
        if len(parts) < 3:
            continue
        year, square = int(parts[1]), parts[2]
        for name, asset in feature.get("assets", {}).items():
            if not name.endswith(suffix):
                continue
            if square not in newest or year > newest[square][0]:
                newest[square] = (year, asset["href"])
    return [href for _, href in sorted(newest.values())]


def read_tile(url: str) -> np.ndarray:
    """The XYZ payload as an (N, 3) array of LV95 east, north, height."""
    with zipfile.ZipFile(io.BytesIO(_get(url))) as archive:
        name = next(n for n in archive.namelist() if n.lower().endswith(".xyz"))
        with archive.open(name) as handle:
            text = io.TextIOWrapper(handle, encoding="ascii")
            # The first line is a header ("X Y Z") in some vintages and data in others.
            first = text.readline()
            rows = []
            try:
                rows.append([float(v) for v in first.split()])
            except ValueError:
                pass
            for line in text:
                rows.append([float(v) for v in line.split()])
    return np.asarray(rows, dtype=np.float64)


def to_grid(points: np.ndarray, spacing: float
            ) -> tuple[np.ndarray, float, float]:
    """Scattered LV95 points onto a regular grid, plus its south-west corner.

    swissALTI3D is already a regular raster; this only recovers the shape that the flat XYZ
    listing threw away, so index arithmetic is enough and no interpolation is involved.
    """
    east, north, height = points[:, 0], points[:, 1], points[:, 2]
    east0, north0 = east.min(), north.min()

    columns = np.rint((east - east0) / spacing).astype(np.int64)
    rows = np.rint((north - north0) / spacing).astype(np.int64)

    grid = np.full((rows.max() + 1, columns.max() + 1), np.nan)
    grid[rows, columns] = height
    return grid, float(east0), float(north0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle")
    parser.add_argument("--radius", type=float, default=300,
                        help="metres around the anchor to keep (default 300)")
    parser.add_argument("--resolution", type=int, default=2, choices=(2,),
                        help="grid spacing in metres; 0.5 exists but is 60x the data")
    args = parser.parse_args()

    with open(os.path.join(args.bundle, "scene.json"), encoding="utf-8") as handle:
        manifest = json.load(handle)

    anchor = manifest.get("anchor")
    if not anchor:
        print("This bundle has no GPS anchor, so there is nowhere to fetch terrain for.")
        return 1
    if not anchor.get("lv95IsInRange"):
        print("The anchor is outside Switzerland; swissALTI3D does not cover it.")
        return 1

    latitude, longitude = anchor["latitude"], anchor["longitude"]
    # Rough degrees for the requested radius — only used to pick tiles, so approximate is fine.
    d_lat = args.radius / 111_320
    d_lon = args.radius / (111_320 * np.cos(np.radians(latitude)))
    bbox = (longitude - d_lon, latitude - d_lat, longitude + d_lon, latitude + d_lat)

    urls = tile_urls(bbox, args.resolution)
    if not urls:
        print("swisstopo returned no tiles for this area.")
        return 1

    print(f"anchor {latitude:.6f}, {longitude:.6f} — {len(urls)} tile(s) at "
          f"{args.resolution} m")
    chunks = []
    for url in urls:
        print(f"  {os.path.basename(url)}")
        chunks.append(read_tile(url))
    points = np.vstack(chunks)

    # Crop to the radius before gridding: a full tile is a square kilometre, and carrying
    # 250 000 vertices into Blender for a 30 m walk helps nobody.
    east0, north0 = anchor["lv95East"], anchor["lv95North"]
    keep = ((np.abs(points[:, 0] - east0) <= args.radius)
            & (np.abs(points[:, 1] - north0) <= args.radius))
    points = points[keep]
    if points.size == 0:
        print("Nothing within the radius — is the anchor inside the fetched tiles?")
        return 1

    grid, grid_east, grid_north = to_grid(points, args.resolution)
    print(f"grid {grid.shape[1]}x{grid.shape[0]} @ {args.resolution} m, "
          f"height {np.nanmin(grid):.1f}..{np.nanmax(grid):.1f} m")

    np.savez_compressed(os.path.join(args.bundle, "terrain.npz"), heights=grid)
    with open(os.path.join(args.bundle, "terrain.json"), "w", encoding="utf-8") as handle:
        json.dump({
            "source": "swisstopo swissALTI3D",
            "crs": "EPSG:2056",
            "heightReference": "LN02 orthometric",
            "spacing": args.resolution,
            # South-west corner of cell (0, 0), in LV95.
            "originEast": grid_east,
            "originNorth": grid_north,
            "rows": int(grid.shape[0]),
            "columns": int(grid.shape[1]),
            "anchorEast": east0,
            "anchorNorth": north0,
            "anchorHeight": anchor["lv95Height"],
        }, handle, indent=2)

    print(f"wrote terrain.npz and terrain.json to {args.bundle}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
