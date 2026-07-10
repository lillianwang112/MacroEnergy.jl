"""
generate_transport_emissions.py

Generates TransportEmissions JSON files for CrudeSteel and DRI using:
  - Routes from the existing Transmission transport JSONs (road_osrm variant)
  - Road distances from the cached OSRM distance matrix (km)
  - Emission factor: 0.000078 t CO2 / (t · km)
    Source: GB/T 51366-2019 Table E.0.1, heavy diesel truck 30t capacity

Usage:
    python generate_transport_emissions.py          # dry-run: print summary
    python generate_transport_emissions.py --write  # write JSON files
"""

import argparse
import csv
import json
from pathlib import Path

BASE = Path(__file__).parent
VARIANT_ROAD = BASE / "assets" / "transport_variants" / "road_osrm"
DISTANCE_MATRIX = BASE / "plot_inputs" / "transport_distance_matrix.csv"

# GB/T 51366-2019 Appendix E, Table E.0.1: heavy diesel truck 30t capacity
# Units: t CO2 / (t · km)  [= 0.078 kg CO2/t-km / 1000]
EMISSION_FACTOR = 0.000078

COMMODITIES = {
    "crudesteel": {
        "source_file": "crudesteel_transport.json",
        "output_file": "crudesteel_transport_emissions.json",
        "commodity": "CrudeSteel",
        "vertex_prefix": "crudesteel",
        "top_key": "CrudeSteelTransportEmissions",
        "id_prefix": "crudesteel_transport_emissions",
    },
    "dri": {
        "source_file": "dri_transport.json",
        "output_file": "dri_transport_emissions.json",
        "commodity": "DRI",
        "vertex_prefix": "dri",
        "top_key": "DRITransportEmissions",
        "id_prefix": "dri_transport_emissions",
    },
}


def load_distance_matrix(path):
    distances = {}
    with open(path) as f:
        reader = csv.reader(f)
        header = next(reader)
        regions = header[1:]  # skip blank first col
        for row in reader:
            origin = row[0]
            for dest, val in zip(regions, row[1:]):
                if val:
                    distances[(origin, dest)] = float(val)
    return distances


def extract_routes(source_json):
    """Return list of (origin_region, dest_region) from existing Transmission file."""
    data = json.loads(source_json.read_text())
    key = list(data.keys())[0]
    routes = []
    for inst in data[key]["instance_data"]:
        edge = list(inst["edges"].values())[0]
        start = edge["start_vertex"]
        end = edge["end_vertex"]
        # vertex names are like "crudesteel_Region1Beijing" — extract "Region..." part
        origin_region = start[start.index("Region"):]
        dest_region = end[end.index("Region"):]
        routes.append((origin_region, dest_region))
    return routes


def build_transport_emissions_json(cfg, distances):
    commodity = cfg["commodity"]
    vertex_prefix = cfg["vertex_prefix"]
    id_prefix = cfg["id_prefix"]
    top_key = cfg["top_key"]

    source_path = VARIANT_ROAD / cfg["source_file"]
    routes = extract_routes(source_path)

    instances = []
    missing = []
    for origin_region, dest_region in routes:
        key = (origin_region, dest_region)
        dist = distances.get(key)
        if dist is None:
            missing.append(key)
            continue

        instances.append({
            "id": f"{id_prefix}_{origin_region}_to_{dest_region}",
            "transforms": {
                "distance": round(dist, 4),
            },
            "edges": {
                "origin_edge": {
                    "start_vertex": f"{vertex_prefix}_{origin_region}",
                },
                "destination_edge": {
                    "end_vertex": f"{vertex_prefix}_{dest_region}",
                },
            },
        })

    if missing:
        print(f"  WARNING: {len(missing)} routes missing from distance matrix: {missing[:5]}...")

    output = {
        top_key: [
            {
                "type": "TransportEmissions",
                "global_data": {
                    "transforms": {
                        "emission_factor": EMISSION_FACTOR,
                        "constraints": {
                            "BalanceConstraint": True,
                        },
                    },
                    "edges": {
                        "origin_edge": {
                            "commodity": commodity,
                            "has_capacity": False,
                        },
                        "destination_edge": {
                            "commodity": commodity,
                            "has_capacity": False,
                        },
                        "co2_edge": {
                            "commodity": "CO2",
                            "has_capacity": False,
                            "end_vertex": "co2_sink",
                        },
                    },
                },
                "instance_data": instances,
            }
        ]
    }

    return output, len(instances), len(missing)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--write", action="store_true", help="Write output files")
    args = parser.parse_args()

    print(f"Loading distance matrix from {DISTANCE_MATRIX}")
    distances = load_distance_matrix(DISTANCE_MATRIX)
    print(f"  {len(distances)} origin-destination pairs loaded")

    for name, cfg in COMMODITIES.items():
        print(f"\nGenerating {name} transport emissions...")
        output, n_instances, n_missing = build_transport_emissions_json(cfg, distances)
        print(f"  {n_instances} instances generated, {n_missing} missing distances")

        # Print a sample instance
        sample = output[cfg["top_key"]][0]["instance_data"][0]
        print(f"  Sample: {sample['id']}, distance={sample['transforms']['distance']} km")
        emission_rate = sample["transforms"]["distance"] * EMISSION_FACTOR
        print(f"  -> emission_rate = {emission_rate:.6f} t CO2/t commodity")

        if args.write:
            out_path = VARIANT_ROAD / cfg["output_file"]
            out_path.write_text(json.dumps(output, indent=2))
            print(f"  Written: {out_path}")
        else:
            print(f"  (dry run — use --write to save to {VARIANT_ROAD / cfg['output_file']})")


if __name__ == "__main__":
    main()
