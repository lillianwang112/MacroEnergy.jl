using HiGHS
using JuMP

Test.@testset "GenX-equivalent MGA quantities" begin
    case_path = joinpath(@__DIR__, "test_small_case")
    case = MacroEnergy.load_case(case_path; lazy_load=true)
    optimizer = MacroEnergy.create_optimizer(
        HiGHS.Optimizer,
        nothing,
        ("solver" => "simplex",),
    )
    case, model = MacroEnergy.solve_case(case, optimizer)

    solar = GenXMGAResourceSpec(
        "solar",
        :Electricity;
        asset_types=["VRE"],
        asset_pattern=r"solar",
        location_pattern=r"^([A-Z]{2})_",
        capacity_unit="MW",
        activity_unit="MWh",
    )
    wind = GenXMGAResourceSpec(
        "onshore wind",
        :Electricity;
        asset_types=["VRE"],
        asset_pattern=r"onshore_wind",
        location_pattern=r"^([A-Z]{2})_",
        capacity_unit="MW",
        activity_unit="MWh",
    )

    capacity_quantities = genx_mga_quantities(
        case,
        [solar, wind];
        measure=:capacity,
    )
    Test.@test getfield.(capacity_quantities, :label) == [
        "solar | CT | period 1",
        "solar | MA | period 1",
        "onshore wind | CT | period 1",
        "onshore wind | ME | period 1",
    ]
    Test.@test all(==("MW"), getfield.(capacity_quantities, :unit))
    Test.@test all(quantity -> all(term -> term.measure == :capacity, quantity.terms), capacity_quantities)

    annual_quantities = genx_mga_quantities(
        case,
        [solar];
        measure=:annual_generation,
    )
    Test.@test getfield.(annual_quantities, :label) == [
        "solar | CT | period 1",
        "solar | MA | period 1",
    ]
    Test.@test all(==("MWh"), getfield.(annual_quantities, :unit))

    resolved_annual = MacroEnergy._resolve_mga_groups(model, annual_quantities)
    expected_by_location = Dict{String,Float64}()
    system = only(MacroEnergy.get_periods(case))
    edges, edge_asset_map = MacroEnergy.get_edges(system; return_ids_map=true)
    for edge in edges
        asset = edge_asset_map[MacroEnergy.id(edge)][]
        MacroEnergy.typesymbol(typeof(asset)) == :VRE || continue
        occursin(r"solar", string(MacroEnergy.id(asset))) || continue
        MacroEnergy.get_commodity_name(edge) == :Electricity || continue
        MacroEnergy.end_vertex(edge) isa MacroEnergy.Node || continue
        location = MacroEnergy._genx_resource_location(solar, edge, asset)
        expected_by_location[location] = sum(MacroEnergy.time_interval(edge)) do t
            weight = MacroEnergy.subperiod_weight(
                edge,
                MacroEnergy.current_subperiod(edge, t),
            )
            weight * JuMP.value(MacroEnergy.flow(edge, t))
        end
    end
    for group in resolved_annual
        location = only(unique(term.location for term in group.terms))
        Test.@test isapprox(
            JuMP.value(group.expression),
            expected_by_location[location];
            rtol=1e-10,
        )
    end

    run_result = run_genx_mga(
        model,
        case,
        mktempdir();
        resources=[solar],
        measure=:capacity,
        slacks=[0.01],
        iterations=1,
        random_seed=7,
        write_detailed_results=false,
    )
    Test.@test size(run_result.summary, 1) == 3
    Test.@test run_result.summary.optimization_sense == ["baseline", "max", "min"]
    Test.@test all(run_result.directions.coefficient .>= 0.0)
    Test.@test all(run_result.directions.coefficient .< 1.0)
    Test.@test run_result.directions[1:2, :coefficient] ==
        run_result.directions[3:4, :coefficient]

    Test.@test_throws ArgumentError genx_mga_quantities(
        case,
        [GenXMGAResourceSpec(
            "missing",
            :Electricity;
            asset_types=["VRE"],
            asset_pattern=r"does_not_exist",
        )],
    )
end
