using Pkg
Pkg.activate("/Users/lillianwang/Documents/MacroEnergy.jl")
Pkg.develop(path="/Users/lillianwang/Documents/MacroEnergySolvers.jl")

using MacroEnergy
using Gurobi

(case, solution, mga_results, mga_vectors, mga_var_names) = MacroEnergy.run_case(
    @__DIR__;
    planning_optimizer=Gurobi.Optimizer,
    subproblem_optimizer=Gurobi.Optimizer,
    planning_optimizer_attributes=("Method" => 2, "Crossover" => 0, "BarConvTol" => 1e-3),
    subproblem_optimizer_attributes=("Method" => 2, "Crossover" => 1, "BarConvTol" => 1e-3),
    run_mga=true
)
