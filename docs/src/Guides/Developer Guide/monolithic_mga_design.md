# GenX-equivalent monolithic MGA design

This implementation adds GenX-style capacity and annual-generation MGA to a
perfect-foresight monolithic MacroEnergy model.

## Files

```text
src/utilities/mga_quantities.jl  What quantity is being optimized?
src/utilities/mga.jl             How is the MGA search performed safely?
src/utilities/mga_genx.jl        How is the GenX formulation represented in MacroEnergy?
```

`mga_quantities.jl` represents objectives such as capacity or annual generation
as named weighted sums of model variables and records which variables they use.
`mga.jl` is the general solve engine: it manages the cost budget, repeated
solves, status checks, outputs, and restoration of the original objective.
`mga_genx.jl` maps GenX resource groups onto MacroEnergy assets and defines the
GenX capacity, annual-generation, and paired-direction behavior.

This separation keeps the solving process independent of the objective being
explored. Budget enforcement and model restoration are implemented and tested
once, while other MGA formulations can reuse the same engine.

By default, MGA writes the standard MacroEnergy outputs for every accepted
alternative. Annual-generation totals are also recorded in
`mga_group_values.csv`. `write_mga_capacity_outputs` is an optional compact
writer for capacity studies that do not need operational outputs.

## Quantities and solve engine

`MGAQuantityTerm` stores a model variable, its multiplier, and the information
needed to identify it in the output files. `MGAQuantitySpec` combines these
terms into one weighted sum:

$$
Q(x)=\sum_i a_i x_i.
$$

`MGAGroupSpec` is a lower-level option that selects model variables by matching
their names. The GenX layer instead finds variables through MacroEnergy assets
and edges, so it does not depend on JuMP variable names.

The engine starts from an already solved model. For each slack $\epsilon$, it
adds

$$
f(x) \le z^* + \epsilon |z^*|.
$$

The constraint is rescaled internally to help the solver, without changing its
meaning. After each alternative, the engine evaluates the original objective
and checks the cost budget directly. The same model is reused for every
direction and slack.

Before returning, even after an error, the engine removes the temporary budget,
restores the original objective, and re-solves the baseline.

## Resource mapping

`GenXMGAResourceSpec` identifies which MacroEnergy assets belong to each GenX
resource group. An eligible edge must:

1. belong to a selected asset type, when types are specified;
2. match the optional asset and component patterns;
3. carry the selected commodity; and
4. be an asset-to-node output edge.

Variables are grouped by technology, location, and investment period. The
resulting groups are written to `mga_group_definitions.csv`.

## Capacity and annual generation

For resource group $r$, location $z$, and period $p$, capacity MGA uses

$$
P_{r,z,p}=\sum_{y\in Y(r,z,p)} C_y,
$$

where $C_y$ is available capacity rather than construction in that period.

Annual-generation MGA uses

$$
G_{r,z,p}=\sum_{y\in Y(r,z,p)}\sum_t \omega_{y,t}F_{y,t},
$$

where $F_{y,t}$ is output flow and $\omega_{y,t}$ tells how often each
representative time step occurs. MacroEnergy currently assumes one-hour time
steps, so no separate duration multiplier is needed.

## Directions and solve order

For each iteration, `run_genx_mga` draws one random number between zero and one
for each quantity. It maximizes and then minimizes that same set of numbers.
Thus `N` iterations attempt `2N` alternatives for each slack.

## Status and outputs

The engine records the quantity definitions, search directions, run settings,
solve summaries, and quantity values. Progress tables are updated after every
attempted solve. Detailed output is written only for accepted solutions that
pass the cost check.

Accepted statuses are `OPTIMAL` and `ALMOST_OPTIMAL`. A time-limit result is
recorded but is not accepted solely because the solver provides values.

Focused tests cover cost budgets and restoration, paired directions,
repeatable random numbers, capacity aggregation, weighted annual generation,
resource matching, and max-then-min solve order.
