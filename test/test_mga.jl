using HiGHS
using JuMP
using CSV
using DataFrames
using JSON3

Test.@testset "Macro-native MGA" begin
    case_path = joinpath(@__DIR__, "test_small_case")
    case = MacroEnergy.load_case(case_path; lazy_load=true)
    optimizer = MacroEnergy.create_optimizer(
        HiGHS.Optimizer,
        nothing,
        ("solver" => "simplex", "threads" => 1),
    )
    case, model = MacroEnergy.solve_case(case, optimizer)

    capacity_groups = MacroEnergy._mga_groups(
        model,
        case;
        measure=:capacity,
        periods=nothing,
        include_groups=["solar", "onshore wind"],
        unit="MW",
    )
    Test.@test getfield.(capacity_groups, :label) == [
        "onshore wind | elec_CT | period 1",
        "onshore wind | elec_ME | period 1",
        "solar | elec_CT | period 1",
        "solar | elec_MA | period 1",
    ]

    for measure in (:new_capacity, :retired_capacity)
        groups = MacroEnergy._mga_groups(
            model,
            case;
            measure=measure,
            periods=nothing,
            include_groups=[:solar],
            unit="MW",
        )
        Test.@test length(groups) == 2
        Test.@test all(==(measure), getfield.(groups, :measure))
    end

    annual_groups = MacroEnergy._mga_groups(
        model,
        case;
        measure=:annual_activity,
        periods=nothing,
        include_groups=["solar", "onshore wind"],
        unit="MWh",
    )
    Test.@test getfield.(annual_groups, :label) == getfield.(capacity_groups, :label)

    expected_by_group = Dict{String,Float64}()
    system = only(MacroEnergy.get_periods(case))
    for edge in MacroEnergy.get_edges(system)
        MacroEnergy.mga(edge) || continue
        MacroEnergy.mga_group(edge) in (:solar, Symbol("onshore wind")) || continue
        group = string(MacroEnergy.mga_group(edge))
        location = MacroEnergy._mga_edge_location(edge)
        label = "$group | $location | period 1"
        expected_by_group[label] = get(expected_by_group, label, 0.0) +
            sum(MacroEnergy.time_interval(edge)) do t
                weight = MacroEnergy.subperiod_weight(
                    edge,
                    MacroEnergy.current_subperiod(edge, t),
                )
                weight * JuMP.value(MacroEnergy.flow(edge, t))
            end
    end
    for group in annual_groups
        Test.@test isapprox(
            JuMP.value(group.expression),
            expected_by_group[group.label];
            rtol=1e-10,
        )
    end

    fuel_groups = MacroEnergy._mga_groups(
        model,
        case;
        measure=:annual_activity,
        periods=nothing,
        include_groups=["natural gas use"],
        unit="MWh fuel",
    )
    Test.@test length(fuel_groups) == 3
    Test.@test all(==(:NaturalGas), [
        component.commodity
        for group in fuel_groups
        for component in group.components
    ])

    carbon_groups = MacroEnergy._mga_groups(
        model,
        case;
        measure=:annual_activity,
        periods=nothing,
        include_groups=["direct carbon emissions"],
        unit="tonnes CO2",
    )
    Test.@test length(carbon_groups) == 3
    Test.@test all(==(:CO2), [
        component.commodity
        for group in carbon_groups
        for component in group.components
    ])

    storage_groups = MacroEnergy._mga_groups(
        model,
        case;
        measure=:storage_energy_capacity,
        periods=nothing,
        include_groups=["battery energy"],
        unit="MWh",
    )
    Test.@test getfield.(storage_groups, :label) == [
        "battery energy | elec_CT | period 1",
        "battery energy | elec_MA | period 1",
        "battery energy | elec_ME | period 1",
    ]

    corridor_groups = MacroEnergy._mga_groups(
        model,
        case;
        measure=:corridor_capacity,
        periods=nothing,
        include_groups=["electric transmission"],
        unit="MW",
    )
    Test.@test getfield.(corridor_groups, :label) == [
        "electric transmission | elec_MA -> elec_CT | period 1",
        "electric transmission | elec_MA -> elec_ME | period 1",
    ]
    Test.@test getfield.(corridor_groups, :origin) == ["elec_MA", "elec_MA"]
    Test.@test getfield.(corridor_groups, :destination) == ["elec_CT", "elec_ME"]

    transfer_groups = MacroEnergy._mga_groups(
        model,
        case;
        measure=:annual_net_transfer,
        periods=nothing,
        include_groups=["electric transmission"],
        unit="MWh",
    )
    Test.@test length(transfer_groups) == 2
    Test.@test all(group -> only(group.components).term_count == 72, transfer_groups)

    run_result = run_mga(
        model,
        case,
        mktempdir();
        measure=:capacity,
        unit="MW",
        include_groups=["solar", "onshore wind"],
        slacks=[0.01],
        search=:random,
        iterations=1,
        random_seed=7,
        write_detailed_results=false,
    )
    Test.@test size(run_result.summary, 1) == 3
    Test.@test run_result.summary.optimization_sense == ["baseline", "min", "max"]
    group_count = length(capacity_groups)
    Test.@test run_result.directions[1:group_count, :coefficient] ==
        run_result.directions[group_count + 1:2group_count, :coefficient]
    Test.@test isapprox(JuMP.objective_value(model), run_result.baseline_objective; rtol=1e-8)

    definitions = CSV.read(
        joinpath(run_result.output_path, "mga_group_definitions.csv"),
        DataFrame,
    )
    Test.@test size(definitions, 1) == 4
    Test.@test Set(definitions.input_group) == Set(["solar", "onshore wind"])
    metadata = JSON3.read(read(
        joinpath(run_result.output_path, "mga_metadata.json"),
        String,
    ))
    Test.@test metadata.measure == "capacity"
    Test.@test metadata.search == "random"
    Test.@test metadata.solver_threads === nothing

    if Threads.nthreads() >= 2
        parallel_result = run_mga(
            model,
            case,
            mktempdir();
            measure=:capacity,
            unit="MW",
            include_groups=["solar", "onshore wind"],
            slacks=[0.01],
            search=:random,
            iterations=1,
            random_seed=7,
            parallel_workers=2,
            optimizer=optimizer,
            solver_threads=1,
            write_detailed_results=false,
        )
        Test.@test parallel_result.summary.optimization_sense ==
            ["baseline", "min", "max"]
        Test.@test all(parallel_result.summary.within_budget)
        Test.@test parallel_result.directions == run_result.directions
    end

    ratio_result = run_mga_ratio(
        model,
        case,
        mktempdir();
        numerator_groups=[:solar],
        denominator_groups=["solar", "onshore wind"],
        measure=:capacity,
        unit="MW",
        name="solar share of wind and solar",
        slacks=[0.01],
        write_detailed_results=false,
    )
    Test.@test size(ratio_result.summary, 1) == 3
    Test.@test all(ratio_result.summary.converged)
    Test.@test all(ratio_result.summary.within_budget)
    Test.@test all(x -> 0.0 <= x <= 1.0, ratio_result.summary.ratio_value)

    first_edge = first(filter(MacroEnergy.mga, MacroEnergy.get_edges(system)))
    first_group = MacroEnergy.mga_group(first_edge)
    first_edge.mga_group = missing
    Test.@test_throws ArgumentError MacroEnergy._mga_groups(
        model,
        case;
        measure=:capacity,
        periods=nothing,
        include_groups=nothing,
        unit="MW",
    )
    first_edge.mga_group = first_group

    Test.@test_throws ArgumentError run_mga(
        model,
        case,
        mktempdir();
        measure=:unsupported,
        unit="MW",
        write_detailed_results=false,
    )
    Test.@test_throws ArgumentError run_mga(
        model,
        case,
        mktempdir();
        measure=:capacity,
        unit="",
        write_detailed_results=false,
    )
end
