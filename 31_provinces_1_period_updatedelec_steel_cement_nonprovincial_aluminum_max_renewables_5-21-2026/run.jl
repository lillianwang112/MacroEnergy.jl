using Pkg
Pkg.activate("/Users/lillianwang/Documents/MacroEnergy.jl")

using Infiltrator
using MacroEnergy
using Gurobi
using JuMP

(system, model) = MacroEnergy.run_case(@__DIR__; 
                    optimizer=Gurobi.Optimizer,
                    optimizer_attributes=("Method" => 2, "Crossover" => 0, "BarConvTol" => 1e-3));

# Optimize the model

case = MacroEnergy.load_case(@__DIR__)
optim = MacroEnergy.create_optimizer(Gurobi.Optimizer, nothing, ("Method" => 2, "Crossover" => 0, "BarConvTol" => 1e-3))

model = MacroEnergy.generate_model(case, optim)

MacroEnergy.optimize!(model)

# Compute conflicts

MacroEnergy.compute_conflict!(model)
list_of_conflicting_constraints = MacroEnergy.ConstraintRef[];
for (F, S) in MacroEnergy.list_of_constraint_types(model)
    for con in MacroEnergy.JuMP.all_constraints(model, F, S)
        if MacroEnergy.JuMP.get_attribute(con, MacroEnergy.MOI.ConstraintConflictStatus()) == MacroEnergy.MOI.IN_CONFLICT
            push!(list_of_conflicting_constraints, con)
        end
    end
end
display(list_of_conflicting_constraints)

# Save the list of conflicting constraints to a text file
function clean_constraint_list(input_list::Vector{JuMP.ConstraintRef})
    seen_patterns = Set{String}()
    cleaned_list = String[] # We return strings for the text file

    for constraint in input_list
        line = string(constraint)
        normalized = replace(line, r"\[\d+\]" => "[]")
        if !(normalized in seen_patterns)
            push!(seen_patterns, normalized)
            push!(cleaned_list, line) 
        end
    end

    return cleaned_list
end

result = clean_constraint_list(list_of_conflicting_constraints)

open("conflicting_constraints.txt", "w") do io
    for item in result
        println(io, item)
    end
end