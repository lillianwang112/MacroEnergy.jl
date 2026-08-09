"""
    GenXMGAResourceSpec(technology, commodity; kwargs...)

Map eligible MacroEnergy assets to one GenX-style MGA technology group.
`asset_types` uses MacroEnergy output names such as `"VRE"` or
`"ThermalPower"`; parameterized variants match their base type. Optional asset
and component patterns distinguish technologies that share an asset type. An
optional `location_pattern` extracts a location from each asset ID; its first
capture group is used when present.
"""
struct GenXMGAResourceSpec
    technology::String
    commodity::Symbol
    asset_types::Vector{String}
    asset_pattern::Union{Nothing,Regex}
    component_pattern::Union{Nothing,Regex}
    location_pattern::Union{Nothing,Regex}
    capacity_unit::String
    activity_unit::String

    function GenXMGAResourceSpec(
        technology::AbstractString,
        commodity::Symbol;
        asset_types::AbstractVector{<:AbstractString}=String[],
        asset_pattern::Union{Nothing,Regex}=nothing,
        component_pattern::Union{Nothing,Regex}=nothing,
        location_pattern::Union{Nothing,Regex}=nothing,
        capacity_unit::AbstractString="model capacity units",
        activity_unit::AbstractString="model activity units",
    )
        clean_technology = _normalize_mga_label(technology)
        clean_asset_types = strip.(String.(asset_types))
        any(isempty, clean_asset_types) &&
            throw(ArgumentError("GenX-style MGA asset types cannot be empty strings."))
        clean_capacity_unit = strip(String(capacity_unit))
        clean_activity_unit = strip(String(activity_unit))
        isempty(clean_capacity_unit) &&
            throw(ArgumentError("A GenX-style MGA capacity unit cannot be empty."))
        isempty(clean_activity_unit) &&
            throw(ArgumentError("A GenX-style MGA activity unit cannot be empty."))
        return new(
            clean_technology,
            commodity,
            clean_asset_types,
            asset_pattern,
            component_pattern,
            location_pattern,
            clean_capacity_unit,
            clean_activity_unit,
        )
    end
end

function _mga_base_asset_type(asset)
    return string(typesymbol(typeof(asset)))
end

function _matches_genx_resource(spec::GenXMGAResourceSpec, edge, asset)
    isempty(spec.asset_types) || _mga_base_asset_type(asset) in spec.asset_types || return false
    isnothing(spec.asset_pattern) || occursin(spec.asset_pattern, string(id(asset))) || return false
    isnothing(spec.component_pattern) ||
        occursin(spec.component_pattern, string(id(edge))) || return false
    get_commodity_name(edge) == spec.commodity || return false
    return end_vertex(edge) isa Node
end

function _genx_resource_location(spec, edge, asset)
    !isnothing(spec.location_pattern) &&
        return _mga_location_from_pattern(asset, spec.location_pattern)
    resource_location = location(start_vertex(edge))
    return ismissing(resource_location) ?
        get_zone_name(end_vertex(edge)) : string(resource_location)
end

function _genx_capacity_term(spec, edge, asset, location, period)
    capacity(edge) isa JuMP.VariableRef || throw(ArgumentError(
        "GenX-style capacity MGA requires a JuMP capacity variable for component $(id(edge)).",
    ))
    return MGAQuantityTerm(
        variable=capacity(edge),
        coefficient=1.0,
        measure=:capacity,
        technology=spec.technology,
        asset=id(asset),
        component=id(edge),
        commodity=spec.commodity,
        location=location,
        period=period,
    )
end

function _genx_annual_activity_terms(spec, edge, asset, location, period)
    return [
        MGAQuantityTerm(
            variable=flow(edge, t),
            coefficient=subperiod_weight(edge, current_subperiod(edge, t)),
            measure=:annual_generation,
            technology=spec.technology,
            asset=id(asset),
            component=id(edge),
            commodity=spec.commodity,
            location=location,
            period=period,
        ) for t in time_interval(edge)
    ]
end

"""
    genx_mga_quantities(case, resources; measure=:capacity, periods=nothing)

Construct GenX-style technology-by-location-by-period MGA quantities from a
generated MacroEnergy case. `measure` may be `:capacity` or
`:annual_generation`. `periods=nothing` includes every investment period. If
an asset has no location, its receiving node ID is used as the location label.
"""
function genx_mga_quantities(
    case,
    resources::AbstractVector{GenXMGAResourceSpec};
    measure::Symbol=:capacity,
    periods::Union{Nothing,AbstractVector{<:Integer}}=nothing,
)
    measure in (:capacity, :annual_generation) || throw(ArgumentError(
        "GenX-style MGA measure must be `:capacity` or `:annual_generation`.",
    ))
    isempty(resources) && throw(ArgumentError(
        "GenX-style MGA requires at least one eligible resource specification.",
    ))
    selected_periods = isnothing(periods) ?
        Set(period_index(system) for system in get_periods(case)) : Set(Int.(periods))

    quantities = MGAQuantitySpec[]
    for spec in resources
        matched_resource = false
        for system in get_periods(case)
            period = period_index(system)
            period in selected_periods || continue
            edges, edge_asset_map = get_edges(system; return_ids_map=true)
            grouped_terms = Dict{String,Vector{MGAQuantityTerm}}()
            for edge in edges
                asset = edge_asset_map[id(edge)][]
                _matches_genx_resource(spec, edge, asset) || continue
                measure == :capacity && !has_capacity(edge) && continue
                matched_resource = true
                location = _genx_resource_location(spec, edge, asset)
                terms = get!(grouped_terms, location, MGAQuantityTerm[])
                if measure == :capacity
                    push!(terms, _genx_capacity_term(spec, edge, asset, location, period))
                else
                    append!(
                        terms,
                        _genx_annual_activity_terms(spec, edge, asset, location, period),
                    )
                end
            end
            for location in sort!(collect(keys(grouped_terms)))
                unit = measure == :capacity ? spec.capacity_unit : spec.activity_unit
                push!(quantities, MGAQuantitySpec(
                    "$(spec.technology) | $(location) | period $(period)",
                    grouped_terms[location];
                    unit=unit,
                ))
            end
        end
        matched_resource || throw(ArgumentError(
            "GenX-style MGA resource `$(spec.technology)` matched no eligible output edges.",
        ))
    end
    return quantities
end

"""
    run_genx_mga(model, case, output_path; resources, kwargs...)

Run the GenX-style MGA formulation on a solved monolithic MacroEnergy model.
Each iteration draws positive uniform coefficients for the selected
technology-by-location-by-period quantities, then maximizes and minimizes that
same coefficient vector. Set `measure=:annual_generation` to use time-weighted
annual activity instead of available capacity.
"""
function run_genx_mga(
    model::JuMP.Model,
    case,
    output_path::AbstractString;
    resources::AbstractVector{GenXMGAResourceSpec},
    measure::Symbol=:capacity,
    periods::Union{Nothing,AbstractVector{<:Integer}}=nothing,
    slacks::AbstractVector{<:Real}=[0.01, 0.05, 0.10],
    iterations::Integer=10,
    random_seed::Integer=42,
    write_detailed_results::Bool=true,
    detailed_output_writer::Function=write_outputs,
    continue_on_failure::Bool=false,
)
    quantities = genx_mga_quantities(
        case,
        resources;
        measure=measure,
        periods=periods,
    )
    return run_monolithic_mga(
        model,
        case,
        output_path;
        groups=quantities,
        slacks=slacks,
        method=:random,
        iterations=iterations,
        random_seed=random_seed,
        random_distribution=:positive_uniform,
        pair_order=:max_min,
        write_detailed_results=write_detailed_results,
        detailed_output_writer=detailed_output_writer,
        continue_on_failure=continue_on_failure,
    )
end
