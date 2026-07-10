struct TransportEmissions{T} <: AbstractAsset
    id::AssetId
    transport_transform::Transformation
    origin_edge::Edge{<:T}
    destination_edge::Edge{<:T}
    co2_edge::Edge{<:CO2}
end

TransportEmissions(
    id::AssetId,
    transport_transform::Transformation,
    origin_edge::Edge{T},
    destination_edge::Edge{T},
    co2_edge::Edge{<:CO2},
) where {T<:Commodity} =
    TransportEmissions{T}(id, transport_transform, origin_edge, destination_edge, co2_edge)

function default_data(t::Type{TransportEmissions}, id=missing, style="full")
    if style == "full"
        return full_default_data(t, id)
    else
        return simple_default_data(t, id)
    end
end

function full_default_data(::Type{TransportEmissions}, id=missing)
    return OrderedDict{Symbol,Any}(
        :id => id,
        :transforms => @transform_data(
            :timedata => missing,
            :distance => 0.0,
            :emission_factor => 0.0,
            :emission_rate => missing,
            :constraints => Dict{Symbol,Bool}(
                :BalanceConstraint => true,
            ),
        ),
        :edges => Dict{Symbol,Any}(
            :origin_edge => @edge_data(
                :commodity => missing,
                :has_capacity => false,
            ),
            :destination_edge => @edge_data(
                :commodity => missing,
                :has_capacity => false,
            ),
            :co2_edge => @edge_data(
                :commodity => "CO2",
                :has_capacity => false,
                :co2_sink => missing,
            ),
        ),
    )
end

function simple_default_data(::Type{TransportEmissions}, id=missing)
    return OrderedDict{Symbol,Any}(
        :id => id,
        :location => missing,
        :commodity => missing,
        :timedata => missing,
        :start_vertex => missing,
        :end_vertex => missing,
        :co2_sink => missing,
        :distance => 0.0,
        :emission_factor => 0.0,
        :emission_rate => missing,
        :variable_om_cost => 0.0,
    )
end

function set_commodity!(::Type{TransportEmissions}, commodity::Type{<:Commodity}, data::AbstractDict{Symbol,Any})
    edge_keys = [:origin_edge, :destination_edge]
    if haskey(data, :commodity)
        data[:commodity] = string(commodity)
    end
    if haskey(data, :edges)
        for edge_key in edge_keys
            if haskey(data[:edges], edge_key) && haskey(data[:edges][edge_key], :commodity)
                data[:edges][edge_key][:commodity] = string(commodity)
            end
        end
    end
    return nothing
end

function transport_emission_rate(transform_data::AbstractDict{Symbol,Any})
    emission_rate = get(transform_data, :emission_rate, missing)
    if !ismissing(emission_rate)
        return emission_rate
    end
    return get(transform_data, :distance, 0.0) * get(transform_data, :emission_factor, 0.0)
end

function make(asset_type::Type{TransportEmissions}, data::AbstractDict{Symbol,Any}, system::System)
    id = AssetId(data[:id])
    location = as_symbol_or_missing(get(data, :location, missing))

    @setup_data(asset_type, data, id)

    transform_key = :transforms
    @process_data(
        transform_data,
        data[transform_key],
        [
            (data[transform_key], key),
            (data[transform_key], Symbol("transform_", key)),
            (data, Symbol("transform_", key)),
            (data, key),
        ]
    )

    origin_edge_key = :origin_edge
    @process_data(
        origin_edge_data,
        data[:edges][origin_edge_key],
        [
            (data[:edges][origin_edge_key], key),
            (data[:edges][origin_edge_key], Symbol("origin_", key)),
            (data, Symbol("origin_", key)),
            (data, key),
        ]
    )
    commodity_symbol = Symbol(origin_edge_data[:commodity])
    commodity = commodity_types()[commodity_symbol]

    timedata_symbol = if haskey(transform_data, :timedata) && !ismissing(transform_data[:timedata])
        Symbol(transform_data[:timedata])
    else
        commodity_symbol
    end

    transport_transform = Transformation(;
        id = Symbol(id, "_", transform_key),
        timedata = system.time_data[timedata_symbol],
        location = location,
        constraints = transform_data[:constraints],
    )

    @start_vertex(
        origin_start_node,
        origin_edge_data,
        commodity,
        [
            (origin_edge_data, :start_vertex),
            (data, :start_vertex),
            (data, :transport_origin),
            (data, :location),
        ],
    )
    origin_end_node = transport_transform
    origin_edge = Edge(
        Symbol(id, "_", origin_edge_key),
        origin_edge_data,
        system.time_data[commodity_symbol],
        commodity,
        origin_start_node,
        origin_end_node,
    )

    destination_edge_key = :destination_edge
    @process_data(
        destination_edge_data,
        data[:edges][destination_edge_key],
        [
            (data[:edges][destination_edge_key], key),
            (data[:edges][destination_edge_key], Symbol("destination_", key)),
            (data, Symbol("destination_", key)),
            (data, key),
        ]
    )
    destination_start_node = transport_transform
    @end_vertex(
        destination_end_node,
        destination_edge_data,
        commodity,
        [
            (destination_edge_data, :end_vertex),
            (data, :end_vertex),
            (data, :transport_dest),
            (data, :location),
        ],
    )
    destination_edge = Edge(
        Symbol(id, "_", destination_edge_key),
        destination_edge_data,
        system.time_data[commodity_symbol],
        commodity,
        destination_start_node,
        destination_end_node,
    )

    co2_edge_key = :co2_edge
    @process_data(
        co2_edge_data,
        data[:edges][co2_edge_key],
        [
            (data[:edges][co2_edge_key], key),
            (data[:edges][co2_edge_key], Symbol("co2_", key)),
            (data, Symbol("co2_", key)),
        ]
    )
    co2_start_node = transport_transform
    @end_vertex(
        co2_end_node,
        co2_edge_data,
        CO2,
        [(co2_edge_data, :end_vertex), (data, :co2_sink), (data, :location)],
    )
    co2_edge = Edge(
        Symbol(id, "_", co2_edge_key),
        co2_edge_data,
        system.time_data[:CO2],
        CO2,
        co2_start_node,
        co2_end_node,
    )

    transport_transform.balance_data = Dict(
        :transport => Dict(
            origin_edge.id => 1.0,
            destination_edge.id => 1.0,
        ),
        :emissions => Dict(
            origin_edge.id => transport_emission_rate(transform_data),
            co2_edge.id => 1.0,
        ),
    )

    return TransportEmissions(id, transport_transform, origin_edge, destination_edge, co2_edge)
end
