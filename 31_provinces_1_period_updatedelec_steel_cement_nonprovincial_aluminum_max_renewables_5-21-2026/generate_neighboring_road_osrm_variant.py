"""
Generate a road_osrm transport variant limited to neighboring provinces.

The source road_osrm variant contains every directed province pair. This script
filters those route instances to province pairs that share a provincial border,
while preserving the existing JSON schema, edge costs, and directed edges.

Usage:
    python generate_neighboring_road_osrm_variant.py
"""

import json
import re
from pathlib import Path


BASE = Path(__file__).parent
SOURCE_DIR = BASE / "assets" / "transport_variants" / "road_osrm"
TARGET_DIR = BASE / "assets" / "transport_variants" / "road_osrm_neighboring"

TRANSPORT_FILES = [
    "cement_transport.json",
    "crudesteel_transport.json",
    "dri_transport.json",
    "ironore_transport.json",
    "steelscrap_transport.json",
]

REGION_PAIR_RE = re.compile(r"_transport_(Region\d+[A-Za-z]+)_to_(Region\d+[A-Za-z]+)$")

# Undirected provincial adjacencies for the 31 mainland model regions. Hainan is
# connected to Guangdong via the Qiongzhou Strait ferry/road corridor.
NEIGHBOR_PAIRS = {
    ("Region1Beijing", "Region2Tianjin"),
    ("Region1Beijing", "Region3Hebei"),
    ("Region2Tianjin", "Region3Hebei"),
    ("Region3Hebei", "Region4Shanxi"),
    ("Region3Hebei", "Region5Innermongolia"),
    ("Region3Hebei", "Region6Liaoning"),
    ("Region3Hebei", "Region15Shandong"),
    ("Region3Hebei", "Region16Henan"),
    ("Region4Shanxi", "Region5Innermongolia"),
    ("Region4Shanxi", "Region16Henan"),
    ("Region4Shanxi", "Region27Shaanxi"),
    ("Region5Innermongolia", "Region6Liaoning"),
    ("Region5Innermongolia", "Region7Jilin"),
    ("Region5Innermongolia", "Region8Heilongjiang"),
    ("Region5Innermongolia", "Region27Shaanxi"),
    ("Region5Innermongolia", "Region28Gansu"),
    ("Region5Innermongolia", "Region30Ningxia"),
    ("Region6Liaoning", "Region7Jilin"),
    ("Region7Jilin", "Region8Heilongjiang"),
    ("Region9Shanghai", "Region10Jiangsu"),
    ("Region9Shanghai", "Region11Zhejiang"),
    ("Region10Jiangsu", "Region11Zhejiang"),
    ("Region10Jiangsu", "Region12Anhui"),
    ("Region10Jiangsu", "Region15Shandong"),
    ("Region11Zhejiang", "Region12Anhui"),
    ("Region11Zhejiang", "Region13Fujian"),
    ("Region11Zhejiang", "Region14Jiangxi"),
    ("Region12Anhui", "Region14Jiangxi"),
    ("Region12Anhui", "Region15Shandong"),
    ("Region12Anhui", "Region16Henan"),
    ("Region12Anhui", "Region17Hubei"),
    ("Region13Fujian", "Region14Jiangxi"),
    ("Region13Fujian", "Region19Guangdong"),
    ("Region14Jiangxi", "Region17Hubei"),
    ("Region14Jiangxi", "Region18Hunan"),
    ("Region14Jiangxi", "Region19Guangdong"),
    ("Region15Shandong", "Region16Henan"),
    ("Region16Henan", "Region17Hubei"),
    ("Region16Henan", "Region27Shaanxi"),
    ("Region17Hubei", "Region18Hunan"),
    ("Region17Hubei", "Region22Chongqing"),
    ("Region17Hubei", "Region27Shaanxi"),
    ("Region18Hunan", "Region19Guangdong"),
    ("Region18Hunan", "Region20Guangxi"),
    ("Region18Hunan", "Region22Chongqing"),
    ("Region18Hunan", "Region24Guizhou"),
    ("Region19Guangdong", "Region20Guangxi"),
    ("Region19Guangdong", "Region21Hainan"),
    ("Region20Guangxi", "Region24Guizhou"),
    ("Region20Guangxi", "Region25Yunnan"),
    ("Region22Chongqing", "Region23Sichuan"),
    ("Region22Chongqing", "Region24Guizhou"),
    ("Region22Chongqing", "Region27Shaanxi"),
    ("Region23Sichuan", "Region24Guizhou"),
    ("Region23Sichuan", "Region25Yunnan"),
    ("Region23Sichuan", "Region26Tibet"),
    ("Region23Sichuan", "Region27Shaanxi"),
    ("Region23Sichuan", "Region28Gansu"),
    ("Region23Sichuan", "Region29Qinghai"),
    ("Region24Guizhou", "Region25Yunnan"),
    ("Region25Yunnan", "Region26Tibet"),
    ("Region26Tibet", "Region29Qinghai"),
    ("Region26Tibet", "Region31Xinjiang"),
    ("Region27Shaanxi", "Region28Gansu"),
    ("Region27Shaanxi", "Region30Ningxia"),
    ("Region28Gansu", "Region29Qinghai"),
    ("Region28Gansu", "Region30Ningxia"),
    ("Region28Gansu", "Region31Xinjiang"),
    ("Region29Qinghai", "Region31Xinjiang"),
}

DIRECTED_NEIGHBORS = NEIGHBOR_PAIRS | {(dst, src) for src, dst in NEIGHBOR_PAIRS}


def instance_pair(instance_id):
    match = REGION_PAIR_RE.search(instance_id)
    if not match:
        raise ValueError(f"Could not parse transport route id: {instance_id}")
    return match.group(1), match.group(2)


def filter_file(source_path, target_path):
    with open(source_path) as f:
        data = json.load(f)

    top_key = next(iter(data))
    instances = data[top_key]["instance_data"]
    filtered = [
        instance
        for instance in instances
        if instance_pair(instance["id"]) in DIRECTED_NEIGHBORS
    ]

    data[top_key]["instance_data"] = filtered

    with open(target_path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")

    return len(instances), len(filtered)


def main():
    TARGET_DIR.mkdir(parents=True, exist_ok=True)

    expected = len(DIRECTED_NEIGHBORS)
    for filename in TRANSPORT_FILES:
        source_path = SOURCE_DIR / filename
        target_path = TARGET_DIR / filename
        total, kept = filter_file(source_path, target_path)
        if kept != expected:
            raise RuntimeError(
                f"{filename}: expected {expected} neighboring routes, got {kept}"
            )
        print(f"{filename}: kept {kept} of {total} routes")

    print(f"Wrote neighboring road OSRM variant to {TARGET_DIR}")


if __name__ == "__main__":
    main()
