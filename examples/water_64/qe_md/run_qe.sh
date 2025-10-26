#!/usr/bin/env bash
set -euo pipefail
rm -rf qe_outdir
rm -f *.ini *.out *.xyz log* fort.* monitor.out
mpirun -np 8 pimd.mpi.x >& monitor.out &
