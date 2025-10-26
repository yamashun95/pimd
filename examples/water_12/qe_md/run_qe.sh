#!/usr/bin/env bash
set -euo pipefail
rm -rf qe_outdir
rm -f *.ini *.out *.xyz log* fort.* monitor.out
mpirun -np 4 pimd.mpi.x >& monitor.out &
