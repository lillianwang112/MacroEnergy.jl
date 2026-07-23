using Random

"""
    run_monolithic_mga(model, case, results_base_path, mga_variables; kwargs...)

MGA using the GenX vMGA aggregation approach (Berntsen & Trutnevyte 2017 / DeCarolis 2011).

Creates intermediate vMGA[k] variables that aggregate compatible capacity variables by
technology, physical zone or transmission corridor, component role, and investment period.
The component role prevents unlike units (for example storage MW and MWh) from being added,
and the period key prevents capacities from different investment periods from collapsing.

Each iteration runs both a Max AND a Min solve with the same random weight vector,
producing two alternative portfolios per iteration (matching GenX's approach).

# Arguments
- `model`: Solved JuMP monolithic model (returned by solve_case).
- `case`: MacroEnergy Case object (used for write_outputs and asset iteration).
- `results_base_path`: Base path where the optimal results were written.
- `mga_variables`: Optional explicit model-variable names. When empty, MGA uses the
  dimensionally separated capacity aggregation described above.

# Keyword Arguments
- `mga_slack::Float64=0.1`: Budget slack fraction above optimal (e.g. 0.1 = 10%).
- `mga_iterations::Int=100`: Number of MGA iterations (each produces 2 solves: Max + Min).
- `mga_method::Int=1`: Monolithic GenX-style uniform random weights. Other methods
  are rejected until they have an explicit monolithic implementation.
- `mga_combo_ratio::Float64=0.25`: Reserved for future monolithic vector methods.
- `mga_seed::Int=42`: Random seed for reproducibility.

# Returns
- `(results, weights, group_labels)`: Vector of per-solve outcomes, the reproducible
  direction matrix, and the scientific label for each vMGA group.
"""
function run_monolithic_mga(
    model::Model,
    case,
    results_base_path::AbstractString,
    mga_variables::Vector{String}=String[];
    mga_slack::Float64=0.1,
    mga_iterations::Int=100,
    mga_method::Int=1,
    mga_combo_ratio::Float64=0.25,
    mga_seed::Int=42,
)
    is_solved_and_feasible(model) || throw(ArgumentError("Monolithic MGA requires a solved, feasible base model"))
    mga_slack >= 0 || throw(ArgumentError("mga_slack must be nonnegative"))
    mga_iterations > 0 || throw(ArgumentError("mga_iterations must be positive"))
    Least_System_Cost = objective_value(model)
    mga_budget = Least_System_Cost + mga_slack * abs(Least_System_Cost)
    @info("MGA: z* = $Least_System_Cost, budget = $mga_budget ($(mga_slack*100)% slack), $mga_iterations iterations ($(mga_iterations*2) total solves)")

    mga_method == 1 || throw(ArgumentError(
        "Monolithic MGA currently supports only mga_method=1 (GenX-style uniform weights)",
    ))
    mga_combo_ratio == 0.25 || @warn(
        "mga_combo_ratio has no effect for monolithic mga_method=1",
    )

    # Budget constraint — same structure as GenX: eObj <= z* * (1 + slack)
    original_objective = objective_function(model)
    original_sense = objective_sense(model)
    if haskey(model.obj_dict, :cMGABudget)
        old_budget = model[:cMGABudget]
        is_valid(model, old_budget) && delete(model, old_budget)
        unregister(model, :cMGABudget)
    end
    @constraint(model, cMGABudget, objective_function(model) <= mga_budget)

    mga_output = try
        # Gurobi self-dual embedding improves numerical handling without sending
        # Gurobi-only options to other optimizers.
        if occursin("Gurobi", solver_name(model))
            set_optimizer_attribute(model, "BarHomogeneous", 1)
            set_optimizer_attribute(model, "NumericFocus", 3)
        end

    # Build the safe default aggregation, or honor an explicit raw-variable selection.
    group_labels, vMGA_vars = if isempty(mga_variables)
        _mga_setup!(model, case)
    else
        length(unique(mga_variables)) == length(mga_variables) ||
            throw(ArgumentError("Monolithic MGA variable names must be unique"))
        unsafe = filter(name -> name == "vREF" || startswith(name, "vTHETA"), mga_variables)
        isempty(unsafe) || throw(ArgumentError(
            "Monolithic MGA variables include cost/reference auxiliaries: $(join(unsafe, ", "))",
        ))
        refs = [variable_by_name(model, variable_name) for variable_name in mga_variables]
        missing = mga_variables[isnothing.(refs)]
        isempty(missing) || throw(ArgumentError(
            "Monolithic MGA variables not found in the model: $(join(missing, ", ")). " *
            "Explicit selection requires EnableJuMPStringNames=true.",
        ))
        @warn("Monolithic MGA is using explicitly selected raw variables; dimensional compatibility is the caller's responsibility")
        copy(mga_variables), VariableRef[ref for ref in refs]
    end
    n_pairs = length(group_labels)
    if n_pairs == 0
        throw(ArgumentError("MGA setup found no capacity variables to diversify"))
    end
    @info("MGA: $(n_pairs) diversity variables/groups selected")

    # Output directories (matching GenX naming convention)
    outpath_max = joinpath(results_base_path, "mga", "MGAResults_max")
    outpath_min = joinpath(results_base_path, "mga", "MGAResults_min")
    mkpath(outpath_max)
    mkpath(outpath_min)

    mga_start_time = time()
    weights = rand(MersenneTwister(mga_seed), n_pairs, mga_iterations)

    # Write the scientific definition of the run before the first solve so a
    # timeout still leaves the exact groups and directions used.
    _write_mga_metadata(results_base_path, group_labels, weights, mga_slack, mga_budget, mga_iterations)

    results = Vector{NamedTuple}(undef, mga_iterations * 2)

    println("Starting MGA iterations")
    for i in 1:mga_iterations

        # Random coefficients uniform [0,1] per (TechType × Zone) group — matches GenX's
        # pRand = rand(length(TechTypes), length(zones))
        pRand = view(weights, :, i)

        ### Maximization objective (GenX solves Max first)
        @objective(model, Max, sum(pRand[k] * vMGA_vars[k] for k in 1:n_pairs))
        optimize!(model)

        mgaoutpath_max = joinpath(outpath_max, string("MGA_", mga_slack, "_", i))
        max_status = termination_status(model)
        max_objective = has_values(model) ? objective_value(model) : NaN
        if is_solved_and_feasible(model)
            postprocess!(case, model)
            write_outputs(mgaoutpath_max, case, model)
            results[2i-1] = (iteration=i, direction=:max, feasible=true, status=max_status, objective=max_objective)
            @info("MGA: iteration $i Max feasible → $mgaoutpath_max")
        else
            @warn("MGA: iteration $i Max $max_status, skipping output")
            results[2i-1] = (iteration=i, direction=:max, feasible=false, status=max_status, objective=max_objective)
        end
        _write_mga_solve_summary(outpath_max, results[2i-1])

        ### Minimization objective (same pRand — explores opposite direction)
        @objective(model, Min, sum(pRand[k] * vMGA_vars[k] for k in 1:n_pairs))
        optimize!(model)

        mgaoutpath_min = joinpath(outpath_min, string("MGA_", mga_slack, "_", i))
        min_status = termination_status(model)
        min_objective = has_values(model) ? objective_value(model) : NaN
        if is_solved_and_feasible(model)
            postprocess!(case, model)
            write_outputs(mgaoutpath_min, case, model)
            results[2i] = (iteration=i, direction=:min, feasible=true, status=min_status, objective=min_objective)
            @info("MGA: iteration $i Min feasible → $mgaoutpath_min")
        else
            @warn("MGA: iteration $i Min $min_status, skipping output")
            results[2i] = (iteration=i, direction=:min, feasible=false, status=min_status, objective=min_objective)
        end
        _write_mga_solve_summary(outpath_min, results[2i])
    end

    total_time = time() - mga_start_time
    @info("MGA: completed $(mga_iterations) iterations ($(mga_iterations*2) solves) in $(round(total_time/60, digits=1)) minutes")

        (results, weights, group_labels)
    finally
        set_objective_sense(model, original_sense)
        set_objective_function(model, original_objective)
        if haskey(model.obj_dict, :cMGABudget)
            budget_constraint = model[:cMGABudget]
            is_valid(model, budget_constraint) && delete(model, budget_constraint)
            unregister(model, :cMGABudget)
        end
    end

    @info("Restoring the monolithic model to its least-cost objective")
    optimize!(model)
    is_solved_and_feasible(model) || error(
        "Monolithic model failed to solve after restoring its least-cost objective: $(termination_status(model))",
    )
    postprocess!(case, model)
    return mga_output
end

"""
    _mga_setup!(model, case) -> (group_labels, vMGA_vars)

MacroEnergy equivalent of GenX's `mga!()` function.

Creates `vMGA[k]` variables and constrains each to equal the sum of compatible capacity
variables with the same technology, zone or corridor, component role, and period.

- TechType = Julia struct name of the asset (e.g. "ThermalPower", "VariableRenewable")
- Zone = the physical node suffix (or a sorted endpoint pair for transmission)
- Component role keeps power, energy, and distinct asset edges separate
- Period keeps investment vintages separate

Returns human-readable group labels and the vMGA variable vector.
"""
function _mga_node_zone(node::Node)
    node_id = string(id(node))
    separator = findfirst('_', node_id)
    return isnothing(separator) ? node_id : node_id[nextind(node_id, separator):end]
end

function _mga_zone(edge::AbstractEdge)
    zones = sort!(unique!([_mga_node_zone(vertex) for vertex in (edge.start_vertex, edge.end_vertex) if vertex isa Node]))
    return isempty(zones) ? get_zone_name(edge) : join(zones, "__")
end

function _mga_zone(storage::AbstractStorage)
    zones = String[]
    for edge in (storage.charge_edge, storage.discharge_edge)
        isnothing(edge) || append!(zones, [_mga_node_zone(vertex) for vertex in (edge.start_vertex, edge.end_vertex) if vertex isa Node])
    end
    unique!(zones)
    sort!(zones)
    return isempty(zones) ? get_zone_name(storage) : join(zones, "__")
end

function _mga_component_role(asset::AbstractAsset, component, kind::Symbol)
    asset_prefix = string(id(asset), "_")
    component_id = string(id(component))
    role = startswith(component_id, asset_prefix) ? component_id[length(asset_prefix)+1:end] : component_id
    return string(kind, "_", role)
end

function _mga_capacity_variable(model::Model, component)
    component_capacity = capacity(component)
    component_capacity isa VariableRef && return component_capacity

    variable_name = "vCAP_$(id(component))_period$(period_index(component))"
    model_variable = variable_by_name(model, variable_name)
    isnothing(model_variable) && throw(ArgumentError(
        "MGA could not find planning capacity variable $variable_name for component $(id(component))",
    ))
    return model_variable
end

function _mga_setup!(
    model::Model,
    case;
    variable_key::Symbol=:vMGA,
    constraint_prefix::String="cMGACapEquiv",
)
    if haskey(model.obj_dict, variable_key)
        labels_key = Symbol(variable_key, :_labels)
        return get(model.ext, labels_key, String[]), model[variable_key]
    end
    systems = case.systems

    # Collect scientifically compatible capacity groups for every capacity-bearing component.
    asset_entries = NamedTuple[]
    for system in systems
        period = period_index(system)
        for asset in system.assets
            tech = string(typesymbol(typeof(asset)))
            for e in edges_with_capacity_variables(asset)
                key = (
                    tech=tech,
                    zone=_mga_zone(e),
                    component=_mga_component_role(asset, e, :edge),
                    period=period,
                )
                push!(asset_entries, (key=key, cap_var=_mga_capacity_variable(model, e)))
            end
            for s in storages_with_capacity_variables(asset)
                key = (
                    tech=tech,
                    zone=_mga_zone(s),
                    component=_mga_component_role(asset, s, :storage),
                    period=period,
                )
                push!(asset_entries, (key=key, cap_var=_mga_capacity_variable(model, s)))
            end
        end
    end

    if isempty(asset_entries)
        return NamedTuple[], VariableRef[]
    end

    # Keep only groups that actually exist (a sparse representation).
    unique_groups = unique(entry.key for entry in asset_entries)
    n_groups = length(unique_groups)
    group_labels = [
        "$(group.tech)|$(group.zone)|$(group.component)|period$(group.period)"
        for group in unique_groups
    ]

    # One nonnegative aggregate variable per compatible group.
    v_mga = @variable(model, [1:n_groups], lower_bound=0.0, base_name=string(variable_key))
    model[variable_key] = v_mga

    # Tie each aggregate exactly to the sum of its underlying capacity variables.
    for k in 1:n_groups
        group = unique_groups[k]
        cap_vars = [entry.cap_var for entry in asset_entries if entry.key == group]
        @constraint(model, v_mga[k] == sum(cap_vars), base_name="$(constraint_prefix)_$(k)")
    end

    model.ext[Symbol(variable_key, :_labels)] = group_labels
    return group_labels, v_mga
end

function _write_mga_metadata(
    results_base_path::AbstractString,
    group_labels::Vector{String},
    weights::AbstractMatrix,
    slack::Float64,
    budget::Float64,
    n_iterations::Int,
)
    mga_path = joinpath(results_base_path, "mga")
    mkpath(mga_path)
    meta = Dict(
        "mga_slack" => slack,
        "mga_budget" => budget,
        "n_iterations" => n_iterations,
        "total_solves" => n_iterations * 2,
        "mga_groups" => group_labels,
        "approach" => "GenX_vMGA_aggregation",
    )
    settings_path = joinpath(mga_path, "mga_settings.json")
    settings_tmp = settings_path * ".tmp.$(getpid())"
    try
        open(settings_tmp, "w") do io
            JSON3.write(io, meta)
            flush(io)
        end
        mv(settings_tmp, settings_path; force=true)
    finally
        isfile(settings_tmp) && rm(settings_tmp; force=true)
    end

    vectors_path = joinpath(mga_path, "mga_vectors.csv")
    vectors_tmp = vectors_path * ".tmp.$(getpid())"
    try
        CSV.write(
            vectors_tmp,
            DataFrame(permutedims(Matrix(weights)), Symbol.(group_labels)),
        )
        mv(vectors_tmp, vectors_path; force=true)
    finally
        isfile(vectors_tmp) && rm(vectors_tmp; force=true)
    end
    return nothing
end

function _write_mga_solve_summary(base_path::AbstractString, result::NamedTuple)
    path = joinpath(base_path, "solve_$(lpad(result.iteration, 4, '0'))_summary.json")
    temporary = path * ".tmp.$(getpid())"
    try
        open(temporary, "w") do io
            JSON3.write(io, Dict(
                "iteration" => result.iteration,
                "direction" => string(result.direction),
                "feasible" => result.feasible,
                "status" => string(result.status),
                "objective" => result.objective,
            ))
        end
        mv(temporary, path; force=true)
    finally
        isfile(temporary) && rm(temporary; force=true)
    end
    return path
end
