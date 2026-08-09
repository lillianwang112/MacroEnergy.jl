abstract type AbstractMGAQuantitySpec end

function _normalize_mga_label(label::AbstractString)
    clean_label = strip(String(label))
    isempty(clean_label) && throw(ArgumentError("An MGA quantity label cannot be empty."))
    return clean_label
end

function _normalize_mga_scale(scale::Real)
    scale_value = Float64(scale)
    isfinite(scale_value) && scale_value > 0 || throw(ArgumentError(
        "An MGA quantity scale must be finite and positive.",
    ))
    return scale_value
end

function _mga_location_from_pattern(asset, pattern::Regex)
    matched = match(pattern, string(id(asset)))
    isnothing(matched) && throw(ArgumentError(
        "MGA location pattern $pattern did not match asset `$(id(asset))`.",
    ))
    for capture in matched.captures
        !isnothing(capture) && return String(capture)
    end
    return String(matched.match)
end

"""
    MGAGroupSpec(label, pattern; scale=1.0, unit="model units")

Define a named group of JuMP variables for a Modeling to Generate Alternatives
(MGA) objective. `pattern` is matched against JuMP variable names.

`scale` normalizes the group when it is combined with other groups in an MGA
objective. It does not change the values reported for the group.

Groups may overlap. An overlapping variable contributes to every group that
matches it.
"""
struct MGAGroupSpec <: AbstractMGAQuantitySpec
    label::String
    pattern::Regex
    scale::Float64
    unit::String

    function MGAGroupSpec(
        label::AbstractString,
        pattern::Regex;
        scale::Real=1.0,
        unit::AbstractString="model units",
    )
        clean_unit = strip(String(unit))
        isempty(clean_unit) && throw(ArgumentError("An MGA quantity unit cannot be empty."))
        return new(
            _normalize_mga_label(label),
            pattern,
            _normalize_mga_scale(scale),
            clean_unit,
        )
    end
end

"""
    MGAQuantityTerm(variable; coefficient=1.0, metadata...)

Define one auditable term in a weighted MGA quantity. Metadata fields describe
the MacroEnergy object represented by `variable`; they do not affect the
objective coefficient.
"""
Base.@kwdef struct MGAQuantityTerm
    variable::JuMP.VariableRef
    coefficient::Float64 = 1.0
    measure::Union{Missing,Symbol} = missing
    technology::Union{Missing,String} = missing
    asset::Union{Missing,Symbol} = missing
    component::Union{Missing,Symbol} = missing
    commodity::Union{Missing,Symbol} = missing
    location::Union{Missing,String} = missing
    origin::Union{Missing,String} = missing
    destination::Union{Missing,String} = missing
    period::Union{Missing,Int} = missing
end

"""
    MGAQuantitySpec(label, terms; scale=1.0, unit="model units")

Define an MGA quantity as an auditable weighted sum of JuMP variables. This is
the structured interface used for time-weighted activity and metadata-based
capacity groups.
"""
struct MGAQuantitySpec <: AbstractMGAQuantitySpec
    label::String
    terms::Vector{MGAQuantityTerm}
    scale::Float64
    unit::String

    function MGAQuantitySpec(
        label::AbstractString,
        terms::AbstractVector{MGAQuantityTerm};
        scale::Real=1.0,
        unit::AbstractString="model units",
    )
        isempty(terms) && throw(ArgumentError("An MGA quantity requires at least one term."))
        all(term -> isfinite(term.coefficient) && !iszero(term.coefficient), terms) ||
            throw(ArgumentError("MGA quantity term coefficients must be finite and nonzero."))
        clean_unit = strip(String(unit))
        isempty(clean_unit) && throw(ArgumentError("An MGA quantity unit cannot be empty."))
        return new(
            _normalize_mga_label(label),
            collect(terms),
            _normalize_mga_scale(scale),
            clean_unit,
        )
    end
end

"""
    combine_mga_quantities(label, quantities; scale=1.0)

Combine same-unit structured quantities into one auditable MGA quantity. This
is useful for national or multi-technology totals.
"""
function combine_mga_quantities(
    label::AbstractString,
    quantities::AbstractVector{MGAQuantitySpec};
    scale::Real=1.0,
)
    isempty(quantities) && throw(ArgumentError(
        "At least one MGA quantity is required for aggregation.",
    ))
    units = unique(getfield.(quantities, :unit))
    length(units) == 1 || throw(ArgumentError(
        "Combined MGA quantities must use the same unit.",
    ))
    return MGAQuantitySpec(
        label,
        reduce(vcat, getfield.(quantities, :terms));
        scale=scale,
        unit=only(units),
    )
end
