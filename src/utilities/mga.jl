using Random

"""
    MGAGroupSpec(label, pattern; coefficient=1.0)

Define one named Modeling to Generate Alternatives (MGA) quantity from model
variables whose JuMP names match `pattern`. The group value is

`coefficient * sum(matched variables)`.

Groups may overlap. For example, an `"all_wind"` group may match the same
variables as separate `"onshore_wind"` and `"offshore_wind"` groups.
"""
struct MGAGroupSpec
    label::String
    pattern::Regex
    coefficient::Float64

    function MGAGroupSpec(
        label::AbstractString,
        pattern::Regex;
        coefficient::Real=1.0,
    )
        isempty(strip(label)) && throw(ArgumentError("An MGA group label cannot be empty."))
        isfinite(coefficient) || throw(ArgumentError("MGA group coefficients must be finite."))
        coefficient == 0 && throw(ArgumentError("An MGA group coefficient cannot be zero."))
        return new(String(label), pattern, Float64(coefficient))
    end
end

function _validate_mga_inputs(
    group_specs::AbstractVector{MGAGroupSpec},
    slacks::AbstractVector{<:Real},
    method::Symbol,
    iterations::Integer,
)
    isempty(group_specs) && throw(ArgumentError(
        "Monolithic MGA requires at least one explicit MGAGroupSpec. " *
        "Explicit groups prevent unlike technologies or units from being combined silently.",
    ))

    labels = getfield.(group_specs, :label)
    length(unique(labels)) == length(labels) ||
        throw(ArgumentError("MGA group labels must be unique."))

    isempty(slacks) && throw(ArgumentError("At least one MGA slack must be provided."))
    all(isfinite, slacks) || throw(ArgumentError("MGA slacks must be finite."))
    all(>=(0), slacks) || throw(ArgumentError("MGA slacks must be nonnegative."))

    method in (:one_at_a_time, :random) || throw(ArgumentError(
        "Unsupported MGA method `$method`. Choose `:one_at_a_time` or `:random`.",
    ))
    iterations > 0 || throw(ArgumentError("MGA iterations must be positive."))
    return nothing
end

function _resolve_mga_groups(model::JuMP.Model, specs::AbstractVector{MGAGroupSpec})
    model_variables = JuMP.all_variables(model)
    variable_names = JuMP.name.(model_variables)
    all(isempty, variable_names) && throw(ArgumentError(
        "MGA group matching requires JuMP variable names. Set " *
        "`\"EnableJuMPStringNames\": true` in settings/macro_settings.json.",
    ))
    groups = NamedTuple[]

    for spec in specs
        matches = findall(name -> occursin(spec.pattern, name), variable_names)
        isempty(matches) && throw(ArgumentError(
            "MGA group `$(spec.label)` matched no model variables using $(spec.pattern).",
        ))

        expression = JuMP.AffExpr(0.0)
        for i in matches
            JuMP.add_to_expression!(expression, spec.coefficient, model_variables[i])
        end
        push!(groups, (
            label=spec.label,
            pattern=string(spec.pattern),
            coefficient=spec.coefficient,
            variable_names=variable_names[matches],
            expression=expression,
        ))
    end
    return groups
end

function _mga_slug(value::AbstractString)
    slug = lowercase(replace(strip(value), r"[^A-Za-z0-9]+" => "_"))
    return isempty(slug) ? "unnamed" : strip(slug, '_')
end

function _mga_directions(
    groups,
    method::Symbol,
    iterations::Integer,
    random_seed::Integer,
)
    directions = NamedTuple[]
    n_groups = length(groups)

    if method == :one_at_a_time
        for (i, group) in enumerate(groups)
            coefficients = zeros(Float64, n_groups)
            coefficients[i] = 1.0
            push!(directions, (
                name=group.label,
                sense=JuMP.MOI.MIN_SENSE,
                direction="min",
                coefficients=coefficients,
            ))
            push!(directions, (
                name=group.label,
                sense=JuMP.MOI.MAX_SENSE,
                direction="max",
                coefficients=coefficients,
            ))
        end
    else
        rng = MersenneTwister(random_seed)
        for i in 1:iterations
            coefficients = rand(rng, n_groups) .* 2 .- 1
            norm_value = sqrt(sum(abs2, coefficients))
            coefficients ./= norm_value
            push!(directions, (
                name="random_$(lpad(i, ndigits(iterations), '0'))",
                sense=JuMP.MOI.MIN_SENSE,
                direction="min",
                coefficients=coefficients,
            ))
        end
    end
    return directions
end

function _mga_group_objective(groups, coefficients)
    expression = JuMP.AffExpr(0.0)
    for (group, coefficient) in zip(groups, coefficients)
        JuMP.add_to_expression!(expression, coefficient, group.expression)
    end
    return expression
end

function _write_mga_tables(
    output_root::AbstractString,
    summary_rows,
    vector_rows,
    direction_rows,
)
    CSV.write(joinpath(output_root, "mga_summary.csv"), DataFrame(summary_rows))
    group_values = if isempty(vector_rows)
        DataFrame(
            run_id=String[],
            slack=Float64[],
            direction_name=String[],
            optimization_sense=String[],
            group=String[],
            value=Float64[],
        )
    else
        DataFrame(vector_rows)
    end
    CSV.write(joinpath(output_root, "mga_group_values.csv"), group_values)
    CSV.write(joinpath(output_root, "mga_directions.csv"), DataFrame(direction_rows))
    return nothing
end

"""
    write_mga_capacity_outputs(output_path, case, model)

Write only `capacity.csv` (plus case settings) for an MGA alternative. This is
useful for large sweeps whose analysis needs regional investment results but
not operational time-series outputs.
"""
function write_mga_capacity_outputs(
    output_path::AbstractString,
    case,
    model::JuMP.Model,
)
    num_periods = number_of_periods(case)
    periods = get_periods(case)
    scaling = parameter_scaling_factor(get_settings(case))
    capacity_summaries = DataFrame[]

    for (period_index, system) in enumerate(periods)
        results_dir = mkpath_for_period(output_path, num_periods, period_index)
        capacity = write_capacity(
            joinpath(results_dir, "capacity.csv"),
            system,
            scaling,
        )
        if capacity isa DataFrame
            push!(capacity_summaries, capacity)
        end
    end

    if num_periods > 1 && length(capacity_summaries) == num_periods
        write_capacity_summary(
            output_path,
            capacity_summaries,
            get_output_layout(periods[1], :CapacitySummary),
        )
    elseif num_periods > 1
        @warn(
            "Skipping the cross-period MGA capacity summary because this " *
            "MacroEnergy version does not return capacity tables from write_capacity.",
        )
    end
    write_settings(case, joinpath(output_path, "settings.json"))
    return nothing
end

"""
    run_monolithic_mga(model, case, output_path; kwargs...)

Explore near-optimal solutions of an already solved monolithic MacroEnergy
model. The original objective value `z*` defines the cost budget

`original_objective <= z* + slack * abs(z*)`.

The same model and budget constraint are reused across all directions and
slacks, avoiding repeated case and model construction.

# Required keyword
- `groups::Vector{MGAGroupSpec}`: Explicit named quantities to explore.

# Other keywords
- `slacks=[0.01, 0.05, 0.10]`: Fractional cost increases.
- `method=:one_at_a_time`: Minimize and maximize each group independently.
  Use `:random` for signed random direction vectors.
- `iterations=100`: Number of directions when `method=:random`.
- `random_seed=42`: Reproducible random seed.
- `write_detailed_results=true`: Write standard MacroEnergy outputs for each
  successful alternative.
- `detailed_output_writer=write_outputs`: Output function called as
  `writer(path, case, model)`. Use `write_mga_capacity_outputs` for compact
  capacity-only alternatives.
- `continue_on_failure=false`: Record a failed direction and continue.

The function always restores and re-solves the original model objective before
returning or rethrowing an error.
"""
function run_monolithic_mga(
    model::JuMP.Model,
    case,
    output_path::AbstractString;
    groups::AbstractVector{MGAGroupSpec},
    slacks::AbstractVector{<:Real}=[0.01, 0.05, 0.10],
    method::Symbol=:one_at_a_time,
    iterations::Integer=100,
    random_seed::Integer=42,
    write_detailed_results::Bool=true,
    detailed_output_writer::Function=write_outputs,
    continue_on_failure::Bool=false,
)
    _validate_mga_inputs(groups, slacks, method, iterations)
    JuMP.has_values(model) || throw(ArgumentError(
        "The baseline model must have a feasible solution before running MGA.",
    ))

    original_sense = JuMP.objective_sense(model)
    original_objective = JuMP.objective_function(model)
    original_status = JuMP.termination_status(model)
    baseline_cost = Float64(JuMP.value(original_objective))
    isfinite(baseline_cost) || throw(ArgumentError("The baseline objective value is not finite."))

    resolved_groups = _resolve_mga_groups(model, groups)
    directions = _mga_directions(resolved_groups, method, iterations, random_seed)
    ordered_slacks = sort!(unique(Float64.(slacks)))

    output_root = joinpath(output_path, "mga")
    mkpath(output_root)

    group_definition_rows = NamedTuple[]
    for group in resolved_groups
        for variable_name in group.variable_names
            push!(group_definition_rows, (
                group=group.label,
                pattern=group.pattern,
                coefficient=group.coefficient,
                variable=variable_name,
            ))
        end
    end
    CSV.write(
        joinpath(output_root, "mga_group_definitions.csv"),
        DataFrame(group_definition_rows),
    )

    metadata = (
        baseline_objective=baseline_cost,
        baseline_termination_status=string(original_status),
        slacks=ordered_slacks,
        method=string(method),
        iterations=iterations,
        random_seed=random_seed,
        write_detailed_results=write_detailed_results,
        detailed_output_writer=string(detailed_output_writer),
        continue_on_failure=continue_on_failure,
        groups=[
            (
                label=group.label,
                pattern=group.pattern,
                coefficient=group.coefficient,
                variable_count=length(group.variable_names),
            ) for group in resolved_groups
        ],
    )
    open(joinpath(output_root, "mga_metadata.json"), "w") do io
        write(io, JSON3.write(metadata))
    end

    direction_rows = NamedTuple[]
    for direction in directions
        for (group, coefficient) in zip(resolved_groups, direction.coefficients)
            push!(direction_rows, (
                direction_name=direction.name,
                optimization_sense=direction.direction,
                group=group.label,
                coefficient=coefficient,
            ))
        end
    end

    summary_rows = NamedTuple[(
        run_id="baseline",
        slack=0.0,
        cost_budget=baseline_cost,
        direction_name="baseline",
        optimization_sense="baseline",
        termination_status=string(original_status),
        accepted_status=true,
        has_solution=true,
        within_budget=true,
        system_cost=baseline_cost,
        mga_objective=missing,
        output_written=true,
        output_path=output_path,
        error="",
    )]
    vector_rows = NamedTuple[]
    for group in resolved_groups
        push!(vector_rows, (
            run_id="baseline",
            slack=0.0,
            direction_name="baseline",
            optimization_sense="baseline",
            group=group.label,
            value=Float64(JuMP.value(group.expression)),
        ))
    end
    _write_mga_tables(output_root, summary_rows, vector_rows, direction_rows)
    budget_constraint = nothing

    try
        initial_budget = baseline_cost + first(ordered_slacks) * abs(baseline_cost)
        budget_constraint = @constraint(model, original_objective <= initial_budget)

        for slack in ordered_slacks
            budget = baseline_cost + slack * abs(baseline_cost)
            JuMP.set_normalized_rhs(budget_constraint, budget)
            slack_name = @sprintf("slack_%0.4f", slack)

            for (direction_index, direction) in enumerate(directions)
                run_id = @sprintf("%s_%03d_%s_%s",
                    slack_name,
                    direction_index,
                    _mga_slug(direction.name),
                    direction.direction,
                )
                alternative_path = joinpath(
                    output_root,
                    slack_name,
                    @sprintf("%03d_%s_%s",
                        direction_index,
                        _mga_slug(direction.name),
                        direction.direction,
                    ),
                )
                objective = _mga_group_objective(
                    resolved_groups,
                    direction.coefficients,
                )
                JuMP.set_objective_sense(model, direction.sense)
                JuMP.set_objective_function(model, objective)
                @info(
                    "Starting MGA alternative",
                    run_id=run_id,
                    slack=slack,
                    direction=direction.name,
                    sense=direction.direction,
                    budget=budget,
                )

                solve_error = nothing
                solve_start = time()
                try
                    JuMP.optimize!(model)
                catch error
                    solve_error = error
                end

                status = JuMP.termination_status(model)
                accepted_status = status in (
                    JuMP.MOI.OPTIMAL,
                    JuMP.MOI.LOCALLY_SOLVED,
                    JuMP.MOI.ALMOST_OPTIMAL,
                )
                has_solution = isnothing(solve_error) && JuMP.has_values(model)
                system_cost = has_solution ? Float64(JuMP.value(original_objective)) : missing
                mga_value = has_solution ? Float64(JuMP.objective_value(model)) : missing
                budget_tolerance = max(1e-6, 1e-7 * max(1.0, abs(budget)))
                within_budget = has_solution &&
                    system_cost <= budget + budget_tolerance
                output_written = false
                output_error = nothing

                if accepted_status && has_solution && within_budget &&
                    write_detailed_results
                    try
                        mkpath(alternative_path)
                        postprocess!(case, model)
                        detailed_output_writer(alternative_path, case, model)
                        output_written = true
                    catch error
                        output_error = error
                    end
                end

                push!(summary_rows, (
                    run_id=run_id,
                    slack=slack,
                    cost_budget=budget,
                    direction_name=direction.name,
                    optimization_sense=direction.direction,
                    termination_status=string(status),
                    accepted_status=accepted_status,
                    has_solution=has_solution,
                    within_budget=within_budget,
                    system_cost=system_cost,
                    mga_objective=mga_value,
                    output_written=output_written,
                    output_path=write_detailed_results ? alternative_path : "",
                    error=isnothing(solve_error) ? (
                        isnothing(output_error) ? "" : sprint(showerror, output_error)
                    ) : sprint(showerror, solve_error),
                ))

                if has_solution
                    for group in resolved_groups
                        push!(vector_rows, (
                            run_id=run_id,
                            slack=slack,
                            direction_name=direction.name,
                            optimization_sense=direction.direction,
                            group=group.label,
                            value=Float64(JuMP.value(group.expression)),
                        ))
                    end
                end

                _write_mga_tables(
                    output_root,
                    summary_rows,
                    vector_rows,
                    direction_rows,
                )

                run_ok = accepted_status && has_solution && within_budget &&
                    (!write_detailed_results || output_written)
                @info(
                    "Finished MGA alternative",
                    run_id=run_id,
                    status=string(status),
                    accepted_status=accepted_status,
                    elapsed_seconds=round(time() - solve_start; digits=3),
                    system_cost=system_cost,
                    within_budget=within_budget,
                    output_written=output_written,
                )
                if !run_ok && !continue_on_failure
                    error(
                        "MGA run `$run_id` failed: status=$status, " *
                        "has_solution=$has_solution, within_budget=$within_budget, " *
                        "output_written=$output_written.",
                    )
                end
            end
        end
    finally
        if !isnothing(budget_constraint) && JuMP.is_valid(model, budget_constraint)
            JuMP.delete(model, budget_constraint)
        end
        JuMP.set_objective_sense(model, original_sense)
        JuMP.set_objective_function(model, original_objective)
        JuMP.optimize!(model)
        if write_detailed_results && JuMP.has_values(model)
            postprocess!(case, model)
        end
    end

    return (
        baseline_objective=baseline_cost,
        output_path=output_root,
        summary=DataFrame(summary_rows),
        group_values=DataFrame(vector_rows),
        directions=DataFrame(direction_rows),
    )
end
