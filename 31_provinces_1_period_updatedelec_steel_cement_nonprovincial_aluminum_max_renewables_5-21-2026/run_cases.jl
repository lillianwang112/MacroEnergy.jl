using Pkg
Pkg.activate("/Users/lillianwang/Documents/MacroEnergy.jl")

using MacroEnergy
using Gurobi
using JuMP
using JSON3

output_base = joinpath(@__DIR__, "results")

# ── Scenario configuration ────────────────────────────────────────────────────

# Nodes files to sweep over (name => path relative to system/)
nodes_scenarios = [
    "min_co2_injection"  => "system/nodes_min_co2_injection.json",
    "mean_co2_injection" => "system/nodes_mean_co2_injection.json",
    "max_co2_injection"  => "system/nodes_max_co2_injection.json",
]

# Emission cap cases: (output folder name, fraction of baseline CO2 allowed)
# The uncapped case is always run first to establish the baseline.
emission_cases = [
    "30pct" => 0.70,
    "60pct" => 0.40,
    "80pct" => 0.20,
]

# ── Optimizer (shared across all runs) ───────────────────────────────────────
optim = MacroEnergy.create_optimizer(Gurobi.Optimizer, nothing, ("Method" => 2, "Crossover" => 0, "BarConvTol" => 1e-3))

# ── Main loop ─────────────────────────────────────────────────────────────────
system_data_path = joinpath(@__DIR__, "system_data.json")
original_system_data = read(system_data_path, String)

for (nodes_name, nodes_path) in nodes_scenarios
    @info "=== Nodes scenario: $nodes_name ==="

    # Patch system_data.json with this scenario's nodes file
    sys = JSON3.read(original_system_data, Dict)
    sys["case"][1]["nodes"]["path"] = nodes_path
    write(system_data_path, JSON3.write(sys))

    # ── Uncapped case (establishes baseline CO2) ──────────────────────────────
    case = MacroEnergy.load_case(@__DIR__)
    MacroEnergy.find_node(case.systems[1], :co2_sink).rhs_policy[MacroEnergy.CO2CapConstraint] = 1e15

    (case, model) = MacroEnergy.solve_case(case, optim)
    MacroEnergy.postprocess!(case, model)

    out_dir = joinpath(output_base, nodes_name, "noemissionscap")
    mkpath(out_dir)
    MacroEnergy.write_outputs(out_dir, case, model)

    co2_node = MacroEnergy.find_node(case.systems[1], :co2_sink)
    baseline_co2 = sum(
        MacroEnergy.subperiod_weight(co2_node, MacroEnergy.current_subperiod(co2_node, t)) *
        JuMP.value(MacroEnergy.get_balance(co2_node, :emissions, t))
        for t in MacroEnergy.time_interval(co2_node)
    )
    @info "[$nodes_name] Baseline CO2 (no cap): $baseline_co2"

    # ── Emission cap cases ────────────────────────────────────────────────────
    for (case_name, fraction) in emission_cases
        case = MacroEnergy.load_case(@__DIR__)

        node = MacroEnergy.find_node(case.systems[1], :co2_sink)
        node.rhs_policy[MacroEnergy.CO2CapConstraint] = baseline_co2 * fraction

        (case, model) = MacroEnergy.solve_case(case, optim)
        MacroEnergy.postprocess!(case, model)

        out_dir = joinpath(output_base, nodes_name, case_name)
        mkpath(out_dir)
        MacroEnergy.write_outputs(out_dir, case, model)
    end
end

# Restore original system_data.json
write(system_data_path, original_system_data)
