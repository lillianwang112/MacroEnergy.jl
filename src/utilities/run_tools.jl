"""
    run_case(case_path; kwargs...) -> (case::Case, solution::Any)

Load, solve, and write results for a Macro case. This is the main entry point for running 
a complete Macro workflow.

# Arguments
- `case_path::AbstractString`: Path to the case directory containing `system_data.json`. 
  Defaults to `@__DIR__` (the directory of the calling script).

# Keyword Arguments

## Data Loading
- `lazy_load::Bool=true`: Whether to delay loading the input data until needed.

## Logging
- `log_level::LogLevel=Logging.Info`: Logging verbosity level (e.g., `Logging.Debug`, 
  `Logging.Info`, `Logging.Warn`, `Logging.Error`). **Note**: you need to import the `Logging` 
  module to change this parameter.
- `log_to_console::Bool=true`: Whether to print log messages to the console.
- `log_to_file::Bool=true`: Whether to write log messages to a file.
- `log_file_path::AbstractString`: Path to the log file. Defaults to `<case_path>/<case_name>.log`.
- `log_file_attribution::Bool=true`: Whether to include source file attribution in log messages.

## Optimizer (Monolithic/Myopic)
- `optimizer::DataType=HiGHS.Optimizer`: Optimizer constructor for Monolithic or Myopic algorithms.
- `optimizer_env::Any=nothing`: Optional optimizer environment.
- `optimizer_attributes::Tuple`: Solver-specific settings. Default: `("BarConvTol" => 1e-3, "Crossover" => 0, "Method" => 2)`.

## Optimizer (Benders)
- `planning_optimizer::DataType=HiGHS.Optimizer`: Optimizer constructor for the planning problem.
- `subproblem_optimizer::DataType=HiGHS.Optimizer`: Optimizer constructor for the subproblems.
- `planning_optimizer_attributes::Tuple`: Solver settings for the planning problem.
- `subproblem_optimizer_attributes::Tuple`: Solver settings for the subproblems.

## Monolithic MGA
- `run_mga::Bool=false`: Run Modeling to Generate Alternatives after the
  baseline monolithic solve.
- `mga_groups::Vector{MGAGroupSpec}`: Explicit variable groups to explore.
- `mga_slacks=[0.01, 0.05, 0.10]`: Fractional cost increases.
- `mga_method::Symbol=:one_at_a_time`: `:one_at_a_time` or `:random`.
- `mga_iterations::Int=100`: Number of directions for `:random`.
- `mga_random_seed::Int=42`: Reproducible random seed.
- `mga_write_detailed_results::Bool=true`: Write standard outputs per solution.
- `mga_output_writer::Function=write_outputs`: Detailed output function. Use
  `write_mga_capacity_outputs` for capacity-only sweeps.
- `mga_continue_on_failure::Bool=false`: Record and continue after a failed run.

# Returns
- `case::Case`: A case object containing a vector of solved system objects (one per period) and the case settings
- `solution`: The solution object (type depends on the solution algorithm: `Model` for 
  Monolithic, `MyopicResults` for Myopic (both Monolithic and Benders), `BendersModel`
  for Perfect Foresight + Benders). `MyopicResults.results` holds a `Vector` of per-period
  results when `ReturnModels=true`, or `nothing` when `ReturnModels=false`.
- `mga_results`: Returned as a third value only when `run_mga=true`. Contains
  the baseline objective, output path, summary table, group values, and directions.

# Examples

## Basic usage with HiGHS (default)
```julia
using MacroEnergy

(case, solution) = run_case(@__DIR__);
```

## Using Gurobi optimizer
```julia
using MacroEnergy
using Gurobi

(case, solution) = run_case(
    @__DIR__;
    optimizer=Gurobi.Optimizer,
    optimizer_attributes=("Method" => 2, "Crossover" => 0, "BarConvTol" => 1e-3)
);
```

## Benders decomposition with custom settings
```julia
using MacroEnergy
using Gurobi

(case, solution) = run_case(
    @__DIR__;
    planning_optimizer=Gurobi.Optimizer,
    subproblem_optimizer=Gurobi.Optimizer,
    planning_optimizer_attributes=("Method" => 2, "Crossover" => 0, "BarConvTol" => 1e-3),
    subproblem_optimizer_attributes=("Method" => 2, "Crossover" => 0, "BarConvTol" => 1e-3)
);
```

## Suppressing console output when running a case
```julia
using MacroEnergy
using Logging

(case, solution) = run_case(
    case_path;
    log_to_console=false,
    log_level=Logging.Warn
);
```

## Monolithic MGA
```julia
groups = [
    MGAGroupSpec("solar", r"^vCAP_.*solar.*_edge_"),
    MGAGroupSpec("onshore wind", r"^vCAP_.*onshore_wind.*_edge_"),
]

(case, model, mga) = run_case(
    case_path;
    run_mga=true,
    mga_groups=groups,
    mga_slacks=[0.01, 0.05, 0.10],
    mga_method=:one_at_a_time,
)
```

# Notes
- The solution algorithm (Monolithic, Myopic, or Benders) is determined by the 
  `SolutionAlgorithm` setting in the case's `settings/case_settings.json` file.
- For Myopic runs, results are written during iteration; no additional output writing 
  occurs after solving.
- For Benders with distributed processing enabled, worker processes are automatically 
  created and cleaned up.
"""
function run_case(
    case_path::AbstractString=@__DIR__;
    lazy_load::Bool=true,
    # Logging
    log_level::LogLevel=Logging.Info,
    log_to_console::Bool=true,
    log_to_file::Bool=true,
    log_file_path::AbstractString=joinpath(case_path, "$(basename(case_path)).log"),
    log_file_attribution::Bool=true,
    # Monolithic or Myopic
    optimizer::DataType=HiGHS.Optimizer,
    optimizer_env::Any=nothing,
    optimizer_attributes::Tuple=("solver" => "ipm", "run_crossover" => "off", "ipm_optimality_tolerance" => 1e-3),
    # Benders
    planning_optimizer::DataType=HiGHS.Optimizer,
    subproblem_optimizer::DataType=HiGHS.Optimizer,
    planning_optimizer_attributes::Tuple=("solver" => "ipm", "run_crossover" => "off", "ipm_optimality_tolerance" => 1e-3),
    subproblem_optimizer_attributes::Tuple=("solver" => "ipm", "run_crossover" => "on", "ipm_optimality_tolerance" => 1e-3),
    # Monolithic MGA
    run_mga::Bool=false,
    mga_groups::AbstractVector{MGAGroupSpec}=MGAGroupSpec[],
    mga_slacks::AbstractVector{<:Real}=[0.01, 0.05, 0.10],
    mga_method::Symbol=:one_at_a_time,
    mga_iterations::Integer=100,
    mga_random_seed::Integer=42,
    mga_write_detailed_results::Bool=true,
    mga_output_writer::Function=write_outputs,
    mga_continue_on_failure::Bool=false,
)
    # This will run when the Julia process closes. 
    # It may be overfill with the try-catch
    atexit(() -> try case_cleanup() catch; end)

    set_logger(log_to_console, log_to_file, log_level, log_file_path, log_file_attribution)

    # Wrapping the work in a try-catch to all for cleanup after errors
    try 
        @info("Running case at $(case_path)")

        setup_user_additions(case_path)
        load_user_additions(case_path)
        refresh_user_type_registries!()

        return Base.invokelatest(
            _run_case_impl,
            case_path,
            lazy_load,
            log_to_file,
            log_file_path,
            optimizer,
            optimizer_env,
            optimizer_attributes,
            planning_optimizer,
            subproblem_optimizer,
            planning_optimizer_attributes,
            subproblem_optimizer_attributes,
            run_mga,
            mga_groups,
            mga_slacks,
            mga_method,
            mga_iterations,
            mga_random_seed,
            mga_write_detailed_results,
            mga_output_writer,
            mga_continue_on_failure,
        )
    catch e
        rethrow(e)
    finally
        case_cleanup()  # Ensure all processes are removed
    end
end

function _run_case_impl(
    case_path::AbstractString,
    lazy_load::Bool,
    log_to_file::Bool,
    log_file_path::AbstractString,
    optimizer::DataType,
    optimizer_env,
    optimizer_attributes::Tuple,
    planning_optimizer::DataType,
    subproblem_optimizer::DataType,
    planning_optimizer_attributes::Tuple,
    subproblem_optimizer_attributes::Tuple,
    run_mga::Bool,
    mga_groups::AbstractVector{MGAGroupSpec},
    mga_slacks::AbstractVector{<:Real},
    mga_method::Symbol,
    mga_iterations::Integer,
    mga_random_seed::Integer,
    mga_write_detailed_results::Bool,
    mga_output_writer::Function,
    mga_continue_on_failure::Bool,
)
    case = load_case(case_path; lazy_load=lazy_load)

    # Inputs were scaled by `parameter_scaling_factor` inside `prepare_case!`
    # (during `load_case`). Restore them after solving/writing so the returned
    # System is in original units; the `finally` guarantees this even on error.
    scaling = parameter_scaling_factor(get_settings(case))
    try
        # Create optimizer based on solution algorithm
        optimizer_instance = if isa(solution_algorithm(case), Monolithic)
            create_optimizer(optimizer, optimizer_env, optimizer_attributes)
        elseif isa(solution_algorithm(case), Benders)
            create_optimizer_benders(planning_optimizer, subproblem_optimizer,
                planning_optimizer_attributes, subproblem_optimizer_attributes)
        else
            error("Unknown solution algorithm. Please check `SolutionAlgorithm` in `settings/case_settings.json`. Valid values are \"Monolithic\" and \"Benders\".")
        end

        # If Benders, create processes for subproblems optimization
        if isa(solution_algorithm(case), Benders)
            if case.settings.BendersSettings[:Distributed]
                number_of_subproblems = sum(length(system.time_data[:Electricity].subperiods) for system in case.systems)
                start_distributed_processes!(case_path, number_of_subproblems)
            end
        end

        case, solution = solve_case(case, optimizer_instance)

        postprocess!(case, solution)

        run_mga && !isa(solution_algorithm(case), Monolithic) && error(
            "Monolithic MGA requires `SolutionAlgorithm` to be `Monolithic`.",
        )
        run_mga && isa(solution, MyopicResults) && error(
            "Monolithic MGA currently requires a perfect-foresight solve.",
        )

        if isa(solution, MyopicResults)
            # Outputs already written per-period during iteration; just retrieve the output path for log file copying
            output_path = solution.output_path
        else
            output_path = length(case.systems) ≥ 1 ? create_output_path(case.systems[1], case_path) : case_path
            write_outputs(output_path, case, solution)
        end

        mga_results = if run_mga
            run_monolithic_mga(
                solution,
                case,
                output_path;
                groups=mga_groups,
                slacks=mga_slacks,
                method=mga_method,
                iterations=mga_iterations,
                random_seed=mga_random_seed,
                write_detailed_results=mga_write_detailed_results,
                detailed_output_writer=mga_output_writer,
                continue_on_failure=mga_continue_on_failure,
            )
        else
            nothing
        end

        if log_to_file && isfile(log_file_path)
            cp(log_file_path, joinpath(output_path, basename(log_file_path)); force=true)
        end

        if isa(solution_algorithm(case), Benders)
            if case.settings.BendersSettings[:Distributed] && nprocs() > 1
                rmprocs(workers())
            end
        end

        return run_mga ? (case, solution, mga_results) : (case, solution)
    finally
        unscale!(case, scaling)
    end
end

function case_cleanup()
    # Only remove distributed processes (workers beyond the main process)
    nprocs() > 1 && rmprocs(workers())
end
