#!/bin/bash
#SBATCH --job-name=test_31prov
#SBATCH --output=logs/test_%j.out
#SBATCH --error=logs/test_%j.err
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=1
#SBATCH --mem=32G
#SBATCH --time=0:30:00
#SBATCH --mail-type=FAIL
#SBATCH --mail-user=lw3319@princeton.edu

module purge
module load julia/1.11.3
module load gurobi/11.0.3

cd "${SLURM_SUBMIT_DIR}"
mkdir -p logs
julia run_mga_della.jl
