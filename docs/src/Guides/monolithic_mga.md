# Monolithic Modeling to Generate Alternatives

Modeling to Generate Alternatives (MGA) searches for solutions that are
different from a least-cost solution while remaining within a user-selected
cost increase. MacroEnergy uses the baseline objective value \(z^*\) and
enforces

\[
f(x) \le z^* + \epsilon |z^*|,
\]

where \(\epsilon\) is a fractional cost slack.

## Run a one-at-a-time sweep

Set `"SolutionAlgorithm": "Monolithic"` in
`settings/case_settings.json` and `"EnableJuMPStringNames": true` in
`settings/macro_settings.json`, then define explicit groups using patterns
that match JuMP variable names:

```julia
using MacroEnergy
using Gurobi

groups = [
    MGAGroupSpec("solar", r"^vCAP_.*solar.*_edge_"),
    MGAGroupSpec("onshore wind", r"^vCAP_.*onshore_wind.*_edge_"),
    MGAGroupSpec("natural gas", r"^vCAP_.*natural_gas.*_edge_"),
    MGAGroupSpec("battery power", r"^vCAP_.*battery.*_discharge_edge_"),
    MGAGroupSpec("transmission", r"^vCAP_.*(?:_to_|transmission).*_edge_"),
]

case, model, mga = run_case(
    case_path;
    optimizer=Gurobi.Optimizer,
    optimizer_attributes=("Method" => 2, "Crossover" => 0),
    run_mga=true,
    mga_groups=groups,
    mga_slacks=[0.01, 0.05, 0.10],
    mga_method=:one_at_a_time,
    mga_output_writer=write_mga_capacity_outputs,
)
```

Each group is minimized and maximized at every slack. Groups may overlap, so
you can define `"all wind"` together with separate onshore and offshore wind
groups. A group that matches no variables raises an error before the MGA
sweep begins.

The baseline model is built and solved once. The cost constraint and objective
are then updated in place for each alternative. MacroEnergy restores and
re-solves the original objective after the sweep.

## Outputs

MGA outputs are written under the baseline result directory:

```text
results_NNN/
└── mga/
    ├── mga_metadata.json
    ├── mga_group_definitions.csv
    ├── mga_directions.csv
    ├── mga_summary.csv
    ├── mga_group_values.csv
    └── slack_0.0100/
        ├── 001_solar_min/
        └── 002_solar_max/
```

`mga_summary.csv` records solver status, the true system cost, the permitted
cost budget, and output status for every alternative.
`mga_group_values.csv` records every named group for every alternative and is
the recommended input for envelope and correlation plots.

Set `mga_write_detailed_results=false` when only these compact tables are
needed. Use `mga_output_writer=write_mga_capacity_outputs` when the analysis
needs regional capacity results but not large operational time-series files.

A complete runnable script is available at
`docs/examples/monolithic_mga.jl`.

## Random directions

Use `mga_method=:random`, `mga_iterations=N`, and `mga_random_seed=...` for
signed random directions. If groups use different physical units, choose
`MGAGroupSpec(...; coefficient=...)` values that normalize them before mixing
them in a random objective. One-at-a-time sweeps do not require cross-group
normalization.
