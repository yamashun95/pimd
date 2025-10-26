# PIMD 2.7.0 + QE 6.3 + n2p2 (optional AENET) — Manual Build Guide

This document explains how to **manually** build PIMD 2.7.0 with Quantum ESPRESSO (QE) coupling and n2p2,
optionally including AENET, **without using the provided shell script**. Commands are shown for
Intel oneAPI compilers (`ifx`, `mpiifx`, `icx`, `mpiicx`). Adjust paths and versions to your environment.

---

## 0. Scope & Assumptions

- You have the source archive: `pimd.2.7.0.r2.tar.gz`.
- You will unpack it into a working directory `WORK_DIR`.
- You want: PIMD core binaries, n2p2 static libraries, and QE 6.3 integrated via CMake.
- Optional: integrate **AENET 2.0.3** before configuring CMake.
- OS: Linux x86_64; compiler stack: Intel oneAPI 2024/2025 (ifx/icx/mpiifx/mpiicx).

> **Tip:** If your environment differs (e.g., GCC + OpenMPI), translate the compiler variables accordingly
> (e.g., `FC=mpif90`, `CC=mpicc`, `CXX=mpicxx`).

---

## 1. Prepare the workspace

```bash
# Choose a working directory (example)
export WORK_DIR="$HOME/pimd-manual"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Put the source archive here beforehand:
#   $WORK_DIR/pimd.2.7.0.r2.tar.gz
```

Unpack the tarball:

```bash
gzip -dk pimd.2.7.0.r2.tar.gz       # leaves pimd.2.7.0.r2.tar next to the .gz
tar -xf pimd.2.7.0.r2.tar
# Detect the top-level directory name (commonly 'pimd.2.7.0.r2')
ls -1
```

Set the source root (substitute the actual unpacked directory name if different):

```bash
export SRC_DIR="$WORK_DIR/pimd.2.7.0.r2"
```

---

## 2. Load Intel oneAPI toolchains

If installed under the default path:

```bash
# oneAPI init (ignore harmless warnings if components are not present)
source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 || true
```

Ensure compilers and MPI wrappers are visible:

```bash
command -v ifx    && ifx    --version
command -v mpiifx && mpiifx -V
command -v icx    && icx    --version
command -v mpiicx && mpiicx -V
```

Optional but recommended: prefer LLVM binutils if available:

```bash
export AR="$(command -v llvm-ar   || true)"
export RANLIB="$(command -v llvm-ranlib || true)"
export ARFLAGS=rcs
```

---

## 3. Choose compilers for CMake and sub-builds

Define canonical variables for the build:

```bash
# MPI wrappers for C/C++/Fortran
export CC=mpiicx
export CXX=mpiicpx
export FC=mpiifx

# Serial fallbacks (used by some makefiles)
export CC_SERIAL=icx
export FC_SERIAL=ifx

# Make sure QE uses ifx via mpiifx when it probes Fortran
export MPIF90="mpiifx -fc=ifx"
export MPIF77=mpiifx

# Some sources expect math.h available; force-include is harmless here
export CFLAGS="${CFLAGS:-} -include math.h"
```

> If QE attempts to use legacy `ifort`, create temporary wrappers that forward to `ifx`:
> ```bash
> mkdir -p "$WORK_DIR/wrappers"
> printf '#!/usr/bin/env bash\nexec ifx "$@"\n' > "$WORK_DIR/wrappers/ifort"
> printf '#!/usr/bin/env bash\nexec ifx "$@"\n' > "$WORK_DIR/wrappers/ifc"
> printf '#!/usr/bin/env bash\nexec mpiifx "$@"\n' > "$WORK_DIR/wrappers/mpiifort"
> chmod +x "$WORK_DIR/wrappers/"*
> export PATH="$WORK_DIR/wrappers:$PATH"
> ```

---

## 4. (Optional) Stage AENET 2.0.3 sources

If you plan to build with AENET support later, stage its sources **now** so the PIMD CMake
configuration can detect them correctly.

Assume you have either:
- Extracted AENET directory `AENET_SRC=/path/to/aenet-2.0.3` with subfolders `src/` and `lib/`, or
- An archive `aenet-2.0.3.tar.bz2`.

Create the staging area and copy sources under PIMD’s tree:

```bash
export AENET_SRC="/path/to/aenet-2.0.3"      # OR leave unset if using an archive
export AENET_TARBALL="/path/to/aenet-2.0.3.tar.bz2"

# PIMD's aenet integration folder
export AENET_STAGE_DIR="$SRC_DIR/lib/aenet"
mkdir -p "$AENET_STAGE_DIR"

# Clean previous stage (if any)
rm -rf "$AENET_STAGE_DIR/src" "$AENET_STAGE_DIR/lib" "$AENET_STAGE_DIR/src_modified"
mkdir -p "$AENET_STAGE_DIR/aenetlib"

if [[ -n "$AENET_SRC" && -d "$AENET_SRC/src" && -d "$AENET_SRC/lib" ]]; then
  cp -a "$AENET_SRC/src" "$AENET_STAGE_DIR/src"
  cp -a "$AENET_SRC/lib" "$AENET_STAGE_DIR/lib"
else
  # Use archive
  tar -xf "$AENET_TARBALL" -C "$AENET_STAGE_DIR/aenetlib"
  # Expect the extracted directory to be aenet-2.0.3
  cp -a "$AENET_STAGE_DIR/aenetlib/aenet-2.0.3/src" "$AENET_STAGE_DIR/src"
  cp -a "$AENET_STAGE_DIR/aenetlib/aenet-2.0.3/lib" "$AENET_STAGE_DIR/lib"
fi

# Unpack L-BFGS-B if needed
if [[ -f "$AENET_STAGE_DIR/lib/Lbfgsb.3.0.tar.gz" && ! -d "$AENET_STAGE_DIR/lib/Lbfgsb.3.0" ]]; then
  (cd "$AENET_STAGE_DIR/lib" && tar -xzf Lbfgsb.3.0.tar.gz)
fi

# Apply PIMD-provided patches (script lives in $SRC_DIR/lib/aenet)
chmod +x "$AENET_STAGE_DIR/apply_patch.sh"
(cd "$AENET_STAGE_DIR" && ./apply_patch.sh)
```

### 4.1 Build AENET static libraries (manual `make`)

Build the L-BFGS-B archive and AENET core archive:

```bash
# Build liblbfgsb.a
make -C "$AENET_STAGE_DIR/lib" clean || true
make -C "$AENET_STAGE_DIR/lib" liblbfgsb.a

# Build libaenet.a (choose an appropriate makefile; common default below)
AENET_MK="$AENET_STAGE_DIR/src_modified/makefiles/Makefile.ifort_mpi"
make -C "$AENET_STAGE_DIR/src_modified" -f "$AENET_MK" clean || true
make -C "$AENET_STAGE_DIR/src_modified" -f "$AENET_MK" lib

# Copy into PIMD's lib folder so CMake can find them
mkdir -p "$SRC_DIR/lib"
cp -a "$AENET_STAGE_DIR/lib/liblbfgsb.a" "$SRC_DIR/lib/"
cp -a "$AENET_STAGE_DIR/src_modified/libaenet.a" "$SRC_DIR/lib/"
```

> If your environment lacks `ifort`-style rules in the AENET makefiles, you can swap to another provided makefile
> (e.g. `Makefile.options`) and edit compiler variables to use `ifx/mpifx` as needed.

---

## 5. Bootstrap and build **n2p2** static libraries

PIMD vendors an n2p2 patch helper. Run it once to produce `n2p2-2.2.0.modified/`:

```bash
export N2P2_ROOT="$SRC_DIR/lib/n2p2"
chmod +x "$N2P2_ROOT/getandapply_patch.sh"
(cd "$N2P2_ROOT" && ./getandapply_patch.sh)

# Build libnnp*.a under the modified tree
export N2P2_MOD="$N2P2_ROOT/n2p2-2.2.0.modified"

# Clean previous builds (optional)
make -C "$N2P2_MOD/src/libnnp"      clean || true
make -C "$N2P2_MOD/src/libnnptrain" clean || true
make -C "$N2P2_MOD/src/libnnpif"    clean || true

# Build with Intel toolchain
make -C "$N2P2_MOD/src/libnnp"      COMP=intel PROJECT_CC=icpx PROJECT_MPICC=mpiicx ${AR:+PROJECT_AR="$AR"} ${RANLIB:+PROJECT_RANLIB="$RANLIB"} PROJECT_CFLAGS="-O3 -march=native -std=c++11"
make -C "$N2P2_MOD/src/libnnptrain" COMP=intel PROJECT_CC=icpx PROJECT_MPICC=mpiicx ${AR:+PROJECT_AR="$AR"} ${RANLIB:+PROJECT_RANLIB="$RANLIB"} PROJECT_CFLAGS="-O3 -march=native -std=c++11"
make -C "$N2P2_MOD/src/libnnpif"    COMP=intel PROJECT_CC=icpx PROJECT_MPICC=mpiicx ${AR:+PROJECT_AR="$AR"} ${RANLIB:+PROJECT_RANLIB="$RANLIB"} PROJECT_CFLAGS="-O3 -march=native -std=c++11"

# Stage the resulting static libraries where PIMD's CMake expects them
mkdir -p "$SRC_DIR/lib"
cp -a "$N2P2_MOD/lib/libnnp"*.a "$SRC_DIR/lib/"
```

---

## 6. Prepare Quantum ESPRESSO 6.3 archive

PIMD’s CMake expects a QE zip file at `"$SRC_DIR/lib/qe/qe-6.3.zip"`.

```bash
mkdir -p "$SRC_DIR/lib/qe"
if [[ ! -f "$SRC_DIR/lib/qe/qe-6.3.zip" ]]; then
  # If online:
  curl -L -o "$SRC_DIR/lib/qe/qe-6.3.zip" \
    "https://github.com/QEF/q-e/archive/refs/tags/qe-6.3.zip"
  # If offline: copy a previously downloaded zip here.
fi
```

---

## 7. Configure with CMake

Create a build directory and generate build files.

```bash
export BUILD_DIR="$WORK_DIR/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Optional RPATHs so the binaries find oneAPI runtimes without setting LD_LIBRARY_PATH
ONEAPI_RPATHS=""
for p in \
  "/opt/intel/oneapi/compiler/latest/lib" \
  "/opt/intel/oneapi/compiler/latest/lib/intel64" \
  "/opt/intel/oneapi/mkl/latest/lib/intel64" \
  "/opt/intel/oneapi/mpi/latest/lib/release" \
  "/opt/intel/oneapi/mpi/latest/libfabric/lib" \
  "/opt/intel/oneapi/tbb/latest/lib/intel64/gcc4.8"
do
  [[ -d "$p" ]] && ONEAPI_RPATHS="${ONEAPI_RPATHS:+$ONEAPI_RPATHS:}$p"
done

EXE_LD_FLAGS=""
if [[ -n "$ONEAPI_RPATHS" ]]; then
  EXE_LD_FLAGS="-Wl,-rpath,${ONEAPI_RPATHS}"
fi

cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DMKLUSE=ON \
  -DQE=ON \
  -DQEVERSION=6.3 \
  -DQEFILES="$SRC_DIR/lib/qe/qe-6.3.zip" \
  -DN2P2=ON \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER=mpiicx \
  -DCMAKE_CXX_COMPILER=mpiicpx \
  -DCMAKE_Fortran_COMPILER=mpiifx \
  ${ONEAPI_RPATHS:+-DCMAKE_BUILD_RPATH="$ONEAPI_RPATHS"} \
  ${ONEAPI_RPATHS:+-DCMAKE_INSTALL_RPATH="$ONEAPI_RPATHS"} \
  ${EXE_LD_FLAGS:+-DCMAKE_EXE_LINKER_FLAGS="$EXE_LD_FLAGS"}
```

> **If using AENET** and you have produced `libaenet.a` and `liblbfgsb.a` under `"$SRC_DIR/lib"`, CMake should detect it when `-DAENET=ON`
> is set (if your PIMD CMake has that option). You can add:
> ```bash
>   -DAENET=ON
> ```
> to the `cmake` command above.

---

## 8. Build

```bash
cmake --build "$BUILD_DIR" -- -j"$(nproc)"
```

If the build succeeds, expect binaries at `"$BUILD_DIR"` and/or `"$BUILD_DIR/bin"`:

```bash
ls -l "$BUILD_DIR"/pimd*.x "$BUILD_DIR"/polymers*.x 2>/dev/null || true
mkdir -p "$BUILD_DIR/bin"
for b in pimd.mpi.x pimd.x polymers.x; do
  [[ -f "$BUILD_DIR/$b" ]] && cp -a "$BUILD_DIR/$b" "$BUILD_DIR/bin/$b"
done
```

---

## 9. Quick run of the SiO₂ QE-coupled example (optional)

```bash
EXAMPLE_DIR="$SRC_DIR/examples/SiO2/qe_md"
RUN_DIR="$BUILD_DIR/run/SiO2_qe_md"
mkdir -p "$RUN_DIR"
cp -a "$EXAMPLE_DIR/." "$RUN_DIR/"
cd "$RUN_DIR"

# Adjust -np according to your machine
mpirun -np 2 "$BUILD_DIR/bin/pimd.mpi.x" < input.dat | tee run.log
```

Artifacts to look for include `standard.out`, `rdf.out`, `final.xyz`, `final.poscar`, etc.

---

## 10. Validation & diagnostics

- **Linker paths**:
  ```bash
  ldd "$BUILD_DIR/bin/pimd.mpi.x" | sort
  ```

- **Environment for MKL/oneAPI**: If runtime libraries are not found, either source `setvars.sh` before running or set:
  ```bash
  export LD_LIBRARY_PATH="/opt/intel/oneapi/compiler/latest/lib/intel64:/opt/intel/oneapi/mkl/latest/lib/intel64:$LD_LIBRARY_PATH"
  ```

- **Check QE fetch**: Ensure the zip exists and matches your network/offline policy:
  ```bash
  ls -lh "$SRC_DIR/lib/qe/qe-6.3.zip"
  ```

---

## 11. Troubleshooting

**Q1. `ifort` not found / QE tries legacy compilers**  
Create wrappers (Section 3) or ensure QE’s configure phase sees `mpiifx/ifx` in `PATH` first.

**Q2. `undefined reference` to MKL/mpi libraries at link**  
Re-run CMake after sourcing oneAPI. Also consider the RPATH approach (Section 7).

**Q3. `llvm-ar` / `llvm-ranlib` missing**  
Install them (package manager) or omit `AR/RANLIB` exports so GNU binutils are used.

**Q4. Segmentation fault during QE initialisation**  
Rebuild with debug flags and enable traceback:
```bash
export CFLAGS="$CFLAGS -O0"
export FFLAGS="$FFLAGS -O0 -check all -traceback"
export FCFLAGS="$FCFLAGS -O0 -check all -traceback"
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
# Re-run CMake and build
```
Verify that `qexsd_init_bands` and related interfaces were compiled with consistent toolchains.

**Q5. AENET makefiles expect `ifort`**  
Select or edit a makefile under `src_modified/makefiles/` to use `ifx/mpifx`; ensure `AR/RANLIB` are consistent.

---

## 12. Offline checklist

- Copy `qe-6.3.zip` into:  
  `"$SRC_DIR/lib/qe/qe-6.3.zip"`
- Ensure all third-party archives (AENET, L-BFGS-B) are locally staged.
- Skip any `curl`/network commands; everything else works with local files.

---

## 13. Quick reference (copy‑paste)

```bash
# 1) oneAPI
source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 || true

# 2) Compilers
export CC=mpiicx CXX=mpiicpx FC=mpiifx
export MPIF90="mpiifx -fc=ifx" MPIF77=mpiifx
export CC_SERIAL=icx FC_SERIAL=ifx
export CFLAGS="${CFLAGS:-} -include math.h"

# 3) Unpack PIMD
cd "$WORK_DIR"
gzip -dk pimd.2.7.0.r2.tar.gz
tar -xf pimd.2.7.0.r2.tar
export SRC_DIR="$WORK_DIR/pimd.2.7.0.r2"

# 4) n2p2
chmod +x "$SRC_DIR/lib/n2p2/getandapply_patch.sh"
(cd "$SRC_DIR/lib/n2p2" && ./getandapply_patch.sh)
make -C "$SRC_DIR/lib/n2p2/n2p2-2.2.0.modified/src/libnnp"      COMP=intel PROJECT_CC=icpx PROJECT_MPICC=mpiicx PROJECT_CFLAGS="-O3 -march=native -std=c++11"
make -C "$SRC_DIR/lib/n2p2/n2p2-2.2.0.modified/src/libnnptrain" COMP=intel PROJECT_CC=icpx PROJECT_MPICC=mpiicx PROJECT_CFLAGS="-O3 -march=native -std=c++11"
make -C "$SRC_DIR/lib/n2p2/n2p2-2.2.0.modified/src/libnnpif"    COMP=intel PROJECT_CC=icpx PROJECT_MPICC=mpiicx PROJECT_CFLAGS="-O3 -march=native -std=c++11"
mkdir -p "$SRC_DIR/lib" && cp -a "$SRC_DIR/lib/n2p2/n2p2-2.2.0.modified/lib/libnnp"*.a "$SRC_DIR/lib/"

# 5) QE zip
mkdir -p "$SRC_DIR/lib/qe"
# curl -L -o "$SRC_DIR/lib/qe/qe-6.3.zip" "https://github.com/QEF/q-e/archive/refs/tags/qe-6.3.zip"

# 6) CMake
export BUILD_DIR="$WORK_DIR/build"
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
  -DMKLUSE=ON -DQE=ON -DQEVERSION=6.3 -DQEFILES="$SRC_DIR/lib/qe/qe-6.3.zip" -DN2P2=ON \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER=mpiicx -DCMAKE_CXX_COMPILER=mpiicpx -DCMAKE_Fortran_COMPILER=mpiifx
cmake --build "$BUILD_DIR" -- -j"$(nproc)"
```

---

**End of document.**
