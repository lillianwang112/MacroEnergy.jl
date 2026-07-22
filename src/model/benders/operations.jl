function generate_operation_subproblem(system::System,case_settings::NamedTuple,include_subproblem_slacks::Bool)

    model = Model()

    @variable(model, vREF == 1)

    model[:eVariableCost] = AffExpr(0.0)
    
    add_linking_variables!(system, model)

    linking_variables = name.(setdiff(all_variables(model), model[:vREF]))

    define_available_capacity!(system, model)

    operation_model!(system, model)

    if include_subproblem_slacks == true && !haskey(model, :myslack_max)
        @info("Adding slack variables to ensure subproblems are always feasible")
        slack_penalty = 2*maximum(coefficient(model[:eVariableCost],v) for v in all_variables(model))
        eq_cons_to_be_relaxed =  get_ldes_constraints_to_relax(system);
        less_ineq_cons_to_be_relaxed = get_policy_constraints_to_relax(system);
        greater_ineq_cons_to_be_relaxed = Vector{ConstraintRef}();
        add_slack_variables!(model,slack_penalty,eq_cons_to_be_relaxed,less_ineq_cons_to_be_relaxed,greater_ineq_cons_to_be_relaxed)
    end
    
    period_index = system.time_data[:Electricity].period_index

    period_lengths = collect(case_settings.PeriodLengths)

    discount_rate = case_settings.DiscountRate

    discount_factor = present_value_factor(discount_rate, period_lengths)
    
    opexmult = present_value_annuity_factor.(discount_rate, period_lengths)

    @objective(model, Min, discount_factor[period_index] * opexmult[period_index] * model[:eVariableCost])

    return model, linking_variables


end

function initialize_subproblem(system::Any,optimizer::Optimizer,case_settings::NamedTuple,include_subproblem_slacks::Bool)
    
    subproblem,linking_variables_sub = generate_operation_subproblem(system,case_settings,include_subproblem_slacks);

    set_optimizer(subproblem, optimizer)

    set_silent(subproblem)

    if system.settings.ConstraintScaling
        @info "Scaling constraints and RHS"
        scale_constraints!(subproblem)
    end

    return subproblem,linking_variables_sub
end

function initialize_local_subproblems!(system_local::Vector,subproblems_local::Vector{Dict{Any,Any}},local_indices::UnitRange{Int64},optimizer::Optimizer,case_settings::NamedTuple, include_subproblem_slacks)

    nW = length(system_local)

    for i=1:nW
		subproblem,linking_variables_sub = initialize_subproblem(system_local[i],optimizer,case_settings,include_subproblem_slacks::Bool);
        subproblems_local[i][:model] = subproblem;
        subproblems_local[i][:linking_variables_sub] = linking_variables_sub;
        subproblems_local[i][:subproblem_index] = local_indices[i];
        subproblems_local[i][:system_local] = system_local[i]
    end
end

function generate_subproblems(system_decomp::Vector,opt::Dict,case_settings::NamedTuple,distributed_bool::Bool,include_subproblem_slacks::Bool)
    
    if distributed_bool
        subproblems, linking_variables_sub = initialize_dist_subproblems!(system_decomp,opt,case_settings,include_subproblem_slacks)
    else
        subproblems, linking_variables_sub = initialize_serial_subproblems!(system_decomp,opt,case_settings,include_subproblem_slacks)
    end

    return subproblems, linking_variables_sub
end

function initialize_dist_subproblems!(system_decomp::Vector,opt::Dict,case_settings::NamedTuple,include_subproblem_slacks::Bool)

    ##### Initialize a distributed arrays of JuMP models
	## Start pre-solve timer
     
	subproblem_generation_time = time()
    diagnostics_enabled = lowercase(get(ENV, "MACROENERGY_DISTRIBUTED_BUILD_DIAG", "false")) in ("1", "true", "yes")

    distribute_start = time()
    subproblems_all = distribute([Dict() for i in 1:length(system_decomp)]);
    if diagnostics_enabled
        @info(
            "DIST_BUILD_DIAG phase=darray_ready " *
            "elapsed=$(round(time() - distribute_start, digits=6)) " *
            "workers=$(nworkers()) subproblems=$(length(system_decomp))"
        )
    end

    # Slice system_decomp into each worker's chunk on the controller *before* spawning,
    # so only that worker's own systems are serialized and sent over the wire. Referencing
    # the full system_decomp inside the @spawnat closure (the previous approach) captures
    # and ships the entire decomposed system to every worker, since Julia closures capture
    # whole variables, not the subset later indexed out of them.
    construction_tasks = Task[]
    for p in workers()
        indices_start = time()
        W_local = @fetchfrom p localindices(subproblems_all)[1];
        system_chunk = system_decomp[W_local];
        indices_elapsed = time() - indices_start
        first_index = isempty(W_local) ? 0 : first(W_local)
        last_index = isempty(W_local) ? 0 : last(W_local)

        push!(construction_tasks, @async let
            p = p
            W_local = W_local
            system_chunk = system_chunk
            indices_elapsed = indices_elapsed
            first_index = first_index
            last_index = last_index

            dispatch_start = time()
            if diagnostics_enabled
                @info(
                    "DIST_BUILD_DIAG phase=driver_dispatch worker=$p " *
                    "first=$first_index last=$last_index count=$(length(W_local)) " *
                    "indices_elapsed=$(round(indices_elapsed, digits=6)) epoch=$dispatch_start"
                )
            end

            worker_timing = @fetchfrom p begin
                remote_enter = time()

                optimizer_start = time()
                optimizer = create_optimizer(opt[:solver], opt_env(opt[:solver]), opt[:attributes])
                optimizer_ready = time()

                model_start = time()
                initialize_local_subproblems!(
                    system_chunk,
                    localpart(subproblems_all),
                    W_local,
                    optimizer,
                    case_settings,
                    include_subproblem_slacks,
                )
                model_ready = time()

                (
                    worker = myid(),
                    node = get(ENV, "SLURMD_NODENAME", get(ENV, "HOSTNAME", "unknown")),
                    remote_enter = remote_enter,
                    optimizer_seconds = optimizer_ready - optimizer_start,
                    model_seconds = model_ready - model_start,
                    worker_seconds = model_ready - remote_enter,
                )
            end

            driver_received = time()
            if diagnostics_enabled
                dispatch_to_driver = driver_received - dispatch_start
                transport_and_queue = dispatch_to_driver - worker_timing.worker_seconds
                @info(
                    "DIST_BUILD_DIAG phase=worker_complete worker=$(worker_timing.worker) " *
                    "node=$(worker_timing.node) first=$first_index last=$last_index " *
                    "dispatch_to_remote=$(round(worker_timing.remote_enter - dispatch_start, digits=6)) " *
                    "optimizer=$(round(worker_timing.optimizer_seconds, digits=6)) " *
                    "model=$(round(worker_timing.model_seconds, digits=6)) " *
                    "worker_total=$(round(worker_timing.worker_seconds, digits=6)) " *
                    "remote_to_driver=$(round(driver_received - worker_timing.remote_enter, digits=6)) " *
                    "dispatch_to_driver=$(round(dispatch_to_driver, digits=6)) " *
                    "transport_and_queue=$(round(transport_and_queue, digits=6))"
                )
            end
        end)
    end
    @sync for task in construction_tasks
        @async wait(task)
    end

	p_id = workers();
    np_id = length(p_id);

    linking_variables_sub = [Dict() for k in 1:np_id];

    linking_start = time()
    @sync for k in 1:np_id
        @async linking_variables_sub[k]= @fetchfrom p_id[k] get_local_linking_variables(localpart(subproblems_all))
    end

	linking_variables_sub = merge(linking_variables_sub...);
    if diagnostics_enabled
        @info(
            "DIST_BUILD_DIAG phase=linking_ready " *
            "elapsed=$(round(time() - linking_start, digits=6)) entries=$(length(linking_variables_sub))"
        )
    end

    ## Record pre-solver time
	subproblem_generation_time = time() - subproblem_generation_time
	@info("Distributed operational subproblems generation took $(round(subproblem_generation_time, digits=3)) seconds")

    return subproblems_all,linking_variables_sub

end

function initialize_serial_subproblems!(system_decomp::Vector,opt::Dict,case_settings::NamedTuple,include_subproblem_slacks::Bool)

    ##### Initialize a array of JuMP models
	## Start pre-solve timer

    optimizer = create_optimizer(opt[:solver], opt_env(opt[:solver]), opt[:attributes])

	subproblem_generation_time = time()

    subproblems_all = [Dict() for i in 1:length(system_decomp)];

    initialize_local_subproblems!(system_decomp,subproblems_all, 1:length(system_decomp),optimizer,case_settings,include_subproblem_slacks);

    linking_variables_sub = [get_local_linking_variables([subproblems_all[k]]) for k in 1:length(system_decomp)];
    linking_variables_sub = merge(linking_variables_sub...);

    ## Record pre-solver time
	subproblem_generation_time = time() - subproblem_generation_time
	@info("Serial subproblems generation took $subproblem_generation_time seconds")

    return subproblems_all,linking_variables_sub

end

function get_local_linking_variables(subproblems_local::Vector{Dict{Any,Any}})

    local_variables=Dict();

    for sp in subproblems_local
		w = sp[:subproblem_index];
        local_variables[w] = sp[:linking_variables_sub]
    end

    return local_variables


end

function add_slack_variables!(model::Model,
                            slack_penalty::Float64, 
                            eq_cons::Vector,
                            less_ineq_cons::Vector,
                            greater_ineq_cons::Vector)

    @variable(model, myslack_max >= 0)

    if !isempty(less_ineq_cons)
        for c in less_ineq_cons
            set_normalized_coefficient(c, myslack_max, -1)
        end
    end

    if !isempty(greater_ineq_cons)
        for c in greater_ineq_cons
            set_normalized_coefficient(c, myslack_max, 1)
        end
    end

    if !isempty(eq_cons)
        n = length(eq_cons)
        @variable(model, myslack_eq[1:n])
        for i in 1:n
            set_normalized_coefficient(eq_cons[i], myslack_eq[i], -1)
        end
        @constraint(model, [i in 1:n], myslack_eq[i] <= myslack_max)
        @constraint(model, [i in 1:n], -myslack_eq[i] <= myslack_max)
    end

    model[:eVariableCost] += slack_penalty * myslack_max

    return nothing
end

function compute_slack_penalty_value(system::System)
    x = 0.0;
    for n in system.locations
        if isa(n,Node) && !isempty(non_served_demand(n))
            w = subperiod_indices(n)[1]
            y = subperiod_weight(n, w) * maximum(price_non_served_demand(n,s) for s in segments_non_served_demand(n))
            if y>x
                x = y
            end
        end
    end 

    
    if x==0.0
        penalty = 1e3;
    else
        penalty = 2*x
    end

    @info ("Slack penalty value: $penalty")

    return penalty

end

function get_ldes_constraints_to_relax(system::System)
    balance_constraints = Vector{JuMPConstraint}();
    for a in system.assets
        for t in fieldnames(typeof(a))
            g = getfield(a,t);
            if isa(g,LongDurationStorage)
                for c in g.constraints
                    if isa(c, BalanceConstraint)
                        STARTS = [first(sp) for sp in subperiods(g)];
                        for i in keys(g.balance_data)
                            for t in STARTS
                                push!(balance_constraints, c.constraint_ref[i][t])
                            end
                        end
                    end
                    if isa(c, LongDurationStorageChangeConstraint)
                        for w in subperiod_indices(g)
                            push!(balance_constraints, c.constraint_ref[w])
                        end
                    end
                end
            end
        end
    end
    return balance_constraints
end


function get_policy_constraints_to_relax(system::System)
    policy_constraints = Vector{JuMPConstraint}();
    for n in system.locations
        if isa(n,Node) && isempty(n.price_unmet_policy)
            for c in n.constraints
                if isa(c, PolicyConstraint)
                    for w in subperiod_indices(n)
                        push!(policy_constraints, c.constraint_ref[w])
                    end
                end
            end
        end
    end 
    return policy_constraints
end

function update_with_subproblem_solutions!(subproblems::Union{Vector{Dict{Any, Any}},DistributedArrays.DArray}, results::NamedTuple, elastic_slack::Bool=false)

    # Use expect_feasible=false: the best planning solution is stored as Float64 in a Dict,
    # and tiny floating-point differences when re-fixing linking variables can render a
    # marginally feasible subproblem INFEASIBLE, crashing before any results are written.
    # Pass elastic_slack through so the Big-M penalty is active if it was during Benders.
    subop_sol = MacroEnergySolvers.solve_subproblems(subproblems, results.planning_sol, false, elastic_slack)

    results = (; results..., subop_sol = subop_sol)

    return nothing

end
