using HiGHS
using JuMP

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
            MGAGroupSpec("x capacity", r"^x$"),
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

    Test.@test_throws ArgumentError run_monolithic_mga(
        model,
        nothing,
        mktempdir();
        groups=[MGAGroupSpec("missing", r"does_not_exist")],
        write_detailed_results=false,
    )
end
