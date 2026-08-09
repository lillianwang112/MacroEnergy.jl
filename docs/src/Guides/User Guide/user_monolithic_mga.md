# GenX-equivalent monolithic MGA

Modeling to Generate Alternatives (MGA) searches for different solutions near
the least-cost solution. For baseline cost $z^*$ and cost slack $\epsilon$,
MacroEnergy requires

$$
f(x) \le z^* + \epsilon |z^*|.
$$

It then replaces the cost objective with a capacity or annual-generation
objective while keeping the original model constraints.

## Requirements

The case settings must use:

```json
"SolutionAlgorithm": "Monolithic",
"ExpansionHorizon": "PerfectForesight"
```

Two measures are available:

- `measure=:capacity`
- `measure=:annual_generation`

## Define resource groups

GenX defines MGA eligibility in its resource tables. MacroEnergy instead uses
`GenXMGAResourceSpec` to map model assets into technology groups:

```julia
resources = [
    GenXMGAResourceSpec(
        "solar",
        :Electricity;
        asset_types=["VRE"],
        asset_pattern=r"solar",
        location_pattern=r"(Region\d+[A-Za-z]+)",
        capacity_unit="MW",
        activity_unit="MWh",
    ),
    GenXMGAResourceSpec(
        "onshore wind",
        :Electricity;
        asset_types=["VRE"],
        asset_pattern=r"onshore_wind",
        location_pattern=r"(Region\d+[A-Za-z]+)",
        capacity_unit="MW",
        activity_unit="MWh",
    ),
]
```

Each specification gives the reported technology name and output commodity.
The optional asset type and regular-expression fields narrow the eligible
assets. The first capture group in `location_pattern` is used as the location
label. If the pattern is omitted, MacroEnergy uses the asset location or the
receiving node ID.

The builder reports an error when a specification matches no output edges. The
resolved variables and their technology, location, commodity, and period are
written to `mga_group_definitions.csv`.

## Run MGA

Load and solve the case before calling MGA:

```julia
using MacroEnergy
using Gurobi

case_path = "/path/to/case"
case = load_case(case_path)

optimizer = MacroEnergy.create_optimizer(
    Gurobi.Optimizer,
    nothing,
    ("Method" => 1,),
)
case, model = solve_case(case, optimizer)

mga = run_genx_mga(
    model,
    case,
    joinpath(case_path, "mga_results");
    resources=resources,
    measure=:capacity,
    slacks=[0.01, 0.05, 0.10],
    iterations=10,
    random_seed=42,
)
```

Capacity MGA sums the available capacity for each technology, location, and
investment period. Available capacity is the stock usable in that period, not
necessarily capacity built during that period.

For annual-generation MGA, change the measure:

```julia
measure=:annual_generation
```

Annual generation is the representative-time-weighted output flow for each
technology, location, and investment period. MacroEnergy uses the case's
subperiod occurrence weights.

## Search behavior

Each iteration draws one positive random coefficient for every
technology-location-period quantity. The same coefficient vector is first
maximized and then minimized. Therefore, `iterations=N` attempts `2N`
alternatives for each cost slack. Set `random_seed` to reproduce the directions.

The model is reused across solves. When the run finishes, MacroEnergy removes
the MGA budget, restores the original cost objective, and re-solves it.

## Outputs

Results are written under the `mga/` directory inside the requested output
path:

```text
mga/
├── mga_metadata.json
├── mga_group_definitions.csv
├── mga_directions.csv
├── mga_summary.csv
├── mga_group_values.csv
└── slack_001_0.0100/
    ├── 001_random_01_max/
    └── 002_random_01_min/
```

- `mga_metadata.json` records the baseline, slacks, seed, and tolerances.
- `mga_group_definitions.csv` records the variables in each quantity.
- `mga_directions.csv` records the random coefficient vectors.
- `mga_summary.csv` records solve status, system cost, and budget checks.
- `mga_group_values.csv` records each quantity in every accepted solution.

Use `write_detailed_results=false` to write only the audit tables. For compact
capacity results, use `detailed_output_writer=write_mga_capacity_outputs`.

MacroEnergy accepts `OPTIMAL` and `ALMOST_OPTIMAL` solutions with finite values
that pass an independent check against the original cost budget.
