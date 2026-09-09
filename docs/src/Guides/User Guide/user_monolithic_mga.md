# Monolithic MGA

Modeling to Generate Alternatives (MGA) finds different system designs whose
cost remains near the least-cost result. If the least-cost objective is $z^*$
and the allowed cost increase is $\epsilon$, MGA imposes

$$
f(x) \le z^* + \epsilon |z^*|.
$$

The case must use the monolithic solution algorithm and perfect foresight.

## Select model components

Add the following fields to any edge that should participate:

```json
"mga": true,
"mga_group": "electrolytic hydrogen"
```

Use the same fields inside a storage block to select storage energy capacity.
Unmarked components are excluded. Group names should describe the pathway
quantity represented by the selected edge or storage component.

## Supported measures

`run_mga` supports:

| Measure | Quantity |
| --- | --- |
| `:capacity` | Available edge capacity |
| `:new_capacity` | Capacity built in the period |
| `:retired_capacity` | Capacity retired in the period |
| `:retrofitted_capacity` | Capacity converted through a retrofit |
| `:annual_activity` | Representative-time-weighted flow |
| `:cumulative_activity` | Weighted flow multiplied by the period length |
| `:storage_energy_capacity` | Available storage energy capacity |
| `:new_storage_energy_capacity` | Storage energy capacity built in the period |
| `:retired_storage_energy_capacity` | Storage energy capacity retired in the period |
| `:corridor_capacity` | Available capacity between two network nodes |
| `:new_corridor_capacity` | Corridor capacity built in the period |
| `:retired_corridor_capacity` | Corridor capacity retired in the period |
| `:annual_net_transfer` | Signed weighted flow along a corridor |
| `:cumulative_net_transfer` | Signed corridor flow multiplied by period length |

The activity measures work with any commodity. Selecting the appropriate edge
therefore covers electricity generation, industrial production, hydrogen
production, fuel use, emissions, carbon capture, and carbon injection without
separate MGA-specific asset types.

## Run MGA

Solve the least-cost model first, then call `run_mga`:

```julia
using MacroEnergy
using Gurobi

case = load_case("/path/to/case")
optimizer = create_optimizer(
    Gurobi.Optimizer,
    nothing,
    ("Method" => 2,),
)
case, model = solve_case(case, optimizer)

result = run_mga(
    model,
    case,
    "/path/to/results";
    measure=:annual_activity,
    unit="Mt/year",
    include_groups=["electrolytic hydrogen", "blue hydrogen"],
    slacks=[0.01, 0.05, 0.10],
)
```

`unit` must match the case data. MGA cannot infer a physical unit from a
numerical value.

The default `search=:one_at_a_time` minimizes and maximizes each
technology-location-period group. Use `search=:random` with `iterations` and
`random_seed` to explore paired signed random directions.

## Parallel alternatives

Independent alternatives can run on cloned JuMP models:

```julia
result = run_mga(
    model,
    case,
    "/path/to/results";
    measure=:capacity,
    unit="MW",
    parallel_workers=4,
    optimizer=optimizer,
    solver_threads=2,
    write_detailed_results=false,
)
```

Start Julia with at least the requested number of threads, for example
`julia --threads=4`. Each worker owns a model clone and may give its solver
`solver_threads` internal threads. For a serial run, set the thread count when
creating the optimizer. Avoid requesting more total cores than
`parallel_workers * solver_threads`.

Parallel mode writes MGA summary tables but not full MacroEnergy case outputs,
because the case object refers to variables in the original model. Rerun
selected alternatives serially when full outputs are needed.

## Ratios and shares

`run_mga_ratio` finds the minimum and maximum of a ratio using Dinkelbach
iterations. A share includes the numerator group in the denominator:

```julia
result = run_mga_ratio(
    model,
    case,
    "/path/to/results";
    name="solar share of wind and solar",
    numerator_groups=["solar"],
    denominator_groups=["solar", "onshore wind"],
    measure=:capacity,
    unit="MW",
    slacks=[0.01, 0.05],
)
```

The numerator and denominator must use nonnegative quantities with the same
unit. Signed net-transfer quantities are therefore unsuitable for ratios.

## Outputs

`run_mga` writes definitions, directions, solve summaries, and group values in
the `mga/` directory. `run_mga_ratio` writes the corresponding definition,
summary, and iteration tables in `mga_ratio/`. Serial runs write normal
MacroEnergy result folders by default. Set `write_detailed_results=false` to
write only the MGA tables.
