using Distributed
using Gurobi
using MacroEnergy

function required_env(name::String)
    haskey(ENV, name) || error("Required environment variable $name is not set")
    return ENV[name]
end

function main()
    case_path = abspath(required_env("MACROENERGY_CASE_PATH"))
    subproblem_count = parse(Int, get(ENV, "MACROENERGY_DIAG_SUBPROBLEMS", "8"))
    subproblem_count > 0 || error("MACROENERGY_DIAG_SUBPROBLEMS must be positive")

    println("=== DISTRIBUTED BUILD DIAGNOSTIC ===")
    println("case_path=$case_path")
    println("requested_subproblems=$subproblem_count")
    println("julia_version=$(VERSION)")
    println("project=$(Base.active_project())")
    driver_host = get(ENV, "SLURMD_NODENAME", get(ENV, "HOSTNAME", "unknown"))
    println("driver_host=$driver_host")
    println("macroenergy_commit=$(readchomp(`git -C $(dirname(dirname(@__DIR__))) rev-parse HEAD`))")

    MacroEnergy.load_user_additions(case_path)
    MacroEnergy.refresh_user_type_registries!()

    load_stats = @timed MacroEnergy.load_case(case_path; lazy_load=true)
    case = load_stats.value
    println(
        "CASE_LOAD seconds=$(load_stats.time) gc=$(load_stats.gctime) " *
        "alloc_bytes=$(load_stats.bytes)"
    )

    decomposition_stats = @timed MacroEnergy.generate_decomposed_system(MacroEnergy.get_periods(case))
    all_systems = decomposition_stats.value
    subproblem_count <= length(all_systems) || error(
        "Requested $subproblem_count subproblems, but the case contains only $(length(all_systems))"
    )
    systems = all_systems[1:subproblem_count]
    all_systems = nothing
    GC.gc(true)
    println(
        "DECOMPOSE seconds=$(decomposition_stats.time) gc=$(decomposition_stats.gctime) " *
        "alloc_bytes=$(decomposition_stats.bytes) selected=$(length(systems))"
    )

    MacroEnergy.start_distributed_processes!(case_path, subproblem_count)
    nworkers() == subproblem_count || error(
        "Expected $subproblem_count workers, but started $(nworkers())"
    )

    optimizer = Dict(
        :solver => Gurobi.Optimizer,
        :attributes => (
            "Method" => 1,
            "NumericFocus" => 2,
            "DualReductions" => 0,
            "InfUnbdInfo" => 1,
            "Threads" => 1,
        ),
    )

    try
        build_stats = @timed MacroEnergy.initialize_dist_subproblems!(
            systems,
            optimizer,
            MacroEnergy.get_settings(case),
            false,
        )
        subproblems, linking_variables = build_stats.value
        println(
            "BUILD_COMPLETE seconds=$(build_stats.time) gc=$(build_stats.gctime) " *
            "alloc_bytes=$(build_stats.bytes) subproblems=$(length(subproblems)) " *
            "linking_entries=$(length(linking_variables))"
        )
        println("CONSTRUCTION_DIAGNOSTIC_COMPLETE")
    finally
        isempty(workers()) || rmprocs(workers())
    end
end

main()
