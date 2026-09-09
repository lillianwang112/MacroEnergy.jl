# Monolithic MGA design

The MGA implementation is contained in `src/utilities/mga.jl`. It operates on
an already solved monolithic, perfect-foresight JuMP model.

## Input selection

Edges and storage components carry two input fields: `mga` selects the
component, and `mga_group` names the pathway quantity it contributes to. The
input loader stores these values before model generation. MGA connects them to
JuMP variables only after those variables have been created.

This keeps technology recognition in the case data. It avoids separate MGA
types, regular-expression matching, and duplicated asset-classification logic.
The selected edge determines the commodity and direction, so the same builder
can represent industrial output, sector-coupling flows, fuel consumption, and
carbon management.

## Quantity construction

`_mga_groups` dispatches to edge or storage construction according to the
requested measure. Groups retain their input name, location, investment
period, unit, contributing components, and JuMP expression. Transmission
corridors are recognized as node-to-node edges and retain their direction.

Annual activity applies representative-period weights. Cumulative activity
also multiplies by the investment-period length. Storage energy capacity uses
the storage vertex; storage charge and discharge power remain selectable on
their edges.

## Search and model reuse

`run_mga` records the least-cost objective, adds one cost-budget constraint,
and changes the objective for each alternative. One-at-a-time search brackets
every group. Random search minimizes and maximizes each seeded signed direction.
The original objective is restored and solved again even after an error.

Serial runs reuse the original model. Parallel runs create one JuMP clone per
Julia worker and map the original cost and MGA expressions to each clone. Each
worker processes several alternatives, avoiding one full model copy per solve.
The optimizer must be supplied because `JuMP.copy_model` intentionally does
not copy it. Full case outputs remain serial because the case stores references
to variables in the original model.

`solver_threads` controls threads inside each solver instance. It is separate
from `parallel_workers`, which controls the number of independent model clones.

## Ratios

`run_mga_ratio` combines selected groups into a numerator and denominator.
Dinkelbach iterations solve a sequence of linear objectives of the form
$N-qD$ and update $q=N/D$ until the residual is small. The implementation
requires a positive denominator and conservatively checks that both quantities
are built from nonnegative variables and coefficients.

## Output and scaling

MacroEnergy may scale model quantities before optimization. MGA converts JuMP
values back to the reporting scale and records the requested physical unit.
Definition tables identify which model components contributed to every group;
summary tables record status, cost-budget compliance, and objective values.
