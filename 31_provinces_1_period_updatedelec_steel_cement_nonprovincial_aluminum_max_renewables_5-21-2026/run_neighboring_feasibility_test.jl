"""
Feasibility test for the road_osrm_neighboring transport variant.

Loads the case with neighboring-only transport (assets/assets_neighboring),
builds the model, and solves it. Reports whether the model is feasible and,
if not, computes the IIS and writes conflicting constraints to
neighboring_conflicts.txt.

Usage:
    julia run_neighboring_feasibility_test.jl
"""

using Pkg
Pkg.activate("/Users/lillianwang/Documents/MacroEnergy.jl")

using MacroEnergy
using Gurobi
using JuMP

case_dir   = @__DIR__
data_file  = joinpath(case_dir, "system_data_neighboring.json")

@info "Loading case with road_osrm_neighboring transport variant..."
case = MacroEnergy.load_case(data_file)

optim = MacroEnergy.create_optimizer(
    Gurobi.Optimizer, nothing,
    ("Method" => 2, "Crossover" => 0, "BarConvTol" => 1e-3),
)

@info "Generating model..."
model = MacroEnergy.generate_model(case, optim)

@info "Solving..."
MacroEnergy.optimize!(model)

status = JuMP.termination_status(model)
@info "Termination status: $status"

if status == MOI.OPTIMAL || status == MOI.LOCALLY_SOLVED
    obj = JuMP.objective_value(model)
    @info "FEASIBLE — objective value: $obj"
    out_dir = joinpath(case_dir, "results_neighboring_test")
    mkpath(out_dir)
    MacroEnergy.postprocess!(case, model)
    MacroEnergy.write_outputs(out_dir, case, model)
    @info "Results written to $out_dir"

elseif status == MOI.INFEASIBLE || status == MOI.LOCALLY_INFEASIBLE
    @warn "Model is INFEASIBLE with neighboring-only transport."
    @info "Computing IIS (irreducible infeasible subsystem)..."
    MacroEnergy.compute_conflict!(model)

    conflicting = JuMP.ConstraintRef[]
    for (F, S) in JuMP.list_of_constraint_types(model)
        for con in JuMP.all_constraints(model, F, S)
            if JuMP.get_attribute(con, MOI.ConstraintConflictStatus()) == MOI.IN_CONFLICT
                push!(conflicting, con)
            end
        end
    end

    # Deduplicate by constraint pattern (strip index numbers)
    seen = Set{String}()
    unique_conflicts = String[]
    for con in conflicting
        line = string(con)
        pattern = replace(line, r"\[\d+\]" => "[]")
        if !(pattern in seen)
            push!(seen, pattern)
            push!(unique_conflicts, line)
        end
    end

    out_file = joinpath(case_dir, "neighboring_conflicts.txt")
    open(out_file, "w") do io
        for item in unique_conflicts
            println(io, item)
        end
    end
    @warn "$(length(conflicting)) conflicting constraints ($(length(unique_conflicts)) unique patterns) written to neighboring_conflicts.txt"

else
    @warn "Solver returned status: $status — check solver logs."
end
