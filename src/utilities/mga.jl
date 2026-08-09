using Random
using Printf: @sprintf

function _validate_mga_inputs(
    group_specs::AbstractVector{<:AbstractMGAQuantitySpec},
    slacks::AbstractVector{<:Real},
    method::Symbol,
    iterations::Integer,
    random_distribution::Symbol,
    pair_order::Symbol,
)
    isempty(group_specs) &&
        throw(ArgumentError("Monolithic MGA requires at least one MGA group."))

    labels = getfield.(group_specs, :label)
    length(unique(labels)) == length(labels) ||
        throw(ArgumentError("MGA group labels must be unique."))

    isempty(slacks) && throw(ArgumentError("At least one MGA slack must be provided."))
    normalized_slacks = Float64.(slacks)
    all(isfinite, normalized_slacks) || throw(ArgumentError("MGA slacks must be finite."))
    all(>=(0), normalized_slacks) || throw(ArgumentError("MGA slacks must be nonnegative."))

    method in (:one_at_a_time, :random) || throw(ArgumentError(
        "Unsupported MGA method `$method`. Choose `:one_at_a_time` or `:random`.",
    ))
    method == :random && iterations <= 0 &&
        throw(ArgumentError("Random MGA requires at least one iteration."))
    random_distribution in (:signed_uniform, :positive_uniform) || throw(ArgumentError(
        "Unsupported MGA random distribution `$random_distribution`. Choose " *
        "`:signed_uniform` or `:positive_uniform`.",
    ))
    pair_order in (:min_max, :max_min) || throw(ArgumentError(
        "Unsupported MGA pair order `$pair_order`. Choose `:min_max` or `:max_min`.",
    ))
    return sort!(unique(normalized_slacks))
end

_is_accepted_mga_status(status) = status in (
    JuMP.MOI.OPTIMAL,
    JuMP.MOI.ALMOST_OPTIMAL,
)

function _mga_baseline(model::JuMP.Model)
    status = JuMP.termination_status(model)
    _is_accepted_mga_status(status) || throw(ArgumentError(
        "The baseline model must be solved to optimality before running MGA; " *
        "termination status was $status.",
    ))
    JuMP.has_values(model) || throw(ArgumentError(
        "The baseline model has no solution values.",
    ))
    sense = JuMP.objective_sense(model)
    objective = JuMP.objective_function(model, JuMP.AffExpr)
    cost = Float64(JuMP.value(objective))
    isfinite(cost) || throw(ArgumentError("The baseline objective value is not finite."))
    return (; sense, objective, status, cost)
end

function _mga_reporting_scales(case)
    parameter_scale = isnothing(case) ? 1.0 :
        parameter_scaling_factor(get_settings(case))
    return (
        parameter=parameter_scale,
        quantity=parameter_scale,
        cost=parameter_scale^2,
    )
end

function _restore_mga_model!(model, baseline, constraints_to_delete)
    for constraint in constraints_to_delete
        !isnothing(constraint) && JuMP.is_valid(model, constraint) &&
            JuMP.delete(model, constraint)
    end
    JuMP.set_objective_sense(model, baseline.sense)
    JuMP.set_objective_function(model, baseline.objective)
    JuMP.optimize!(model)
    return nothing
end

function _resolve_mga_groups(
    model::JuMP.Model,
    specs::AbstractVector{<:AbstractMGAQuantitySpec},
)
    model_variables = JuMP.all_variables(model)
    variable_names = JuMP.name.(model_variables)
    return map(specs) do spec
        if spec isa MGAGroupSpec
            all(isempty, variable_names) && throw(ArgumentError(
                "MGA group matching requires JuMP variable names. Set " *
                "`\"EnableJuMPStringNames\": true` in settings/macro_settings.json.",
            ))
            matches = findall(eachindex(variable_names)) do i
                !isempty(variable_names[i]) && occursin(spec.pattern, variable_names[i])
            end
            isempty(matches) && throw(ArgumentError(
                "MGA group `$(spec.label)` matched no model variables using $(spec.pattern).",
            ))
            terms = [MGAQuantityTerm(variable=model_variables[i]) for i in matches]
            pattern = string(spec.pattern)
        else
            terms = spec.terms
            all(term -> JuMP.owner_model(term.variable) === model, terms) ||
                throw(ArgumentError("Every term in MGA quantity `$(spec.label)` must belong to the model."))
            pattern = missing
        end

        expression = JuMP.AffExpr(0.0)
        for term in terms
            JuMP.add_to_expression!(expression, term.coefficient, term.variable)
        end
        return (
            label=spec.label,
            pattern=pattern,
            scale=spec.scale,
            unit=spec.unit,
            terms=terms,
            expression=expression,
        )
    end
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
    random_distribution::Symbol=:signed_uniform,
    pair_order::Symbol=:min_max,
)
    n_groups = length(groups)
    sense_pairs = pair_order == :max_min ? (
        (JuMP.MOI.MAX_SENSE, "max"),
        (JuMP.MOI.MIN_SENSE, "min"),
    ) : (
        (JuMP.MOI.MIN_SENSE, "min"),
        (JuMP.MOI.MAX_SENSE, "max"),
    )

    if method == :one_at_a_time
        direction_specs = [
            (i, sense, direction)
            for i in eachindex(groups)
            for (sense, direction) in sense_pairs
        ]
        return map(direction_specs) do (i, sense, direction)
            coefficients = zeros(Float64, n_groups)
            coefficients[i] = 1.0
            return (
                name=groups[i].label,
                sense=sense,
                direction=direction,
                coefficients=coefficients,
            )
        end
    end

    rng = MersenneTwister(random_seed)
    random_coefficients = map(1:iterations) do _
        if random_distribution == :positive_uniform
            return rand(rng, n_groups)
        end
        coefficients = rand(rng, n_groups) .* 2 .- 1
        return coefficients ./ sqrt(sum(abs2, coefficients))
    end
    return [
        (
            name="random_$(lpad(i, ndigits(iterations), '0'))",
            sense=sense,
            direction=direction,
            coefficients=random_coefficients[i],
        )
        for i in eachindex(random_coefficients)
        for (sense, direction) in sense_pairs
    ]
end

function _mga_group_objective(groups, coefficients)
    expression = JuMP.AffExpr(0.0)
    for i in eachindex(groups, coefficients)
        group = groups[i]
        JuMP.add_to_expression!(
            expression,
            coefficients[i] * group.scale,
            group.expression,
        )
    end
    return expression
end

function _mga_budget_row_scale(
    objective::JuMP.AffExpr,
    baseline_cost::Real;
    minimum_scaled_coefficient::Real=1e-3,
)
    smallest_coefficient = Inf
    for (coefficient, _) in JuMP.linear_terms(objective)
        magnitude = abs(coefficient)
        iszero(magnitude) || (smallest_coefficient = min(smallest_coefficient, magnitude))
    end
    isfinite(smallest_coefficient) || return 1.0

    # Reduce a large budget RHS without pushing any existing cost coefficient
    # below MacroEnergyScaling's default coefficient range.
    desired_scale = max(abs(baseline_cost), 1.0)
    coefficient_limited_scale = smallest_coefficient / minimum_scaled_coefficient
    return max(1.0, min(desired_scale, coefficient_limited_scale))
end

function _mga_within_budget(
    model_cost::Real,
    budget::Real,
    budget_row_scale::Real;
    scaled_tolerance::Real=1e-6,
    relative_tolerance::Real=1e-9,
)
    allowed_violation = max(
        Float64(scaled_tolerance) * Float64(budget_row_scale),
        Float64(relative_tolerance) * max(abs(Float64(budget)), 1.0),
    )
    return Float64(model_cost) - Float64(budget) <= allowed_violation
end

function _write_mga_progress(
    output_root::AbstractString,
    summary_rows,
    group_value_rows,
)
    CSV.write(joinpath(output_root, "mga_summary.csv"), DataFrame(summary_rows))
    CSV.write(
        joinpath(output_root, "mga_group_values.csv"),
        DataFrame(group_value_rows),
    )
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
- `groups`: Named regex groups or structured `MGAQuantitySpec` quantities to
  explore.

# Other keywords
- `slacks=[0.01, 0.05, 0.10]`: Fractional cost increases.
- `method=:one_at_a_time`: Minimize and maximize each group independently.
  Use `:random` for signed random direction vectors.
- `iterations=100`: Number of random coefficient vectors when `method=:random`.
  Each vector is minimized and maximized, producing two alternatives.
- `random_seed=42`: Reproducible random seed.
- `random_distribution=:signed_uniform`: Normalized signed-uniform directions.
  Use `:positive_uniform` for GenX-style random coefficients in `[0, 1)`.
- `pair_order=:min_max`: Solve each paired direction as min then max. Use
  `:max_min` to reproduce GenX's solve order.
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
    groups::AbstractVector{<:AbstractMGAQuantitySpec},
    slacks::AbstractVector{<:Real}=[0.01, 0.05, 0.10],
    method::Symbol=:one_at_a_time,
    iterations::Integer=100,
    random_seed::Integer=42,
    random_distribution::Symbol=:signed_uniform,
    pair_order::Symbol=:min_max,
    write_detailed_results::Bool=true,
    detailed_output_writer::Function=write_outputs,
    continue_on_failure::Bool=false,
)
    ordered_slacks = _validate_mga_inputs(
        groups,
        slacks,
        method,
        iterations,
        random_distribution,
        pair_order,
    )

    baseline = _mga_baseline(model)
    original_objective = baseline.objective
    original_status = baseline.status
    baseline_cost = baseline.cost

    resolved_groups = _resolve_mga_groups(model, groups)
    directions = _mga_directions(
        resolved_groups,
        method,
        iterations,
        random_seed,
        random_distribution,
        pair_order,
    )
    reporting_scales = _mga_reporting_scales(case)
    parameter_scale = reporting_scales.parameter
    quantity_reporting_scale = reporting_scales.quantity
    cost_reporting_scale = reporting_scales.cost
    budget_row_scale = _mga_budget_row_scale(original_objective, baseline_cost)
    scaled_budget_tolerance = 1e-6
    relative_budget_tolerance = 1e-9

    output_root = joinpath(output_path, "mga")
    mkpath(output_root)

    group_definition_rows = [(
        group=group.label,
        pattern=group.pattern,
        scale=group.scale,
        unit=group.unit,
        variable=JuMP.name(term.variable),
        coefficient=term.coefficient,
        measure=term.measure,
        technology=term.technology,
        asset=term.asset,
        component=term.component,
        commodity=term.commodity,
        location=term.location,
        origin=term.origin,
        destination=term.destination,
        period=term.period,
    ) for group in resolved_groups for term in group.terms]
    CSV.write(
        joinpath(output_root, "mga_group_definitions.csv"),
        DataFrame(group_definition_rows),
    )

    metadata = (
        baseline_objective=baseline_cost * cost_reporting_scale,
        baseline_termination_status=string(original_status),
        parameter_scaling_factor=parameter_scale,
        budget_constraint_scale=budget_row_scale * cost_reporting_scale,
        scaled_budget_tolerance=scaled_budget_tolerance,
        relative_budget_tolerance=relative_budget_tolerance,
        slacks=ordered_slacks,
        method=string(method),
        iterations=iterations,
        random_seed=random_seed,
        random_distribution=string(random_distribution),
        pair_order=string(pair_order),
        write_detailed_results=write_detailed_results,
        detailed_output_writer=string(detailed_output_writer),
        continue_on_failure=continue_on_failure,
        groups=[
            (
                label=group.label,
                pattern=group.pattern,
                scale=group.scale,
                unit=group.unit,
                term_count=length(group.terms),
            ) for group in resolved_groups
        ],
    )
    open(joinpath(output_root, "mga_metadata.json"), "w") do io
        write(io, JSON3.write(metadata))
    end

    direction_rows = [(
        direction_name=direction.name,
        optimization_sense=direction.direction,
        group=resolved_groups[i].label,
        coefficient=direction.coefficients[i],
    ) for direction in directions for i in eachindex(
        resolved_groups,
        direction.coefficients,
    )]
    CSV.write(
        joinpath(output_root, "mga_directions.csv"),
        DataFrame(direction_rows),
    )

    summary_rows = NamedTuple[(
        run_id="baseline",
        slack=0.0,
        cost_budget=baseline_cost * cost_reporting_scale,
        direction_name="baseline",
        optimization_sense="baseline",
        termination_status=string(original_status),
        accepted_status=true,
        has_solution=true,
        within_budget=true,
        system_cost=baseline_cost * cost_reporting_scale,
        mga_objective=missing,
        output_written=missing,
        output_path=output_path,
        error="",
    )]
    group_value_rows = [(
        run_id="baseline",
        slack=0.0,
        direction_name="baseline",
        optimization_sense="baseline",
        group=group.label,
        value=Float64(JuMP.value(group.expression)) * quantity_reporting_scale,
    ) for group in resolved_groups]
    _write_mga_progress(output_root, summary_rows, group_value_rows)
    budget_constraint = nothing

    try
        initial_budget = baseline_cost + first(ordered_slacks) * abs(baseline_cost)
        budget_constraint = @constraint(
            model,
            original_objective / budget_row_scale <= initial_budget / budget_row_scale,
        )

        for (slack_index, slack) in enumerate(ordered_slacks)
            budget = baseline_cost + slack * abs(baseline_cost)
            JuMP.set_normalized_rhs(budget_constraint, budget / budget_row_scale)
            slack_name = @sprintf("slack_%03d_%0.4f", slack_index, slack)

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
                    budget=budget * cost_reporting_scale,
                )

                solve_error = nothing
                solve_start = time()
                try
                    JuMP.optimize!(model)
                catch error
                    solve_error = error
                end

                status = JuMP.termination_status(model)
                accepted_status = _is_accepted_mga_status(status)
                has_solution = isnothing(solve_error) && JuMP.has_values(model)
                model_cost = has_solution ? Float64(JuMP.value(original_objective)) : missing
                model_mga_value = has_solution ? Float64(JuMP.objective_value(model)) : missing
                finite_solution = has_solution && isfinite(model_cost) && isfinite(model_mga_value)
                within_budget = finite_solution &&
                    _mga_within_budget(
                        model_cost,
                        budget,
                        budget_row_scale;
                        scaled_tolerance=scaled_budget_tolerance,
                        relative_tolerance=relative_budget_tolerance,
                    )
                system_cost = finite_solution ?
                    model_cost * cost_reporting_scale : missing
                mga_value = finite_solution ?
                    model_mga_value * quantity_reporting_scale : missing
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
                    cost_budget=budget * cost_reporting_scale,
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

                if finite_solution
                    for group in resolved_groups
                        push!(group_value_rows, (
                            run_id=run_id,
                            slack=slack,
                            direction_name=direction.name,
                            optimization_sense=direction.direction,
                            group=group.label,
                            value=Float64(JuMP.value(group.expression)) *
                                quantity_reporting_scale,
                        ))
                    end
                end

                _write_mga_progress(
                    output_root,
                    summary_rows,
                    group_value_rows,
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
                    !isnothing(solve_error) && throw(solve_error)
                    !isnothing(output_error) && throw(output_error)
                    error(
                        "MGA run `$run_id` failed: status=$status, " *
                        "has_solution=$has_solution, within_budget=$within_budget, " *
                        "output_written=$output_written.",
                    )
                end
            end
        end
    finally
        _restore_mga_model!(model, baseline, (budget_constraint,))
        if write_detailed_results && JuMP.has_values(model)
            postprocess!(case, model)
        end
    end

    return (
        baseline_objective=baseline_cost * cost_reporting_scale,
        output_path=output_root,
        summary=DataFrame(summary_rows),
        group_values=DataFrame(group_value_rows),
        directions=DataFrame(direction_rows),
    )
end
