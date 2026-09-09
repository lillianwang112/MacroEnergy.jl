using Random
using Printf: @sprintf

const _MGA_EDGE_CAPACITY_MEASURES = (
    :capacity,
    :new_capacity,
    :retired_capacity,
    :retrofitted_capacity,
)
const _MGA_EDGE_ACTIVITY_MEASURES = (:annual_activity, :cumulative_activity)
const _MGA_CORRIDOR_MEASURES = (
    :corridor_capacity,
    :new_corridor_capacity,
    :retired_corridor_capacity,
    :annual_net_transfer,
    :cumulative_net_transfer,
)
const _MGA_STORAGE_MEASURES = (
    :storage_energy_capacity,
    :new_storage_energy_capacity,
    :retired_storage_energy_capacity,
)
const _MGA_MEASURES = (
    _MGA_EDGE_CAPACITY_MEASURES...,
    _MGA_EDGE_ACTIVITY_MEASURES...,
    _MGA_CORRIDOR_MEASURES...,
    _MGA_STORAGE_MEASURES...,
)

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
    objective = JuMP.objective_function(model, JuMP.AffExpr)
    cost = Float64(JuMP.value(objective))
    isfinite(cost) || throw(ArgumentError("The baseline objective value is not finite."))
    return (
        sense=JuMP.objective_sense(model),
        objective=objective,
        status=status,
        cost=cost,
    )
end

function _validate_mga_case(case)
    solution_algorithm(case) isa Monolithic || throw(ArgumentError(
        "MGA requires a monolithic MacroEnergy model.",
    ))
    expansion_horizon(case) isa PerfectForesight || throw(ArgumentError(
        "MGA currently requires a perfect-foresight expansion horizon.",
    ))
    return nothing
end

function _mga_reporting_scales(case)
    parameter_scale = parameter_scaling_factor(get_settings(case))
    return (quantity=parameter_scale, cost=parameter_scale^2)
end

function _restore_mga_model!(model, baseline, constraints)
    for constraint in constraints
        !isnothing(constraint) && JuMP.is_valid(model, constraint) &&
            JuMP.delete(model, constraint)
    end
    JuMP.set_objective_sense(model, baseline.sense)
    JuMP.set_objective_function(model, baseline.objective)
    JuMP.optimize!(model)
    return nothing
end

function _set_mga_solver_threads!(model, solver_threads)
    isnothing(solver_threads) && return nothing
    solver_threads isa Integer && solver_threads > 0 || throw(ArgumentError(
        "`solver_threads` must be a positive integer.",
    ))
    try
        JuMP.set_attribute(model, JuMP.MOI.NumberOfThreads(), Int(solver_threads))
    catch error
        throw(ArgumentError(
            "The configured optimizer does not support the standard thread setting: " *
            sprint(showerror, error),
        ))
    end
    return nothing
end

function _mga_periods(case, periods)
    available = Set(period_index(system) for system in get_periods(case))
    selected = isnothing(periods) ? available : Set(Int.(periods))
    isempty(selected) && throw(ArgumentError("MGA requires at least one period."))
    missing_periods = setdiff(selected, available)
    isempty(missing_periods) || throw(ArgumentError(
        "MGA periods $(sort!(collect(missing_periods))) are not present in the case.",
    ))
    return selected
end

function _mga_group_filter(include_groups)
    isnothing(include_groups) && return nothing
    selected = Set(Symbol.(include_groups))
    isempty(selected) && throw(ArgumentError("`include_groups` cannot be empty."))
    return selected
end

function _mga_input_group(component, selected_groups)
    mga(component) || return nothing
    ismissing(mga_group(component)) && throw(ArgumentError(
        "MGA component `$(id(component))` requires an `mga_group` input.",
    ))
    group = Symbol(mga_group(component))
    !isnothing(selected_groups) && !(group in selected_groups) && return nothing
    return group
end

function _mga_edge_location(edge)
    source = start_vertex(edge)
    destination = end_vertex(edge)
    if source isa Node && !(destination isa Node)
        component_location = location(destination)
        return ismissing(component_location) ? get_zone_name(source) : string(component_location)
    elseif !(source isa Node) && destination isa Node
        component_location = location(source)
        return ismissing(component_location) ?
            get_zone_name(destination) : string(component_location)
    elseif source isa Node && destination isa Node
        return "$(get_zone_name(source)) -> $(get_zone_name(destination))"
    end
    throw(ArgumentError(
        "MGA edge `$(id(edge))` must connect an asset to a node or two network nodes.",
    ))
end

function _mga_storage_location(storage)
    storage_location = location(storage)
    !ismissing(storage_location) && return string(storage_location)
    discharge = discharge_edge(storage)
    !isnothing(discharge) && return get_zone_name(end_vertex(discharge))
    charge = charge_edge(storage)
    !isnothing(charge) && return get_zone_name(start_vertex(charge))
    return string(id(storage))
end

function _add_mga_affine!(target, source, model; multiplier::Real=1.0)
    if source isa JuMP.VariableRef
        JuMP.owner_model(source) === model || throw(ArgumentError(
            "An MGA variable does not belong to the supplied model.",
        ))
        JuMP.add_to_expression!(target, multiplier, source)
        return 1
    elseif source isa JuMP.AffExpr
        term_count = 0
        constant = multiplier * JuMP.constant(source)
        iszero(constant) || JuMP.add_to_expression!(target, constant)
        for (coefficient, variable) in JuMP.linear_terms(source)
            JuMP.owner_model(variable) === model || throw(ArgumentError(
                "An MGA variable does not belong to the supplied model.",
            ))
            value = multiplier * coefficient
            iszero(value) || JuMP.add_to_expression!(target, value, variable)
            term_count += !iszero(value)
        end
        return term_count
    elseif source isa Real
        value = multiplier * source
        iszero(value) || JuMP.add_to_expression!(target, value)
        return 0
    end
    throw(ArgumentError("MGA quantities must be variables or affine expressions."))
end

function _mga_edge_capacity(edge, measure)
    has_capacity(edge) || return nothing
    measure in (:capacity, :corridor_capacity) && return capacity(edge)
    measure in (:new_capacity, :new_corridor_capacity) && return new_capacity(edge)
    measure in (:retired_capacity, :retired_corridor_capacity) &&
        return retired_capacity(edge)
    measure == :retrofitted_capacity && return retrofitted_capacity(edge)
    return nothing
end

function _mga_storage_capacity(storage, measure)
    measure == :storage_energy_capacity && return capacity(storage)
    measure == :new_storage_energy_capacity && return new_capacity(storage)
    return retired_capacity(storage)
end

function _mga_group_label(group, location_label, period)
    return "$(group) | $location_label | period $period"
end

function _mga_edge_groups(
    model,
    case,
    measure,
    selected_periods,
    selected_groups,
    unit,
)
    grouped = Dict{Tuple{Symbol,String,Int},Any}()
    matched_groups = Set{Symbol}()
    period_lengths = get_settings(case).PeriodLengths

    for system in get_periods(case)
        period = period_index(system)
        period in selected_periods || continue
        edges, edge_asset_map = get_edges(system; return_ids_map=true)
        for edge in edges
            group = _mga_input_group(edge, selected_groups)
            isnothing(group) && continue

            corridor_measure = measure in _MGA_CORRIDOR_MEASURES
            if corridor_measure &&
                !(start_vertex(edge) isa Node && end_vertex(edge) isa Node)
                continue
            elseif !corridor_measure &&
                start_vertex(edge) isa Node && end_vertex(edge) isa Node
                continue
            end

            location_label = _mga_edge_location(edge)
            key = (group, location_label, period)
            entry = get!(grouped, key) do
                (
                    expression=JuMP.AffExpr(0.0),
                    components=NamedTuple[],
                    origin=corridor_measure ? get_zone_name(start_vertex(edge)) : missing,
                    destination=corridor_measure ? get_zone_name(end_vertex(edge)) : missing,
                )
            end

            term_count = 0
            if measure in (
                _MGA_EDGE_CAPACITY_MEASURES...,
                _MGA_CORRIDOR_MEASURES[1:3]...,
            )
                quantity = _mga_edge_capacity(edge, measure)
                isnothing(quantity) && continue
                term_count = _add_mga_affine!(entry.expression, quantity, model)
            else
                multiplier = measure in (:cumulative_activity, :cumulative_net_transfer) ?
                    period_lengths[period] : 1.0
                for t in time_interval(edge)
                    weight = multiplier *
                        subperiod_weight(edge, current_subperiod(edge, t))
                    iszero(weight) && continue
                    term_count += _add_mga_affine!(
                        entry.expression,
                        flow(edge, t),
                        model;
                        multiplier=weight,
                    )
                end
            end
            term_count == 0 && continue

            asset = edge_asset_map[id(edge)][]
            push!(entry.components, (
                asset=id(asset),
                component=id(edge),
                commodity=get_commodity_name(edge),
                term_count=term_count,
            ))
            push!(matched_groups, group)
        end
    end
    return _finish_mga_groups(grouped, matched_groups, selected_groups, measure, unit)
end

function _mga_storage_groups(
    model,
    case,
    measure,
    selected_periods,
    selected_groups,
    unit,
)
    grouped = Dict{Tuple{Symbol,String,Int},Any}()
    matched_groups = Set{Symbol}()

    for system in get_periods(case)
        period = period_index(system)
        period in selected_periods || continue
        storages, storage_asset_map = get_storages(system; return_ids_map=true)
        for storage in storages
            group = _mga_input_group(storage, selected_groups)
            isnothing(group) && continue
            location_label = _mga_storage_location(storage)
            key = (group, location_label, period)
            entry = get!(grouped, key) do
                (
                    expression=JuMP.AffExpr(0.0),
                    components=NamedTuple[],
                    origin=missing,
                    destination=missing,
                )
            end
            term_count = _add_mga_affine!(
                entry.expression,
                _mga_storage_capacity(storage, measure),
                model,
            )
            term_count == 0 && continue
            asset = storage_asset_map[id(storage)][]
            push!(entry.components, (
                asset=id(asset),
                component=id(storage),
                commodity=get_commodity_name(storage),
                term_count=term_count,
            ))
            push!(matched_groups, group)
        end
    end
    return _finish_mga_groups(grouped, matched_groups, selected_groups, measure, unit)
end

function _finish_mga_groups(grouped, matched_groups, selected_groups, measure, unit)
    if !isnothing(selected_groups)
        missing_groups = setdiff(selected_groups, matched_groups)
        isempty(missing_groups) || throw(ArgumentError(
            "MGA groups $(sort!(collect(missing_groups))) matched no eligible components.",
        ))
    end

    groups = NamedTuple[]
    for (group, location_label, period) in sort!(collect(keys(grouped)))
        entry = grouped[(group, location_label, period)]
        isempty(entry.components) && continue
        push!(groups, (
            label=_mga_group_label(group, location_label, period),
            group=group,
            location=location_label,
            origin=entry.origin,
            destination=entry.destination,
            period=period,
            measure=measure,
            unit=unit,
            expression=entry.expression,
            components=entry.components,
        ))
    end
    isempty(groups) && throw(ArgumentError(
        "No eligible components with `mga=true` were found for measure `$measure`.",
    ))
    return groups
end

function _mga_groups(
    model::JuMP.Model,
    case;
    measure::Symbol,
    periods,
    include_groups,
    unit::String,
)
    measure in _MGA_MEASURES || throw(ArgumentError(
        "Unsupported MGA measure `$measure`.",
    ))
    selected_periods = _mga_periods(case, periods)
    selected_groups = _mga_group_filter(include_groups)
    if measure in _MGA_STORAGE_MEASURES
        return _mga_storage_groups(
            model,
            case,
            measure,
            selected_periods,
            selected_groups,
            unit,
        )
    end
    return _mga_edge_groups(
        model,
        case,
        measure,
        selected_periods,
        selected_groups,
        unit,
    )
end

function _mga_directions(groups, search, iterations, random_seed)
    senses = (
        (JuMP.MOI.MIN_SENSE, "min"),
        (JuMP.MOI.MAX_SENSE, "max"),
    )
    if search == :one_at_a_time
        return [(
            name=groups[i].label,
            sense=sense,
            direction=direction,
            coefficients=[j == i ? 1.0 : 0.0 for j in eachindex(groups)],
        ) for i in eachindex(groups) for (sense, direction) in senses]
    elseif search != :random
        throw(ArgumentError("MGA search must be `:one_at_a_time` or `:random`."))
    end

    iterations > 0 || throw(ArgumentError("Random MGA requires at least one iteration."))
    rng = MersenneTwister(random_seed)
    coefficients = map(1:iterations) do _
        direction = rand(rng, length(groups)) .* 2 .- 1
        return direction ./ sqrt(sum(abs2, direction))
    end
    return [(
        name="random_$(lpad(i, ndigits(iterations), '0'))",
        sense=sense,
        direction=direction,
        coefficients=coefficients[i],
    ) for i in eachindex(coefficients) for (sense, direction) in senses]
end

function _mga_objective(groups, coefficients)
    expression = JuMP.AffExpr(0.0)
    for i in eachindex(groups, coefficients)
        JuMP.add_to_expression!(expression, coefficients[i], groups[i].expression)
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

function _mga_slacks(slacks)
    isempty(slacks) && throw(ArgumentError("At least one MGA slack must be provided."))
    values = sort!(unique(Float64.(slacks)))
    all(isfinite, values) || throw(ArgumentError("MGA slacks must be finite."))
    all(>=(0), values) || throw(ArgumentError("MGA slacks must be nonnegative."))
    return values
end

function _mga_slug(value::AbstractString)
    slug = lowercase(replace(strip(value), r"[^A-Za-z0-9]+" => "_"))
    return isempty(slug) ? "unnamed" : strip(slug, '_')
end

function _write_mga_progress(output_root, summary_rows, group_value_rows)
    CSV.write(joinpath(output_root, "mga_summary.csv"), DataFrame(summary_rows))
    CSV.write(joinpath(output_root, "mga_group_values.csv"), DataFrame(group_value_rows))
    return nothing
end

function _write_mga_definitions(output_root, groups)
    rows = [(
        group=group.label,
        input_group=group.group,
        location=group.location,
        origin=group.origin,
        destination=group.destination,
        period=group.period,
        measure=group.measure,
        unit=group.unit,
        asset=component.asset,
        component=component.component,
        commodity=component.commodity,
        term_count=component.term_count,
    ) for group in groups for component in group.components]
    CSV.write(joinpath(output_root, "mga_group_definitions.csv"), DataFrame(rows))
    return nothing
end

function _mga_baseline_summary(baseline, output_path, reporting_scales)
    return (
        run_id="baseline",
        slack=0.0,
        cost_budget=baseline.cost * reporting_scales.cost,
        direction_name="baseline",
        optimization_sense="baseline",
        termination_status=string(baseline.status),
        accepted_status=true,
        has_solution=true,
        within_budget=true,
        system_cost=baseline.cost * reporting_scales.cost,
        mga_objective=missing,
        output_written=missing,
        output_path=output_path,
        error="",
    )
end

function _mga_error_message(solve_error, output_error)
    !isnothing(solve_error) && return sprint(showerror, solve_error)
    !isnothing(output_error) && return sprint(showerror, output_error)
    return ""
end

function _solve_mga_direction!(
    model,
    case,
    baseline_objective,
    groups,
    direction,
    budget_constraint,
    job,
    reporting_scales,
    budget_row_scale,
    detailed_output_writer,
)
    JuMP.set_normalized_rhs(
        budget_constraint,
        job.budget / budget_row_scale,
    )
    JuMP.set_objective_sense(model, direction.sense)
    JuMP.set_objective_function(model, _mga_objective(groups, direction.coefficients))
    solve_error = nothing
    solve_start = time()
    @info "Starting MGA alternative" job.run_id job.slack
    try
        JuMP.optimize!(model)
    catch error
        solve_error = error
    end

    status = JuMP.termination_status(model)
    accepted_status = _is_accepted_mga_status(status)
    has_solution = isnothing(solve_error) && JuMP.has_values(model)
    model_cost = has_solution ? Float64(JuMP.value(baseline_objective)) : missing
    mga_value = has_solution ? Float64(JuMP.objective_value(model)) : missing
    finite_solution = has_solution && isfinite(model_cost) && isfinite(mga_value)
    within_budget = finite_solution && _mga_within_budget(
        model_cost,
        job.budget,
        budget_row_scale,
    )
    output_written = false
    output_error = nothing
    if accepted_status && within_budget && !isnothing(detailed_output_writer)
        try
            mkpath(job.output_path)
            postprocess!(case, model)
            detailed_output_writer(job.output_path, case, model)
            output_written = true
        catch error
            output_error = error
        end
    end
    summary = (
        run_id=job.run_id,
        slack=job.slack,
        cost_budget=job.budget * reporting_scales.cost,
        direction_name=direction.name,
        optimization_sense=direction.direction,
        termination_status=string(status),
        accepted_status=accepted_status,
        has_solution=has_solution,
        within_budget=within_budget,
        system_cost=finite_solution ? model_cost * reporting_scales.cost : missing,
        mga_objective=finite_solution ?
            mga_value * reporting_scales.quantity : missing,
        output_written=output_written,
        output_path=isnothing(detailed_output_writer) ? "" : job.output_path,
        error=_mga_error_message(solve_error, output_error),
    )
    values = finite_solution ? [(
        run_id=job.run_id,
        slack=job.slack,
        direction_name=direction.name,
        optimization_sense=direction.direction,
        group=group.label,
        value=Float64(JuMP.value(group.expression)) * reporting_scales.quantity,
    ) for group in groups] : NamedTuple[]
    @info "Finished MGA alternative" job.run_id status within_budget elapsed_seconds=(
        time() - solve_start
    )
    run_ok = accepted_status && within_budget &&
        (isnothing(detailed_output_writer) || output_written)
    return (
        summary=summary,
        values=values,
        ok=run_ok,
        solve_error=solve_error,
        output_error=output_error,
    )
end

function _run_mga_parallel(
    model,
    optimizer,
    baseline,
    groups,
    directions,
    ordered_slacks,
    reporting_scales,
    budget_row_scale,
    parallel_workers,
    solver_threads,
)
    optimizer isa Optimizer || throw(ArgumentError(
        "Parallel MGA requires the MacroEnergy optimizer returned by `create_optimizer`.",
    ))
    parallel_workers > 1 || throw(ArgumentError(
        "Parallel MGA requires at least two workers.",
    ))
    parallel_workers <= Threads.nthreads() || throw(ArgumentError(
        "Requested $parallel_workers MGA workers, but Julia has only " *
        "$(Threads.nthreads()) threads. Start Julia with `--threads=$parallel_workers`.",
    ))

    jobs = NamedTuple[]
    for (slack_index, slack) in enumerate(ordered_slacks)
        budget = baseline.cost + slack * abs(baseline.cost)
        slack_name = @sprintf("slack_%03d_%0.4f", slack_index, slack)
        for (direction_index, direction) in enumerate(directions)
            push!(jobs, (
                slack=slack,
                budget=budget,
                direction_index=direction_index,
                run_id=@sprintf(
                    "%s_%03d_%s_%s",
                    slack_name,
                    direction_index,
                    _mga_slug(direction.name),
                    direction.direction,
                ),
            ))
        end
    end
    worker_count = min(parallel_workers, length(jobs))

    worker_data = map(1:worker_count) do _
        copied_model, reference_map = try
            JuMP.copy_model(model)
        catch error
            throw(ArgumentError(
                "The JuMP model cannot be cloned for parallel MGA: " *
                sprint(showerror, error),
            ))
        end
        set_optimizer(copied_model, optimizer)
        _set_mga_solver_threads!(copied_model, solver_threads)
        copied_objective = reference_map[baseline.objective]
        copied_groups = [merge(
            group,
            (expression=reference_map[group.expression],),
        ) for group in groups]
        initial_budget = baseline.cost + first(ordered_slacks) * abs(baseline.cost)
        budget_constraint = @constraint(
            copied_model,
            copied_objective / budget_row_scale <= initial_budget / budget_row_scale,
        )
        return (
            model=copied_model,
            objective=copied_objective,
            groups=copied_groups,
            budget_constraint=budget_constraint,
        )
    end

    results = Vector{Any}(undef, length(jobs))
    Threads.@threads :static for worker_index in 1:worker_count
        data = worker_data[worker_index]
        for job_index in worker_index:worker_count:length(jobs)
            job = jobs[job_index]
            results[job_index] = _solve_mga_direction!(
                data.model,
                nothing,
                data.objective,
                data.groups,
                directions[job.direction_index],
                data.budget_constraint,
                job,
                reporting_scales,
                budget_row_scale,
                nothing,
            )
        end
    end
    return results
end

function _run_mga(
    model,
    case,
    output_path,
    groups;
    slacks,
    search,
    iterations,
    random_seed,
    parallel_workers,
    optimizer,
    solver_threads,
    write_detailed_results,
    detailed_output_writer,
    continue_on_failure,
)
    ordered_slacks = _mga_slacks(slacks)
    search in (:one_at_a_time, :random) || throw(ArgumentError(
        "MGA search must be `:one_at_a_time` or `:random`.",
    ))
    parallel_workers isa Integer && parallel_workers > 0 || throw(ArgumentError(
        "`parallel_workers` must be a positive integer.",
    ))
    parallel_workers == 1 && !isnothing(solver_threads) && throw(ArgumentError(
        "For a serial MGA run, set solver threads when creating the optimizer. " *
        "The `solver_threads` keyword applies only to cloned parallel models.",
    ))
    baseline = _mga_baseline(model)
    directions = _mga_directions(groups, search, iterations, random_seed)
    reporting_scales = _mga_reporting_scales(case)
    budget_row_scale = _mga_budget_row_scale(baseline.objective, baseline.cost)

    output_root = mkpath(joinpath(output_path, "mga"))
    _write_mga_definitions(output_root, groups)
    metadata = (
        measure=string(only(unique(getfield.(groups, :measure)))),
        unit=only(unique(getfield.(groups, :unit))),
        baseline_objective=baseline.cost * reporting_scales.cost,
        baseline_termination_status=string(baseline.status),
        parameter_scaling_factor=reporting_scales.quantity,
        budget_constraint_scale=budget_row_scale * reporting_scales.cost,
        slacks=ordered_slacks,
        search=string(search),
        iterations=search == :random ? iterations : nothing,
        random_seed=search == :random ? random_seed : nothing,
        parallel_workers=parallel_workers,
        solver_threads=solver_threads,
        write_detailed_results=write_detailed_results,
    )
    open(joinpath(output_root, "mga_metadata.json"), "w") do io
        write(io, JSON3.write(metadata))
    end

    direction_rows = [(
        direction_name=direction.name,
        optimization_sense=direction.direction,
        group=groups[i].label,
        coefficient=direction.coefficients[i],
    ) for direction in directions for i in eachindex(groups)]
    CSV.write(joinpath(output_root, "mga_directions.csv"), DataFrame(direction_rows))

    summary_rows = NamedTuple[(_mga_baseline_summary(
        baseline,
        output_path,
        reporting_scales,
    ))]
    group_value_rows = [(
        run_id="baseline",
        slack=0.0,
        direction_name="baseline",
        optimization_sense="baseline",
        group=group.label,
        value=Float64(JuMP.value(group.expression)) * reporting_scales.quantity,
    ) for group in groups]
    _write_mga_progress(output_root, summary_rows, group_value_rows)

    if parallel_workers > 1
        write_detailed_results && throw(ArgumentError(
            "Parallel MGA writes the summary tables but not full case outputs. " *
            "Set `write_detailed_results=false`, then rerun selected alternatives " *
            "serially if full outputs are needed.",
        ))
        results = _run_mga_parallel(
            model,
            optimizer,
            baseline,
            groups,
            directions,
            ordered_slacks,
            reporting_scales,
            budget_row_scale,
            parallel_workers,
            solver_threads,
        )
        for result in results
            push!(summary_rows, result.summary)
            append!(group_value_rows, result.values)
        end
        _write_mga_progress(output_root, summary_rows, group_value_rows)
        if !continue_on_failure && any(!result.ok for result in results)
            error("At least one parallel MGA alternative did not produce a valid solution.")
        end
        return (
            baseline_objective=baseline.cost * reporting_scales.cost,
            output_path=output_root,
            summary=DataFrame(summary_rows),
            group_values=DataFrame(group_value_rows),
            directions=DataFrame(direction_rows),
        )
    end
    budget_constraint = nothing
    try
        initial_budget = baseline.cost + first(ordered_slacks) * abs(baseline.cost)
        budget_constraint = @constraint(
            model,
            baseline.objective / budget_row_scale <= initial_budget / budget_row_scale,
        )

        for (slack_index, slack) in enumerate(ordered_slacks)
            budget = baseline.cost + slack * abs(baseline.cost)
            slack_name = @sprintf("slack_%03d_%0.4f", slack_index, slack)
            for (direction_index, direction) in enumerate(directions)
                run_id = @sprintf(
                    "%s_%03d_%s_%s",
                    slack_name,
                    direction_index,
                    _mga_slug(direction.name),
                    direction.direction,
                )
                job = (
                    run_id=run_id,
                    slack=slack,
                    budget=budget,
                    output_path=joinpath(output_root, slack_name, run_id),
                )
                result = _solve_mga_direction!(
                    model,
                    case,
                    baseline.objective,
                    groups,
                    direction,
                    budget_constraint,
                    job,
                    reporting_scales,
                    budget_row_scale,
                    write_detailed_results ? detailed_output_writer : nothing,
                )
                push!(summary_rows, result.summary)
                append!(group_value_rows, result.values)
                _write_mga_progress(output_root, summary_rows, group_value_rows)
                if !result.ok && !continue_on_failure
                    !isnothing(result.solve_error) && throw(result.solve_error)
                    !isnothing(result.output_error) && throw(result.output_error)
                    error("MGA run `$run_id` did not produce a valid solution.")
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
        baseline_objective=baseline.cost * reporting_scales.cost,
        output_path=output_root,
        summary=DataFrame(summary_rows),
        group_values=DataFrame(group_value_rows),
        directions=DataFrame(direction_rows),
    )
end

"""
    run_mga(model, case, output_path; measure, unit, kwargs...)

Explore near-optimal solutions of a solved monolithic MacroEnergy model. Case
components participate when their inputs set `mga=true` and `mga_group`.

The supported edge measures are available, new, retired, and retrofitted
capacity; annual and period-cumulative activity; corridor capacity; and annual
or period-cumulative net transfer. Storage components additionally support
available, new, and retired energy capacity.

`search=:one_at_a_time` finds the minimum and maximum of every group.
`search=:random` instead uses paired signed random directions. `solver_threads`
sets the optimizer's standard thread count; alternatives remain sequential
because they reuse one JuMP model.
"""
function run_mga(
    model::JuMP.Model,
    case,
    output_path::AbstractString;
    measure::Symbol,
    unit::AbstractString,
    include_groups::Union{Nothing,AbstractVector}=nothing,
    periods::Union{Nothing,AbstractVector{<:Integer}}=nothing,
    slacks::AbstractVector{<:Real}=[0.01, 0.05, 0.10],
    search::Symbol=:one_at_a_time,
    iterations::Integer=100,
    random_seed::Integer=42,
    parallel_workers::Integer=1,
    optimizer=nothing,
    solver_threads::Union{Nothing,Integer}=nothing,
    write_detailed_results::Bool=true,
    detailed_output_writer::Function=write_outputs,
    continue_on_failure::Bool=false,
)
    _validate_mga_case(case)
    clean_unit = String(strip(String(unit)))
    isempty(clean_unit) && throw(ArgumentError("MGA reporting unit cannot be empty."))
    groups = _mga_groups(
        model,
        case;
        measure=measure,
        periods=periods,
        include_groups=include_groups,
        unit=clean_unit,
    )
    return _run_mga(
        model,
        case,
        output_path,
        groups;
        slacks=slacks,
        search=search,
        iterations=iterations,
        random_seed=random_seed,
        parallel_workers=parallel_workers,
        optimizer=optimizer,
        solver_threads=solver_threads,
        write_detailed_results=write_detailed_results,
        detailed_output_writer=detailed_output_writer,
        continue_on_failure=continue_on_failure,
    )
end

function _mga_sum_groups(groups, selected::Set{Symbol})
    expression = JuMP.AffExpr(0.0)
    for group in groups
        group.group in selected || continue
        JuMP.add_to_expression!(expression, group.expression)
    end
    return expression
end

function _is_nonnegative_mga_expression(expression)
    JuMP.constant(expression) >= 0 || return false
    for (coefficient, variable) in JuMP.linear_terms(expression)
        coefficient >= 0 || return false
        JuMP.has_lower_bound(variable) || return false
        JuMP.lower_bound(variable) >= 0 || return false
    end
    return true
end

function _mga_ratio_objective(numerator, denominator, ratio)
    objective = copy(numerator)
    JuMP.add_to_expression!(objective, -ratio, denominator)
    return objective
end

function _write_mga_ratio_progress(output_root, summary_rows, iteration_rows)
    CSV.write(joinpath(output_root, "mga_ratio_summary.csv"), DataFrame(summary_rows))
    table = isempty(iteration_rows) ? DataFrame(
        run_id=String[],
        iteration=Int[],
        ratio=Float64[],
        numerator=Float64[],
        denominator=Float64[],
        residual=Float64[],
        termination_status=String[],
    ) : DataFrame(iteration_rows)
    CSV.write(joinpath(output_root, "mga_ratio_iterations.csv"), table)
    return nothing
end

function _solve_mga_ratio!(
    model,
    case,
    baseline_objective,
    numerator,
    denominator,
    budget_constraint,
    job,
    ratio_name,
    initial_ratio,
    minimum_denominator,
    tolerance,
    max_iterations,
    reporting_scales,
    budget_row_scale,
    detailed_output_writer,
)
    JuMP.set_normalized_rhs(budget_constraint, job.budget / budget_row_scale)
    ratio = initial_ratio
    converged = false
    solve_error = nothing
    status = JuMP.MOI.OPTIMIZE_NOT_CALLED
    numerator_value = NaN
    denominator_value = NaN
    model_cost = NaN
    completed_iterations = 0
    iteration_rows = NamedTuple[]
    solve_start = time()
    @info "Starting MGA ratio alternative" job.run_id job.slack

    for iteration in 1:max_iterations
        completed_iterations = iteration
        JuMP.set_objective_sense(model, job.sense)
        JuMP.set_objective_function(
            model,
            _mga_ratio_objective(numerator, denominator, ratio),
        )
        try
            JuMP.optimize!(model)
        catch error
            solve_error = error
        end
        status = JuMP.termination_status(model)
        has_solution = isnothing(solve_error) && JuMP.has_values(model)
        _is_accepted_mga_status(status) && has_solution || break

        numerator_value = Float64(JuMP.value(numerator))
        denominator_value = Float64(JuMP.value(denominator))
        model_cost = Float64(JuMP.value(baseline_objective))
        residual = numerator_value - ratio * denominator_value
        push!(iteration_rows, (
            run_id=job.run_id,
            iteration=iteration,
            ratio=ratio,
            numerator=numerator_value * reporting_scales.quantity,
            denominator=denominator_value * reporting_scales.quantity,
            residual=residual * reporting_scales.quantity,
            termination_status=string(status),
        ))
        isfinite(numerator_value) && isfinite(denominator_value) &&
            denominator_value >= minimum_denominator || break
        converged = abs(residual) <= tolerance * max(
            1.0,
            abs(numerator_value),
            abs(ratio * denominator_value),
        )
        ratio = numerator_value / denominator_value
        converged && break
    end

    finite_solution = converged && isfinite(model_cost) &&
        isfinite(numerator_value) && isfinite(denominator_value)
    within_budget = finite_solution && _mga_within_budget(
        model_cost,
        job.budget,
        budget_row_scale,
    )
    output_written = false
    output_error = nothing
    if finite_solution && within_budget && !isnothing(detailed_output_writer)
        try
            mkpath(job.output_path)
            postprocess!(case, model)
            detailed_output_writer(job.output_path, case, model)
            output_written = true
        catch error
            output_error = error
        end
    end
    run_error = if !isnothing(solve_error)
        sprint(showerror, solve_error)
    elseif !isnothing(output_error)
        sprint(showerror, output_error)
    elseif !converged
        "Dinkelbach iterations did not converge."
    elseif !within_budget
        "The converged solution exceeded the MGA cost budget."
    else
        ""
    end
    summary = (
        run_id=job.run_id,
        slack=job.slack,
        cost_budget=job.budget * reporting_scales.cost,
        ratio=ratio_name,
        optimization_sense=job.direction,
        termination_status=string(status),
        converged=converged,
        iterations=completed_iterations,
        within_budget=within_budget,
        system_cost=finite_solution ? model_cost * reporting_scales.cost : missing,
        numerator=finite_solution ?
            numerator_value * reporting_scales.quantity : missing,
        denominator=finite_solution ?
            denominator_value * reporting_scales.quantity : missing,
        ratio_value=finite_solution ? numerator_value / denominator_value : missing,
        output_written=output_written,
        output_path=isnothing(detailed_output_writer) ? "" : job.output_path,
        error=run_error,
    )
    @info "Finished MGA ratio alternative" job.run_id status converged elapsed_seconds=(
        time() - solve_start
    )
    run_ok = finite_solution && within_budget &&
        (isnothing(detailed_output_writer) || output_written)
    return (
        summary=summary,
        iterations=iteration_rows,
        ok=run_ok,
        solve_error=solve_error,
        output_error=output_error,
    )
end

"""
    run_mga_ratio(model, case, output_path; numerator_groups,
                  denominator_groups, measure, unit, kwargs...)

Find the minimum and maximum of a ratio within each MGA cost budget. The
numerator and denominator are sums of input-selected `mga_group` values. A
share is represented by including the numerator group in both lists, such as
solar divided by solar plus wind.

The ratio is solved by Dinkelbach iterations, so each subproblem remains linear
when the underlying MacroEnergy model is linear. Both expressions must use
nonnegative variables and coefficients, and the denominator is constrained to
remain positive.
"""
function run_mga_ratio(
    model::JuMP.Model,
    case,
    output_path::AbstractString;
    numerator_groups::AbstractVector,
    denominator_groups::AbstractVector,
    measure::Symbol,
    unit::AbstractString,
    name::AbstractString="ratio",
    periods::Union{Nothing,AbstractVector{<:Integer}}=nothing,
    slacks::AbstractVector{<:Real}=[0.01, 0.05, 0.10],
    minimum_denominator::Real=1e-6,
    tolerance::Real=1e-8,
    max_iterations::Integer=100,
    write_detailed_results::Bool=true,
    detailed_output_writer::Function=write_outputs,
    continue_on_failure::Bool=false,
)
    _validate_mga_case(case)
    numerator_names = _mga_group_filter(numerator_groups)
    denominator_names = _mga_group_filter(denominator_groups)
    clean_name = String(strip(String(name)))
    isempty(clean_name) && throw(ArgumentError("MGA ratio name cannot be empty."))
    clean_unit = String(strip(String(unit)))
    isempty(clean_unit) && throw(ArgumentError("MGA reporting unit cannot be empty."))
    minimum = Float64(minimum_denominator)
    isfinite(minimum) && minimum > 0 || throw(ArgumentError(
        "`minimum_denominator` must be finite and positive.",
    ))
    convergence_tolerance = Float64(tolerance)
    isfinite(convergence_tolerance) && convergence_tolerance > 0 ||
        throw(ArgumentError("MGA ratio tolerance must be finite and positive."))
    max_iterations > 0 || throw(ArgumentError(
        "MGA ratio search requires at least one Dinkelbach iteration.",
    ))

    all_names = collect(union(numerator_names, denominator_names))
    groups = _mga_groups(
        model,
        case;
        measure=measure,
        periods=periods,
        include_groups=all_names,
        unit=clean_unit,
    )
    numerator = _mga_sum_groups(groups, numerator_names)
    denominator = _mga_sum_groups(groups, denominator_names)
    _is_nonnegative_mga_expression(numerator) || throw(ArgumentError(
        "The MGA ratio numerator must be a nonnegative quantity.",
    ))
    _is_nonnegative_mga_expression(denominator) || throw(ArgumentError(
        "The MGA ratio denominator must be a nonnegative quantity.",
    ))

    ordered_slacks = _mga_slacks(slacks)
    baseline = _mga_baseline(model)
    reporting_scales = _mga_reporting_scales(case)
    budget_row_scale = _mga_budget_row_scale(baseline.objective, baseline.cost)
    minimum_model_denominator = minimum / reporting_scales.quantity

    output_root = mkpath(joinpath(output_path, "mga_ratio"))
    definition_rows = [(
        ratio=clean_name,
        role=group.group in numerator_names && group.group in denominator_names ?
            "numerator_and_denominator" :
            (group.group in numerator_names ? "numerator" : "denominator"),
        group=group.label,
        input_group=group.group,
        location=group.location,
        period=group.period,
        measure=group.measure,
        unit=group.unit,
    ) for group in groups]
    CSV.write(
        joinpath(output_root, "mga_ratio_definitions.csv"),
        DataFrame(definition_rows),
    )
    metadata = (
        name=clean_name,
        algorithm="Dinkelbach",
        measure=string(measure),
        unit=clean_unit,
        numerator_groups=sort!(string.(collect(numerator_names))),
        denominator_groups=sort!(string.(collect(denominator_names))),
        minimum_denominator=minimum,
        tolerance=convergence_tolerance,
        max_iterations=max_iterations,
        slacks=ordered_slacks,
        baseline_objective=baseline.cost * reporting_scales.cost,
    )
    open(joinpath(output_root, "mga_ratio_metadata.json"), "w") do io
        write(io, JSON3.write(metadata))
    end

    baseline_numerator = Float64(JuMP.value(numerator))
    baseline_denominator = Float64(JuMP.value(denominator))
    baseline_ratio = baseline_denominator >= minimum_model_denominator ?
        baseline_numerator / baseline_denominator : missing
    initial_ratio = ismissing(baseline_ratio) ? 0.0 : baseline_ratio
    summary_rows = NamedTuple[(
        run_id="baseline",
        slack=0.0,
        cost_budget=baseline.cost * reporting_scales.cost,
        ratio=clean_name,
        optimization_sense="baseline",
        termination_status=string(baseline.status),
        converged=!ismissing(baseline_ratio),
        iterations=0,
        within_budget=true,
        system_cost=baseline.cost * reporting_scales.cost,
        numerator=baseline_numerator * reporting_scales.quantity,
        denominator=baseline_denominator * reporting_scales.quantity,
        ratio_value=baseline_ratio,
        output_written=missing,
        output_path=output_path,
        error="",
    )]
    iteration_rows = NamedTuple[]
    _write_mga_ratio_progress(output_root, summary_rows, iteration_rows)
    budget_constraint = nothing
    denominator_constraint = nothing
    try
        initial_budget = baseline.cost + first(ordered_slacks) * abs(baseline.cost)
        budget_constraint = @constraint(
            model,
            baseline.objective / budget_row_scale <= initial_budget / budget_row_scale,
        )
        denominator_constraint = @constraint(
            model,
            denominator >= minimum_model_denominator,
        )

        for (slack_index, slack) in enumerate(ordered_slacks)
            budget = baseline.cost + slack * abs(baseline.cost)
            slack_name = @sprintf("slack_%03d_%0.4f", slack_index, slack)
            for (sense, direction) in (
                (JuMP.MOI.MIN_SENSE, "min"),
                (JuMP.MOI.MAX_SENSE, "max"),
            )
                run_id = "$(slack_name)_$(_mga_slug(clean_name))_$direction"
                job = (
                    run_id=run_id,
                    slack=slack,
                    budget=budget,
                    sense=sense,
                    direction=direction,
                    output_path=joinpath(output_root, slack_name, run_id),
                )
                result = _solve_mga_ratio!(
                    model,
                    case,
                    baseline.objective,
                    numerator,
                    denominator,
                    budget_constraint,
                    job,
                    clean_name,
                    initial_ratio,
                    minimum_model_denominator,
                    convergence_tolerance,
                    max_iterations,
                    reporting_scales,
                    budget_row_scale,
                    write_detailed_results ? detailed_output_writer : nothing,
                )
                push!(summary_rows, result.summary)
                append!(iteration_rows, result.iterations)
                _write_mga_ratio_progress(output_root, summary_rows, iteration_rows)
                if !result.ok && !continue_on_failure
                    !isnothing(result.solve_error) && throw(result.solve_error)
                    !isnothing(result.output_error) && throw(result.output_error)
                    error("MGA ratio run `$run_id` did not produce a valid solution.")
                end
            end
        end
    finally
        _restore_mga_model!(
            model,
            baseline,
            (denominator_constraint, budget_constraint),
        )
        if write_detailed_results && JuMP.has_values(model)
            postprocess!(case, model)
        end
    end

    return (
        baseline_objective=baseline.cost * reporting_scales.cost,
        output_path=output_root,
        summary=DataFrame(summary_rows),
        iterations=DataFrame(iteration_rows),
    )
end
