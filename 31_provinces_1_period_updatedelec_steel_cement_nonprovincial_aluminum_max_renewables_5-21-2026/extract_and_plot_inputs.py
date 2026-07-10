"""
Extract existing capacity, demand, and scrap supply from model inputs
and save as CSVs, then plot on a China province map using plot_province_pies.
"""

import json
import re
import os
import numpy as np
import pandas as pd
import geopandas as gpd
import matplotlib.pyplot as plt
from matplotlib.patches import Wedge, Circle

# ── Paths ────────────────────────────────────────────────────────────────────
BASE = os.path.dirname(os.path.abspath(__file__))
ASSETS = os.path.join(BASE, "assets", "assets_1")
SYSTEM = os.path.join(BASE, "system")
OUT = os.path.join(BASE, "plot_inputs")
os.makedirs(OUT, exist_ok=True)

NODES_FILE = os.path.join(SYSTEM, "nodes_mean_co2_injection.json")

# ── Unit conversion constants ────────────────────────────────────────────────
HOURS_PER_YEAR = 8760
MODEL_HOURS = 288          # total TDR hours modeled
TO_MT = 1e-6               # tonnes → million tonnes

# capacity:  t/hr  → MT/yr
CAP_CONV = HOURS_PER_YEAR * TO_MT

# demand:    aggregate over 288 model-hours, each representing HOURS_PER_YEAR/MODEL_HOURS
#            actual hours → multiply by 8760/288 to annualize, then convert to MT
DEMAND_CONV = (HOURS_PER_YEAR / MODEL_HOURS) * TO_MT

# scrap supply: t/hr → MT/yr
SCRAP_CONV = HOURS_PER_YEAR * TO_MT


# ── Helper: strip "Region{N}" prefix from region IDs ────────────────────────
def region_to_province(region_id):
    """'Region12Anhui' → 'Anhui'"""
    return re.sub(r"^Region\d+", "", region_id)


# ════════════════════════════════════════════════════════════════════════════
# 1. EXTRACT CAPACITY
# ════════════════════════════════════════════════════════════════════════════

def extract_capacity_from_edge(asset_file, edge_key):
    """Extract existing_capacity from edges[edge_key].existing_capacity per instance."""
    with open(asset_file) as f:
        data = json.load(f)
    top_key = list(data.keys())[0]
    entry = data[top_key]
    if isinstance(entry, list):
        entry = entry[0]
    instances = entry.get("instance_data", [])
    rows = []
    for inst in instances:
        region_id = inst.get("location") or re.sub(r"_\w+$", "", inst.get("id", ""))
        # try location first; fall back to stripping suffix from id
        if not region_id:
            continue
        province = region_to_province(region_id)
        cap = inst.get("edges", {}).get(edge_key, {}).get("existing_capacity", 0.0)
        rows.append({"province": province, "existing_capacity_mt_yr": cap * CAP_CONV})
    return pd.DataFrame(rows)


def extract_capacity_top_level(asset_file):
    """Extract existing_capacity from the top-level of each instance (e.g. AluminumSmelting)."""
    with open(asset_file) as f:
        data = json.load(f)
    top_key = list(data.keys())[0]
    entry = data[top_key][0]
    instances = entry.get("instance_data", [])
    rows = []
    for inst in instances:
        region_id = inst.get("location") or inst.get("id", "")
        province = region_to_province(region_id)
        cap = inst.get("existing_capacity", 0.0)
        rows.append({"province": province, "existing_capacity_mt_yr": cap * CAP_CONV})
    return pd.DataFrame(rows)


# BF-BOF steel
bfbof_cap = extract_capacity_from_edge(
    os.path.join(ASSETS, "steelmaking_bfbof.json"), "crudesteel_edge"
)
bfbof_cap.to_csv(os.path.join(OUT, "capacity_steel_bfbof.csv"), index=False)
print("Saved capacity_steel_bfbof.csv")

# EAF scrap steel
eaf_cap = extract_capacity_from_edge(
    os.path.join(ASSETS, "steelmaking_scrapeaf56_2retrofits_zerocost.json"), "crudesteel_edge"
)
eaf_cap.to_csv(os.path.join(OUT, "capacity_steel_eaf.csv"), index=False)
print("Saved capacity_steel_eaf.csv")

# Cement
cement_cap = extract_capacity_from_edge(
    os.path.join(ASSETS, "tradcement.json"), "cement_edge"
)
cement_cap.to_csv(os.path.join(OUT, "capacity_cement.csv"), index=False)
print("Saved capacity_cement.csv")

# Aluminum
aluminum_cap = extract_capacity_top_level(
    os.path.join(ASSETS, "aluminumsmelting.json")
)
aluminum_cap.to_csv(os.path.join(OUT, "capacity_aluminum.csv"), index=False)
print("Saved capacity_aluminum.csv")


# ════════════════════════════════════════════════════════════════════════════
# 2. EXTRACT DEMAND AND SCRAP SUPPLY FROM NODES JSON
# ════════════════════════════════════════════════════════════════════════════

with open(NODES_FILE) as f:
    nodes_data = json.load(f)

nodes = nodes_data["nodes"]

cement_demand_rows = []
steel_demand_rows = []
aluminum_demand_total = None
scrap_supply_rows = []

for node in nodes:
    ntype = node.get("type", "")
    instances = node.get("instance_data", [])

    if ntype == "Cement":
        for inst in instances:
            rhs = inst.get("rhs_policy", {}).get("AggregatedDemandConstraint")
            if rhs is not None:
                province = region_to_province(
                    re.sub(r"^cement_", "", inst["id"])
                )
                cement_demand_rows.append({
                    "province": province,
                    "annual_demand_mt_yr": rhs * DEMAND_CONV,
                })

    elif ntype == "CrudeSteel":
        for inst in instances:
            rhs = inst.get("rhs_policy", {}).get("AggregatedDemandConstraint")
            if rhs is not None:
                province = region_to_province(
                    re.sub(r"^crudesteel_", "", inst["id"])
                )
                steel_demand_rows.append({
                    "province": province,
                    "annual_demand_mt_yr": rhs * DEMAND_CONV,
                })

    elif ntype == "Aluminum":
        for inst in instances:
            rhs = inst.get("rhs_policy", {}).get("AggregatedDemandConstraint")
            if rhs is not None:
                aluminum_demand_total = rhs * DEMAND_CONV

    elif ntype == "SteelScrap":
        for inst in instances:
            max_sup = inst.get("max_supply")
            if max_sup is not None:
                val = max_sup[0] if isinstance(max_sup, list) else max_sup
                province = region_to_province(
                    re.sub(r"^steelscrap_source_", "", inst["id"])
                )
                scrap_supply_rows.append({
                    "province": province,
                    "annual_scrap_supply_mt_yr": val * SCRAP_CONV,
                })

cement_demand = pd.DataFrame(cement_demand_rows)
cement_demand.to_csv(os.path.join(OUT, "demand_cement.csv"), index=False)
print("Saved demand_cement.csv")

steel_demand = pd.DataFrame(steel_demand_rows)
steel_demand.to_csv(os.path.join(OUT, "demand_steel.csv"), index=False)
print("Saved demand_steel.csv")

# Aluminum demand is a single national total
aluminum_demand = pd.DataFrame([{
    "scope": "national",
    "annual_demand_mt_yr": aluminum_demand_total,
}])
aluminum_demand.to_csv(os.path.join(OUT, "demand_aluminum.csv"), index=False)
print(f"Saved demand_aluminum.csv  (national total: {aluminum_demand_total:.2f} MT/yr)")

scrap_supply = pd.DataFrame(scrap_supply_rows)
scrap_supply.to_csv(os.path.join(OUT, "scrap_supply_steel.csv"), index=False)
print("Saved scrap_supply_steel.csv")


# ════════════════════════════════════════════════════════════════════════════
# 3. PLOT ON MAP
# ════════════════════════════════════════════════════════════════════════════

def plot_province_pies(
    gdf,
    data_df,
    province_col="NAME_1",
    categories=None,
    colors=None,
    pie_scale=1.0,
    figsize=(14, 10),
    title="",
    legend_sizes=None,
    capacity_unit="MT/yr",
):
    if categories is None:
        categories = list(data_df.columns)

    if colors is None:
        cmap = plt.cm.tab20
        colors = {cat: cmap(i) for i, cat in enumerate(categories)}

    gdf_proj = gdf.to_crs(epsg=3857)
    gdf_proj = gdf_proj.merge(data_df, left_on=province_col, right_index=True, how="left")
    gdf_proj[categories] = gdf_proj[categories].fillna(0)

    gdf_proj["centroid"] = gdf_proj.geometry.centroid
    gdf_proj["cx"] = gdf_proj.centroid.x
    gdf_proj["cy"] = gdf_proj.centroid.y

    gdf_proj["total_value"] = gdf_proj[categories].sum(axis=1)
    max_total = gdf_proj["total_value"].max() or 1
    gdf_proj["radius"] = (gdf_proj["total_value"] / max_total) * pie_scale * 80_000

    fig, ax = plt.subplots(figsize=figsize)
    ax.set_axis_off()

    for _, row in gdf_proj.iterrows():
        cx, cy, r = row["cx"], row["cy"], row["radius"]
        vals = row[categories].values.astype(float)
        total = vals.sum()
        if total == 0:
            continue
        angles = np.cumsum(vals) / total * 360
        prev_angle = 0
        for cat, angle in zip(categories, angles):
            wedge = Wedge(
                center=(cx, cy), r=r,
                theta1=prev_angle, theta2=angle,
                facecolor=colors[cat], edgecolor="white", linewidth=0.3,
            )
            ax.add_patch(wedge)
            prev_angle = angle

    gdf_proj.plot(ax=ax, facecolor="lightgrey", edgecolor="white", linewidth=0.5)

    # Legend: categories
    legend_patches = [
        plt.matplotlib.patches.Patch(facecolor=colors[c], label=c)
        for c in categories
    ]
    ax.legend(handles=legend_patches, loc="lower left", fontsize=8,
              title="Technology", framealpha=0.8)

    # Legend: sizes
    if legend_sizes:
        legend_x = gdf_proj["cx"].max() * 1.01
        legend_y_start = gdf_proj["cy"].quantile(0.3)
        for i, size in enumerate(legend_sizes):
            r_legend = (size / max_total) * pie_scale * 80_000
            circle = Circle(
                (legend_x, legend_y_start - i * r_legend * 2.5),
                radius=r_legend,
                facecolor="grey", edgecolor="black", linewidth=0.5, alpha=0.5,
            )
            ax.add_patch(circle)
            ax.text(
                legend_x + r_legend * 1.2,
                legend_y_start - i * r_legend * 2.5,
                f"{size:,.0f} {capacity_unit}",
                va="center", fontsize=7,
            )

    ax.set_title(title, fontsize=14)
    ax.autoscale()
    return fig, ax


# Load GeoDataFrame
shapefile = os.path.join(BASE, "gadm36_CHN_1.json")
if not os.path.exists(shapefile):
    shapefile = os.path.join(BASE, "..", "gadm36_CHN_1.json")
gdf = gpd.read_file(shapefile)
rename_map = {
    "Nei Mongol": "Innermongolia",
    "Xizang": "Tibet",
    "Ningxia Hui": "Ningxia",
    "Xinjiang Uygur": "Xinjiang",
}
gdf["NAME_1"] = gdf["NAME_1"].replace(rename_map)

# ── Color maps ───────────────────────────────────────────────────────────────
STEEL_COLORS = {
    "BF-BOF":    "#1f77b4",
    "Scrap EAF": "#38a938",
}
CEMENT_COLORS = {"Traditional Cement": "#e15759"}
ALUMINUM_COLORS = {"Aluminum Smelting": "#ff7f0e"}
SCRAP_COLORS = {"Scrap Supply": "#9467bd"}
DEMAND_STEEL_COLORS = {"Steel Demand": "#1f77b4"}
DEMAND_CEMENT_COLORS = {"Cement Demand": "#e15759"}


def make_map_df(df, province_col, value_col, display_name):
    """Pivot a two-column DataFrame into a map-ready DataFrame indexed by province."""
    out = df.rename(columns={province_col: "province", value_col: display_name})
    return out.set_index("province")[[display_name]]


# ── Plot 1: Steel existing capacity (BF-BOF + EAF) ──────────────────────────
steel_cap_df = pd.merge(
    bfbof_cap.rename(columns={"existing_capacity_mt_yr": "BF-BOF"}),
    eaf_cap.rename(columns={"existing_capacity_mt_yr": "Scrap EAF"}),
    on="province", how="outer",
).fillna(0).set_index("province")

fig, ax = plot_province_pies(
    gdf, steel_cap_df,
    categories=["BF-BOF", "Scrap EAF"],
    colors=STEEL_COLORS,
    pie_scale=2.5,
    title="Existing Steel Capacity (MT/yr)",
    legend_sizes=[5, 20, 50],
    capacity_unit="MT/yr",
)
fig.savefig(os.path.join(OUT, "map_capacity_steel.png"), dpi=150, bbox_inches="tight")
plt.close(fig)
print("Saved map_capacity_steel.png")

# ── Plot 2: Cement existing capacity ────────────────────────────────────────
cement_cap_df = cement_cap.rename(
    columns={"existing_capacity_mt_yr": "Traditional Cement"}
).set_index("province")

fig, ax = plot_province_pies(
    gdf, cement_cap_df,
    categories=["Traditional Cement"],
    colors=CEMENT_COLORS,
    pie_scale=2.5,
    title="Existing Cement Capacity (MT/yr)",
    legend_sizes=[5, 20, 50],
    capacity_unit="MT/yr",
)
fig.savefig(os.path.join(OUT, "map_capacity_cement.png"), dpi=150, bbox_inches="tight")
plt.close(fig)
print("Saved map_capacity_cement.png")

# ── Plot 3: Aluminum existing capacity ──────────────────────────────────────
aluminum_cap_df = aluminum_cap.rename(
    columns={"existing_capacity_mt_yr": "Aluminum Smelting"}
).set_index("province")

fig, ax = plot_province_pies(
    gdf, aluminum_cap_df,
    categories=["Aluminum Smelting"],
    colors=ALUMINUM_COLORS,
    pie_scale=2.5,
    title="Existing Aluminum Capacity (MT/yr)",
    legend_sizes=[1, 3, 5],
    capacity_unit="MT/yr",
)
fig.savefig(os.path.join(OUT, "map_capacity_aluminum.png"), dpi=150, bbox_inches="tight")
plt.close(fig)
print("Saved map_capacity_aluminum.png")

# ── Plot 4: Steel demand by province ─────────────────────────────────────────
steel_demand_df = steel_demand.rename(
    columns={"annual_demand_mt_yr": "Steel Demand"}
).set_index("province")

fig, ax = plot_province_pies(
    gdf, steel_demand_df,
    categories=["Steel Demand"],
    colors=DEMAND_STEEL_COLORS,
    pie_scale=2.5,
    title="Annual Steel Demand (MT/yr)",
    legend_sizes=[5, 20, 50],
    capacity_unit="MT/yr",
)
fig.savefig(os.path.join(OUT, "map_demand_steel.png"), dpi=150, bbox_inches="tight")
plt.close(fig)
print("Saved map_demand_steel.png")

# ── Plot 5: Cement demand by province ────────────────────────────────────────
cement_demand_df = cement_demand.rename(
    columns={"annual_demand_mt_yr": "Cement Demand"}
).set_index("province")

fig, ax = plot_province_pies(
    gdf, cement_demand_df,
    categories=["Cement Demand"],
    colors=DEMAND_CEMENT_COLORS,
    pie_scale=2.5,
    title="Annual Cement Demand (MT/yr)",
    legend_sizes=[5, 20, 50],
    capacity_unit="MT/yr",
)
fig.savefig(os.path.join(OUT, "map_demand_cement.png"), dpi=150, bbox_inches="tight")
plt.close(fig)
print("Saved map_demand_cement.png")

# ── Plot 6: Steel scrap supply by province ───────────────────────────────────
scrap_supply_df = scrap_supply.rename(
    columns={"annual_scrap_supply_mt_yr": "Scrap Supply"}
).set_index("province")

fig, ax = plot_province_pies(
    gdf, scrap_supply_df,
    categories=["Scrap Supply"],
    colors=SCRAP_COLORS,
    pie_scale=2.5,
    title="Annual Steel Scrap Supply (MT/yr)",
    legend_sizes=[2, 10, 20],
    capacity_unit="MT/yr",
)
fig.savefig(os.path.join(OUT, "map_scrap_supply_steel.png"), dpi=150, bbox_inches="tight")
plt.close(fig)
print("Saved map_scrap_supply_steel.png")

print("\nDone. All CSVs and maps saved to:", OUT)
