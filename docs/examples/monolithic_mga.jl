using MacroEnergy

case_path = length(ARGS) == 1 ? abspath(ARGS[1]) : error(
    "Usage: julia --project=. docs/examples/monolithic_mga.jl PATH_TO_CASE",
)

# Set "SolutionAlgorithm": "Monolithic" in settings/case_settings.json and
# "EnableJuMPStringNames": true in settings/macro_settings.json.
# Patterns are matched against JuMP variable names. Adapt the asset-name
# fragments below to the IDs used by your case.
groups = [
    MGAGroupSpec("solar", r"^vCAP_.*solar.*_edge_"),
    MGAGroupSpec("onshore wind", r"^vCAP_.*onshore_wind.*_edge_"),
    MGAGroupSpec("natural gas", r"^vCAP_.*natural_gas.*_edge_"),
    MGAGroupSpec("battery power", r"^vCAP_.*battery.*_discharge_edge_"),
    MGAGroupSpec("transmission", r"^vCAP_.*(?:_to_|transmission).*_edge_"),
]

case, model, mga = run_case(
    case_path;
    run_mga=true,
    mga_groups=groups,
    mga_slacks=[0.01, 0.05, 0.10],
    mga_method=:one_at_a_time,
    mga_output_writer=write_mga_capacity_outputs,
)

println("Baseline objective: ", mga.baseline_objective)
println("MGA tables and capacity solutions: ", mga.output_path)
