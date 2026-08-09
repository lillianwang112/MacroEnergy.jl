using HiGHS
using JuMP
using CSV
using DataFrames

struct MGATestCase
    settings::NamedTuple
end

MacroEnergy.get_settings(case::MGATestCase) = case.settings
MacroEnergy.postprocess!(::MGATestCase, ::JuMP.Model) = nothing

Test.@testset "Monolithic MGA" begin
    model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(model)
    JuMP.@variable(model, x >= 0)
    JuMP.@variable(model, y >= 0)
    JuMP.@constraint(model, x + y >= 1)
    JuMP.@objective(model, Min, x + 2y)
    JuMP.optimize!(model)

    output_path = mktempdir()
    result = run_monolithic_mga(
        model,
        nothing,
        output_path;
        groups=[
            MGAGroupSpec("  x capacity  ", r"^x$"; scale=2.0),
            MGAGroupSpec("y capacity", r"^y$"),
        ],
        slacks=[0.0, 0.1],
        method=:one_at_a_time,
        write_detailed_results=false,
    )

    Test.@test size(result.summary, 1) == 9
    Test.@test size(result.group_values, 1) == 18
    Test.@test all(result.summary.has_solution)
    Test.@test all(result.summary.accepted_status)
    Test.@test all(result.summary.within_budget)
    Test.@test all(result.summary.system_cost .<= result.summary.cost_budget .+ 1e-7)
    baseline_x = only(filter(
        row -> row.run_id == "baseline" && row.group == "x capacity",
        eachrow(result.group_values),
    ))
    Test.@test isapprox(baseline_x.value, 1.0; atol=1e-7)
    Test.@test isfile(joinpath(result.output_path, "mga_summary.csv"))
    Test.@test isfile(joinpath(result.output_path, "mga_group_values.csv"))
    Test.@test isfile(joinpath(result.output_path, "mga_directions.csv"))
    Test.@test isfile(joinpath(result.output_path, "mga_group_definitions.csv"))
    Test.@test isfile(joinpath(result.output_path, "mga_metadata.json"))

    # The baseline objective and solution are restored after MGA.
    Test.@test JuMP.objective_sense(model) == JuMP.MOI.MIN_SENSE
    Test.@test isapprox(JuMP.objective_value(model), 1.0; atol=1e-7)
    Test.@test isapprox(JuMP.value(x), 1.0; atol=1e-7)
    Test.@test isapprox(JuMP.value(y), 0.0; atol=1e-7)

    resolved_groups = MacroEnergy._resolve_mga_groups(
        model,
        [
            MGAGroupSpec("x capacity", r"^x$"; scale=2.0),
            MGAGroupSpec("y capacity", r"^y$"),
        ],
    )
    scaled_objective = MacroEnergy._mga_group_objective(resolved_groups, [1.0, 0.0])
    Test.@test JuMP.coefficient(scaled_objective, x) == 2.0
    Test.@test JuMP.coefficient(scaled_objective, y) == 0.0

    structured_spec = MGAQuantitySpec(
        "annual x activity",
        [MGAQuantityTerm(
            variable=x,
            coefficient=3.0,
            measure=:annual_activity,
            technology="TestTechnology",
            asset=:test_asset,
            component=:x_component,
            commodity=:Electricity,
            location="test_zone",
            period=1,
        )];
        unit="MWh",
    )
    structured_group = only(MacroEnergy._resolve_mga_groups(model, [structured_spec]))
    Test.@test JuMP.coefficient(structured_group.expression, x) == 3.0
    Test.@test structured_group.unit == "MWh"

    structured_result = run_monolithic_mga(
        model,
        nothing,
        mktempdir();
        groups=[structured_spec],
        slacks=[0.0],
        write_detailed_results=false,
    )
    structured_definitions = CSV.read(
        joinpath(structured_result.output_path, "mga_group_definitions.csv"),
        DataFrame,
    )
    Test.@test only(structured_definitions.coefficient) == 3.0
    Test.@test only(structured_definitions.measure) == "annual_activity"
    Test.@test only(structured_definitions.technology) == "TestTechnology"
    Test.@test only(structured_definitions.location) == "test_zone"
    Test.@test only(structured_definitions.period) == 1

    Test.@test combine_mga_quantities(
        "combined quantity",
        [structured_spec, structured_spec],
    ).terms == vcat(structured_spec.terms, structured_spec.terms)

    Test.@test MacroEnergy._mga_budget_row_scale(
        JuMP.objective_function(model, JuMP.AffExpr),
        1e13,
    ) == 1e3

    one_at_a_time = MacroEnergy._mga_directions(
        resolved_groups,
        :one_at_a_time,
        100,
        42,
    )
    Test.@test [(d.name, d.direction) for d in one_at_a_time] == [
        ("x capacity", "min"),
        ("x capacity", "max"),
        ("y capacity", "min"),
        ("y capacity", "max"),
    ]

    random_a = MacroEnergy._mga_directions(resolved_groups, :random, 3, 42)
    random_b = MacroEnergy._mga_directions(resolved_groups, :random, 3, 42)
    Test.@test length(random_a) == 6
    Test.@test getfield.(random_a, :coefficients) == getfield.(random_b, :coefficients)
    Test.@test [(d.name, d.direction) for d in random_a] == [
        ("random_1", "min"),
        ("random_1", "max"),
        ("random_2", "min"),
        ("random_2", "max"),
        ("random_3", "min"),
        ("random_3", "max"),
    ]
    Test.@test all(1:2:length(random_a)) do i
        random_a[i].coefficients == random_a[i + 1].coefficients
    end
    Test.@test all(random_a) do direction
        isapprox(sum(abs2, direction.coefficients), 1.0; atol=1e-12)
    end
    positive_random = MacroEnergy._mga_directions(
        resolved_groups,
        :random,
        2,
        42,
        :positive_uniform,
    )
    Test.@test length(positive_random) == 4
    Test.@test all(direction -> all(c -> 0.0 <= c < 1.0, direction.coefficients), positive_random)
    Test.@test positive_random[1].coefficients == positive_random[2].coefficients
    Test.@test positive_random[3].coefficients == positive_random[4].coefficients
    max_min = MacroEnergy._mga_directions(
        resolved_groups,
        :random,
        1,
        42,
        :positive_uniform,
        :max_min,
    )
    Test.@test getfield.(max_min, :direction) == ["max", "min"]
    Test.@test_throws DimensionMismatch MacroEnergy._mga_group_objective(
        resolved_groups,
        [1.0],
    )

    Test.@test_throws ArgumentError MGAGroupSpec("x", r"^x$"; scale=0.0)
    Test.@test_throws ArgumentError MGAGroupSpec("x", r"^x$"; scale=-1.0)
    Test.@test_throws ArgumentError MGAGroupSpec("x", r"^x$"; scale=big"1e10000")
    Test.@test_throws ArgumentError MGAQuantitySpec("empty", MGAQuantityTerm[])
    Test.@test_throws ArgumentError MGAQuantitySpec(
        "bad coefficient",
        [MGAQuantityTerm(variable=x, coefficient=Inf)],
    )

    anonymous = JuMP.@variable(model, lower_bound=0)
    Test.@test isempty(JuMP.name(anonymous))
    broad_group = only(MacroEnergy._resolve_mga_groups(
        model,
        [MGAGroupSpec("named variables", r".*")],
    ))
    Test.@test JuMP.coefficient(broad_group.expression, anonymous) == 0.0
    JuMP.optimize!(model)

    Test.@test_throws ArgumentError run_monolithic_mga(
        model,
        nothing,
        mktempdir();
        groups=[MGAGroupSpec("missing", r"does_not_exist")],
        write_detailed_results=false,
    )

    Test.@test_throws ArgumentError run_monolithic_mga(
        model,
        nothing,
        mktempdir();
        groups=[MGAGroupSpec("x", r"^x$")],
        slacks=[big"1e10000"],
        write_detailed_results=false,
    )

    scaled_case = MGATestCase((
        ParameterScaling=true,
        ParameterScalingFactor=10.0,
    ))
    scaled_result = run_monolithic_mga(
        model,
        scaled_case,
        mktempdir();
        groups=[MGAGroupSpec("x", r"^x$")],
        slacks=[0.0],
        write_detailed_results=false,
    )
    Test.@test scaled_result.baseline_objective == 100.0
    Test.@test all(==(100.0), scaled_result.summary.cost_budget)
    Test.@test only(filter(
        row -> row.run_id == "baseline",
        eachrow(scaled_result.group_values),
    )).value == 10.0

    continued_result = run_monolithic_mga(
        model,
        scaled_case,
        mktempdir();
        groups=[MGAGroupSpec("x", r"^x$")],
        slacks=[0.0],
        detailed_output_writer=(args...) -> error("test output failure"),
        continue_on_failure=true,
    )
    alternatives = filter(:run_id => !=("baseline"), continued_result.summary)
    Test.@test size(alternatives, 1) == 2
    Test.@test all(.!alternatives.output_written)
    Test.@test all(contains("test output failure"), alternatives.error)
    Test.@test isapprox(JuMP.objective_value(model), 1.0; atol=1e-7)

    large_model = JuMP.Model(HiGHS.Optimizer)
    JuMP.set_silent(large_model)
    JuMP.@variable(large_model, large_x >= 0)
    JuMP.@variable(large_model, large_y >= 0)
    JuMP.@constraint(large_model, large_x + large_y == 1)
    JuMP.@objective(large_model, Min, 1e13 * large_x + 2e13 * large_y)
    JuMP.optimize!(large_model)
    Test.@test MacroEnergy._mga_budget_row_scale(
        JuMP.objective_function(large_model, JuMP.AffExpr),
        1e13,
    ) == 1e13
    Test.@test MacroEnergy._mga_within_budget(9.0e9 + 2.0, 9.0e9, 100.0)
    Test.@test !MacroEnergy._mga_within_budget(9.0e9 + 20.0, 9.0e9, 100.0)

    large_result = run_monolithic_mga(
        large_model,
        nothing,
        mktempdir();
        groups=[MGAGroupSpec("large x", r"^large_x$")],
        slacks=[0.1],
        write_detailed_results=false,
    )
    minimum_x = only(filter(
        row -> row.direction_name == "large x" &&
            row.optimization_sense == "min",
        eachrow(large_result.group_values),
    ))
    Test.@test isapprox(minimum_x.value, 0.9; atol=1e-7)
    Test.@test all(large_result.summary.within_budget)
    Test.@test isapprox(JuMP.objective_value(large_model), 1e13; rtol=1e-10)
end
