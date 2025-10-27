#!/usr/bin/env bash
# Build helper that prepares PIMD 2.7.0 with QE+n2p2 using Intel oneAPI compilers.
# 前提：このスクリプトと pimd.2.7.0.r2.tar.gz が同一ディレクトリにある
set -euo pipefail

# === 基本設定 ===
WORK_DIR="$(pwd)"
SCRIPT_WORK_DIR="${WORK_DIR}"
USER_ARCHIVE_PATH="${PIMD_ARCHIVE:-${PIMD_TAR:-}}"
USER_QE_VERSION="${PIMD_QE_VERSION:-}"
USER_LEGACY_MAKEFILE="${PIMD_LEGACY_MAKEFILE:-}"
USER_LEGACY_FCMP="${PIMD_LEGACY_FCMP:-}"
USER_LEGACY_CC="${PIMD_LEGACY_CC:-}"
FORCED_BUILD_MODE=""
ARCHIVE_GZ=""
ARCHIVE_TAR=""
BUILD_DIR="${WORK_DIR}/build"
MAKE_JOBS="${MAKE_JOBS:-$(nproc)}"

# oneAPI ルート（必要なら上書き）
: "${ONEAPI_ROOT:=/opt/intel/oneapi}"

# AENET 連携向けの入力（オプション）
AENET_ENABLE=0
AENET_SRC_PATH="${AENET_SRC:-${AENET_SOURCE:-}}"
AENET_TAR_PATH="${AENET_TAR:-${AENET_TARBALL:-${AENET_ARCHIVE:-}}}"
AENET_MAKEFILE_PATH="${AENET_MAKEFILE:-}"

# llvm-ar / llvm-ranlib の検出
AR_BIN_DEFAULT="$(command -v llvm-ar || true)"
RANLIB_BIN_DEFAULT="$(command -v llvm-ranlib || true)"
if [[ -z "${AR_BIN_DEFAULT}" && -d "${ONEAPI_ROOT}" ]]; then
  AR_BIN_DEFAULT="$(find "${ONEAPI_ROOT}" -type f -name llvm-ar 2>/dev/null | head -n1 || true)"
fi
if [[ -z "${RANLIB_BIN_DEFAULT}" && -d "${ONEAPI_ROOT}" ]]; then
  RANLIB_BIN_DEFAULT="$(find "${ONEAPI_ROOT}" -type f -name llvm-ranlib 2>/dev/null | head -n1 || true)"
fi
: "${AR_BIN:=${AR_BIN_DEFAULT:-}}"
: "${RANLIB_BIN:=${RANLIB_BIN_DEFAULT:-}}"

usage() {
  cat <<EOF
Usage:
  bash $(basename "$0") [--clean] [--debug]

Assumptions:
  - Current directory contains:
      ./$(basename "$0")
      ./pimd.2.7.0.r2.tar.gz

Env overrides:
  ONEAPI_ROOT=/opt/intel/oneapi
  MAKE_JOBS=$(nproc)
  AR_BIN=</path/to/llvm-ar>      RANLIB_BIN=</path/to/llvm-ranlib>
  EIGEN_INCLUDE=/usr/include/eigen3
  PIMD_ARCHIVE=/path/to/pimd.2.7.0.r2.tar.gz
  PIMD_QE_VERSION=6.3
  PIMD_LEGACY_MAKEFILE=makefiles/makefile.aenet.icex
  PIMD_LEGACY_FCMP=mpiifx
  PIMD_LEGACY_CC=icx
  AENET_SRC=/path/to/aenet-2.0.3 (directory)
  AENET_TAR=/path/to/aenet-2.0.3.tar.bz2
  AENET_MAKEFILE=makefiles/Makefile.ifort_mpi

Steps performed:
  1) Extract PIMD sources from the tarball
  2) Load oneAPI env (if available)
  3) Prepare toolchain (ifx/mpiifx, wrappers for ifort etc.)
  4) Bootstrap n2p2 (getandapply_patch.sh) and build libnnp*.a
  5) Download QE 6.3 zip if missing
  6) Configure & build via CMake
  7) Print artifacts

Options:
  --clean        Remove ./build and re-extract sources
  --debug        Enable shell tracing
  --tar <path>   Explicit PIMD source archive (.tar or .tar.gz)
  --qe-version <ver>  Override QE version used for downloads
  --legacy       Force legacy makefile-based build even if CMake is available
  --cmake        Force CMake-based build
  --legacy-makefile <path>  Override makefile used for legacy build
  --legacy-fcmp <compiler>  Override FCMP for legacy make build
  --legacy-cc <compiler>    Override CC for legacy make build
  --aenet        Enable AENET build (requires AENET_SRC or AENET_TAR)
  --aenet-src    Path to extracted aenet-2.0.3 sources (implies --aenet)
  --aenet-tar    Path to aenet-2.0.3.tar.bz2 archive (implies --aenet)
  --aenet-makefile <path>  Override makefile used for AENET build (relative to src_modified/)
EOF
  exit 0
}

resolve_aenet_root() {
  local base="$1"
  if [[ -d "${base}/src" && -d "${base}/lib" ]]; then
    ( cd "${base}" >/dev/null 2>&1 && pwd )
    return 0
  fi
  local candidate
  candidate="$(find "${base}" -maxdepth 1 -mindepth 1 -type d -name 'aenet-2.0.3' | head -n1 || true)"
  if [[ -n "${candidate}" && -d "${candidate}/src" && -d "${candidate}/lib" ]]; then
    ( cd "${candidate}" >/dev/null 2>&1 && pwd )
    return 0
  fi
  return 1
}

build_aenet_components() {
  local stage_dir="$1"
  local make_jobs="$2"
  local lib_dest="$3"
  local makefile_override="$4"

  local make_parallel_flag=()
  if [[ "${make_jobs}" =~ ^[0-9]+$ ]] && (( make_jobs > 1 )); then
    make_parallel_flag=(-j "${make_jobs}")
  fi

  echo "==> Applying AENET patches"
  ( cd "${stage_dir}" && ./apply_patch.sh )

  mkdir -p "${lib_dest}"

  echo "==> Building AENET L-BFGS-B library"
  if [[ -f "${stage_dir}/lib/Makefile" ]]; then
    pushd "${stage_dir}/lib" >/dev/null
    make clean || true
    if [[ ! -d Lbfgsb.3.0 ]]; then
      if [[ -f Lbfgsb.3.0.tar.gz ]]; then
        tar -xzf Lbfgsb.3.0.tar.gz
      else
        echo "ERROR: Lbfgsb.3.0 sources missing under ${stage_dir}/lib" >&2
        exit 1
      fi
    fi
    make "${make_parallel_flag[@]}" liblbfgsb.a
    if [[ -f liblbfgsb.a ]]; then
      cp liblbfgsb.a "${lib_dest}/liblbfgsb.a"
    else
      echo "ERROR: liblbfgsb.a not produced during AENET build" >&2
      exit 1
    fi
    popd >/dev/null
  else
    echo "ERROR: ${stage_dir}/lib/Makefile not found; cannot build liblbfgsb.a" >&2
    exit 1
  fi

  echo "==> Building AENET static library"
  local stage_src="${stage_dir}/src_modified"
  local makefile_rel

  if [[ -n "${makefile_override}" ]]; then
    if [[ -f "${stage_src}/${makefile_override}" ]]; then
      makefile_rel="${makefile_override}"
    elif [[ -f "${makefile_override}" ]]; then
      makefile_rel="${makefile_override}"
    else
      echo "ERROR: AENET makefile override ${makefile_override} not found" >&2
      exit 1
    fi
  elif [[ -f "${stage_src}/makefiles/Makefile.ifort_mpi" ]]; then
    makefile_rel="makefiles/Makefile.ifort_mpi"
  elif [[ -f "${stage_src}/makefiles/Makefile.options" ]]; then
    makefile_rel="makefiles/Makefile.options"
  else
    echo "ERROR: Could not locate a suitable AENET makefile in ${stage_src}/makefiles" >&2
    exit 1
  fi

  pushd "${stage_src}" >/dev/null
  local make_args=(-f "${makefile_rel}")
  if (( ${#make_parallel_flag[@]} )); then
    make_args+=("${make_parallel_flag[@]}")
  fi
  make -f "${makefile_rel}" clean || true
  make "${make_args[@]}" lib
  if [[ -f libaenet.a ]]; then
    cp libaenet.a "${lib_dest}/libaenet.a"
  else
    echo "ERROR: libaenet.a not produced during AENET build" >&2
    exit 1
  fi
  popd >/dev/null
}

abs_path() {
  python - "$1" <<'PY'
import os
import sys
print(os.path.abspath(sys.argv[1]))
PY
}

detect_archive_paths() {
  if [[ -n "${USER_ARCHIVE_PATH}" ]]; then
    local resolved
    resolved="$(abs_path "${USER_ARCHIVE_PATH}")"
    [[ -f "${resolved}" ]] || { echo "ERROR: Specified archive ${USER_ARCHIVE_PATH} not found" >&2; exit 1; }
    if [[ "${resolved}" == *.tar.gz ]]; then
      ARCHIVE_GZ="${resolved}"
      ARCHIVE_TAR="${resolved%.gz}"
    elif [[ "${resolved}" == *.tar ]]; then
      ARCHIVE_TAR="${resolved}"
      local gz_candidate="${resolved}.gz"
      [[ -f "${gz_candidate}" ]] && ARCHIVE_GZ="${gz_candidate}"
    else
      echo "ERROR: Unsupported archive extension for ${resolved}" >&2
      exit 1
    fi
    return
  fi

  local -a gz_candidates=()
  local -a tar_candidates=()

  mapfile -t gz_candidates < <(find "${WORK_DIR}" -maxdepth 1 -type f -name 'pimd*.tar.gz' -printf '%p\n' | sort)
  if (( ${#gz_candidates[@]} == 1 )); then
    ARCHIVE_GZ="${gz_candidates[0]}"
    ARCHIVE_TAR="${ARCHIVE_GZ%.gz}"
    return
  elif (( ${#gz_candidates[@]} > 1 )); then
    for candidate in "${gz_candidates[@]}"; do
      if [[ "$(basename "${candidate}")" == "pimd.2.7.0.r2.tar.gz" ]]; then
        ARCHIVE_GZ="${candidate}"
        ARCHIVE_TAR="${ARCHIVE_GZ%.gz}"
        return
      fi
    done
    echo "ERROR: Multiple pimd*.tar.gz archives found. Specify one with --tar." >&2
    for candidate in "${gz_candidates[@]}"; do
      echo "  $(basename "${candidate}")" >&2
    done
    exit 1
  fi

  mapfile -t tar_candidates < <(find "${WORK_DIR}" -maxdepth 1 -type f -name 'pimd*.tar' ! -name '*.tar.gz' -printf '%p\n' | sort)
  if (( ${#tar_candidates[@]} == 1 )); then
    ARCHIVE_TAR="${tar_candidates[0]}"
    local gz_candidate="${ARCHIVE_TAR}.gz"
    [[ -f "${gz_candidate}" ]] && ARCHIVE_GZ="${gz_candidate}"
    return
  elif (( ${#tar_candidates[@]} > 1 )); then
    echo "ERROR: Multiple pimd*.tar archives found. Specify one with --tar." >&2
    for candidate in "${tar_candidates[@]}"; do
      echo "  $(basename "${candidate}")" >&2
    done
    exit 1
  fi

  echo "ERROR: No pimd*.tar[.gz] archive located under ${WORK_DIR}" >&2
  echo "       Provide one via --tar or set PIMD_ARCHIVE." >&2
  exit 1
}

tar_topdir() {
  local archive="$1"
  python - "$archive" <<'PY'
import sys, tarfile
archive = sys.argv[1]
with tarfile.open(archive) as tf:
    for member in tf.getmembers():
        name = member.name.split('/', 1)[0]
        if name:
            print(name)
            break
PY
}

detect_legacy_qe_version() {
  local src_dir="$1"
  local override="$2"
  if [[ -n "${override}" ]]; then
    echo "${override}"
    return 0
  fi
  local patch_script="${src_dir}/lib/qe/apply_patch_qe.sh"
  if [[ -f "${patch_script}" ]]; then
    local detected
    detected="$(python - "$patch_script" <<'PY'
import os
import re
import sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='ignore') as fh:
    data = fh.read()
match = re.search(r'q-e-qe-([0-9A-Za-z_.-]+)', data)
if match:
    print(match.group(1))
PY
)"
    if [[ -n "${detected}" ]]; then
      echo "${detected}"
      return 0
    fi
  fi
  echo "6.2.1"
}

prepare_legacy_qe() {
  local src_dir="$1"
  local version="$2"
  local qe_dir="${src_dir}/lib/qe"
  local archive="${qe_dir}/qe-${version}.zip"
  local url="https://github.com/QEF/q-e/archive/refs/tags/qe-${version}.zip"

  [[ -d "${qe_dir}" ]] || return 0

  mkdir -p "${qe_dir}"
  if [[ ! -f "${archive}" ]]; then
    echo "==> Downloading QE ${version} archive"
    curl -L -o "${archive}" "${url}"
  fi

  local extracted="${qe_dir}/q-e-qe-${version}"
  if [[ ! -d "${extracted}" ]]; then
    command -v unzip >/dev/null 2>&1 || { echo "ERROR: unzip command not found but required for legacy QE preparation" >&2; exit 1; }
    echo "==> Unpacking QE ${version}"
    unzip -q "${archive}" -d "${qe_dir}"
  fi

  if [[ -x "${qe_dir}/apply_patch_qe.sh" ]]; then
    echo "==> Applying QE patches"
    ( cd "${qe_dir}" && ./apply_patch_qe.sh )
  fi
}

CLEAN=0
DEBUG=0
while (( $# )); do
  case "$1" in
    -h|--help) usage ;;
    --clean) CLEAN=1; shift; continue ;;
    --debug) DEBUG=1; shift; continue ;;
    --tar)
      (( $# >= 2 )) || { echo "ERROR: --tar requires a path argument" >&2; exit 1; }
      USER_ARCHIVE_PATH="$2"
      shift 2
      continue
      ;;
    --tar=*)
      USER_ARCHIVE_PATH="${1#*=}"
      shift
      continue
      ;;
    --qe-version)
      (( $# >= 2 )) || { echo "ERROR: --qe-version requires a value" >&2; exit 1; }
      USER_QE_VERSION="$2"
      shift 2
      continue
      ;;
    --qe-version=*)
      USER_QE_VERSION="${1#*=}"
      shift
      continue
      ;;
    --legacy)
      FORCED_BUILD_MODE="legacy"
      shift
      continue
      ;;
    --cmake)
      FORCED_BUILD_MODE="cmake"
      shift
      continue
      ;;
    --legacy-makefile)
      (( $# >= 2 )) || { echo "ERROR: --legacy-makefile requires a path argument" >&2; exit 1; }
      USER_LEGACY_MAKEFILE="$2"
      shift 2
      continue
      ;;
    --legacy-makefile=*)
      USER_LEGACY_MAKEFILE="${1#*=}"
      shift
      continue
      ;;
    --legacy-fcmp)
      (( $# >= 2 )) || { echo "ERROR: --legacy-fcmp requires a compiler argument" >&2; exit 1; }
      USER_LEGACY_FCMP="$2"
      shift 2
      continue
      ;;
    --legacy-fcmp=*)
      USER_LEGACY_FCMP="${1#*=}"
      shift
      continue
      ;;
    --legacy-cc)
      (( $# >= 2 )) || { echo "ERROR: --legacy-cc requires a compiler argument" >&2; exit 1; }
      USER_LEGACY_CC="$2"
      shift 2
      continue
      ;;
    --legacy-cc=*)
      USER_LEGACY_CC="${1#*=}"
      shift
      continue
      ;;
    --aenet) AENET_ENABLE=1; shift; continue ;;
    --aenet-src)
      (( $# >= 2 )) || { echo "ERROR: --aenet-src requires a path argument" >&2; exit 1; }
      AENET_ENABLE=1
      AENET_SRC_PATH="$2"
      shift 2
      continue
      ;;
    --aenet-src=*)
      AENET_ENABLE=1
      AENET_SRC_PATH="${1#*=}"
      shift
      continue
      ;;
    --aenet-tar)
      (( $# >= 2 )) || { echo "ERROR: --aenet-tar requires a path argument" >&2; exit 1; }
      AENET_ENABLE=1
      AENET_TAR_PATH="$2"
      shift 2
      continue
      ;;
    --aenet-tar=*)
      AENET_ENABLE=1
      AENET_TAR_PATH="${1#*=}"
      shift
      continue
      ;;
    --aenet-makefile)
      (( $# >= 2 )) || { echo "ERROR: --aenet-makefile requires a path argument" >&2; exit 1; }
      AENET_ENABLE=1
      AENET_MAKEFILE_PATH="$2"
      shift 2
      continue
      ;;
    --aenet-makefile=*)
      AENET_ENABLE=1
      AENET_MAKEFILE_PATH="${1#*=}"
      shift
      continue
      ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

if (( AENET_ENABLE )); then
  if [[ -z "${AENET_SRC_PATH}" && -z "${AENET_TAR_PATH}" ]]; then
    echo "ERROR: AENET requested but no sources specified. Use --aenet-src, --aenet-tar, or set AENET_SRC/AENET_TAR." >&2
    exit 1
  fi
fi

if (( DEBUG == 1 )); then set -x; fi

detect_archive_paths
if [[ -z "${ARCHIVE_TAR}" && -n "${ARCHIVE_GZ}" ]]; then
  ARCHIVE_TAR="${ARCHIVE_GZ%.gz}"
fi
[[ -n "${ARCHIVE_TAR}" ]] || { echo "ERROR: Internal error - archive tar path unresolved" >&2; exit 1; }
ARCHIVE_LABEL="$(basename "${ARCHIVE_TAR}")"

if [[ -n "${FORCED_BUILD_MODE}" ]]; then
  case "${FORCED_BUILD_MODE}" in
    cmake|legacy) ;;
    *) echo "ERROR: Unknown build mode ${FORCED_BUILD_MODE}; use --cmake or --legacy" >&2; exit 1 ;;
  esac
fi

# === 準備 ===
if [[ -n "${ARCHIVE_GZ}" && ! -f "${ARCHIVE_GZ}" ]]; then
  echo "ERROR: ${ARCHIVE_GZ} not found" >&2
  exit 1
fi

if (( CLEAN == 1 )); then
  rm -rf "${BUILD_DIR}"
  if [[ -f "${ARCHIVE_TAR}" ]]; then
    TOPDIR="$(tar_topdir "${ARCHIVE_TAR}")"
    [[ -n "${TOPDIR}" && -d "${WORK_DIR}/${TOPDIR}" ]] && rm -rf "${WORK_DIR:?}/${TOPDIR}"
  fi
fi

mkdir -p "${BUILD_DIR}"

# === 展開（.tar が無ければ .gz を解凍）===
if [[ ! -f "${ARCHIVE_TAR}" ]]; then
  if [[ -n "${ARCHIVE_GZ}" && -f "${ARCHIVE_GZ}" ]]; then
    echo "==> Ungzipping ${ARCHIVE_GZ}"
    gzip -dk "${ARCHIVE_GZ}"
  else
    echo "ERROR: ${ARCHIVE_TAR} not found and no corresponding .tar.gz available" >&2
    exit 1
  fi
fi

# tar のトップディレクトリ名を検出 (Python を利用して SIGPIPE を回避)
TOPDIR="$(
python - <<'PY' "${ARCHIVE_TAR}"
import sys, tarfile
archive = sys.argv[1]
with tarfile.open(archive) as tf:
    for member in tf.getmembers():
        name = member.name.split('/', 1)[0]
        if name:
            print(name)
            break
PY
)"
[[ -n "${TOPDIR}" ]] || { echo "ERROR: Failed to detect top directory in tar"; exit 1; }

if [[ ! -d "${WORK_DIR}/${TOPDIR}" ]]; then
  echo "==> Extracting ${ARCHIVE_TAR}"
  tar -xf "${ARCHIVE_TAR}" -C "${WORK_DIR}"
fi

if [[ -f "${WORK_DIR}/${TOPDIR}/CMakeLists.txt" ]]; then
  SRC_DIR="${WORK_DIR}/${TOPDIR}"
elif [[ -f "${WORK_DIR}/CMakeLists.txt" ]]; then
  SRC_DIR="${WORK_DIR}"
else
  SRC_DIR="${WORK_DIR}/${TOPDIR}"
fi
echo "==> Source tree: ${SRC_DIR}"

if [[ -n "${FORCED_BUILD_MODE}" ]]; then
  BUILD_MODE="${FORCED_BUILD_MODE}"
else
  if [[ -f "${SRC_DIR}/CMakeLists.txt" ]]; then
    BUILD_MODE="cmake"
  else
    BUILD_MODE="legacy"
  fi
fi
echo "==> Build mode: ${BUILD_MODE}"
case "${BUILD_MODE}" in
  cmake|legacy) ;;
  *) echo "ERROR: Unsupported build mode ${BUILD_MODE}" >&2; exit 1 ;;
esac

if (( AENET_ENABLE )); then
  echo "==> Preparing AENET sources"
  [[ -d "${SRC_DIR}/lib/aenet" ]] || { echo "ERROR: ${SRC_DIR}/lib/aenet not found (AENET requested)"; exit 1; }

  AENET_TMP_DIR=""
  AENET_SOURCE_ROOT=""

  if [[ -n "${AENET_SRC_PATH}" ]]; then
    [[ -d "${AENET_SRC_PATH}" ]] || { echo "ERROR: AENET_SRC path ${AENET_SRC_PATH} is not a directory" >&2; exit 1; }
    if ! AENET_SOURCE_ROOT="$(resolve_aenet_root "${AENET_SRC_PATH}")"; then
      echo "ERROR: Unable to locate aenet-2.0.3 sources (src/, lib/) under ${AENET_SRC_PATH}" >&2
      exit 1
    fi
  fi

  if [[ -z "${AENET_SOURCE_ROOT}" && -n "${AENET_TAR_PATH}" ]]; then
    [[ -f "${AENET_TAR_PATH}" ]] || { echo "ERROR: AENET_TAR file ${AENET_TAR_PATH} not found" >&2; exit 1; }
    AENET_TMP_DIR="$(mktemp -d "${SCRIPT_WORK_DIR}/.aenet_unpack.XXXXXX")"
    tar -xf "${AENET_TAR_PATH}" -C "${AENET_TMP_DIR}"
    if ! AENET_SOURCE_ROOT="$(resolve_aenet_root "${AENET_TMP_DIR}")"; then
      echo "ERROR: Extracted ${AENET_TAR_PATH} but src/ or lib/ not found" >&2
      exit 1
    fi
  fi

  if [[ -z "${AENET_SOURCE_ROOT}" ]]; then
    echo "ERROR: AENET sources could not be resolved. Provide --aenet-src or --aenet-tar." >&2
    exit 1
  fi

  AENET_STAGE_DIR="${SRC_DIR}/lib/aenet"
  AENET_STAGE_LIBDIR="${AENET_STAGE_DIR}/aenetlib"
  AENET_EXPECTED_BASENAME="aenet-2.0.3"
  AENET_EXPECTED_ROOT="${AENET_STAGE_LIBDIR}/${AENET_EXPECTED_BASENAME}"
  AENET_EXPECTED_TAR="${AENET_STAGE_LIBDIR}/${AENET_EXPECTED_BASENAME}.tar.bz2"

  rm -rf "${AENET_STAGE_DIR}/src" "${AENET_STAGE_DIR}/lib" "${AENET_EXPECTED_ROOT}"
  mkdir -p "${AENET_STAGE_DIR}" "${AENET_STAGE_LIBDIR}"

  rm -rf "${AENET_STAGE_DIR}/src_modified"

  cp -a "${AENET_SOURCE_ROOT}/src" "${AENET_STAGE_DIR}/src"
  cp -a "${AENET_SOURCE_ROOT}/lib" "${AENET_STAGE_DIR}/lib"

  cp -a "${AENET_SOURCE_ROOT}" "${AENET_EXPECTED_ROOT}"

  for lbfgsb_base in "${AENET_STAGE_DIR}/lib" "${AENET_EXPECTED_ROOT}/lib"; do
    if [[ -d "${lbfgsb_base}" ]]; then
      if [[ -f "${lbfgsb_base}/Lbfgsb.3.0.tar.gz" && ! -d "${lbfgsb_base}/Lbfgsb.3.0" ]]; then
        tar -xzf "${lbfgsb_base}/Lbfgsb.3.0.tar.gz" -C "${lbfgsb_base}"
      fi
    fi
  done

  if [[ -n "${AENET_TAR_PATH}" ]]; then
    cp -a "${AENET_TAR_PATH}" "${AENET_EXPECTED_TAR}"
  else
    tar -cjf "${AENET_EXPECTED_TAR}" -C "$(dirname "${AENET_SOURCE_ROOT}")" "$(basename "${AENET_SOURCE_ROOT}")"
  fi

  chmod +x "${AENET_STAGE_DIR}/apply_patch.sh"

  if [[ -n "${AENET_TMP_DIR}" && -d "${AENET_TMP_DIR}" ]]; then
    rm -rf "${AENET_TMP_DIR}"
  fi

  echo "==> AENET sources staged under ${AENET_STAGE_DIR}"
fi

# n2p2 / QE の相対パス（アーカイブ標準構成を想定）
N2P2_ROOT="${SRC_DIR}/lib/n2p2"
N2P2_MOD="${N2P2_ROOT}/n2p2-2.2.0.modified"
QE_DIR="${SRC_DIR}/lib/qe"
if [[ "${BUILD_MODE}" == "cmake" ]]; then
  QE_VERSION="${USER_QE_VERSION:-6.3}"
else
  QE_VERSION="$(detect_legacy_qe_version "${SRC_DIR}" "${USER_QE_VERSION}")"
fi
QE_ARCHIVE="${QE_DIR}/qe-${QE_VERSION}.zip"
QE_URL="https://github.com/QEF/q-e/archive/refs/tags/qe-${QE_VERSION}.zip"

# === oneAPI 環境 ===
set +u
source "${ONEAPI_ROOT}/setvars.sh" --force >/dev/null 2>&1 || true
set -u
WORK_DIR="${SCRIPT_WORK_DIR}"
BUILD_DIR="${WORK_DIR}/build"

# === oneAPI ランタイム用ライブラリパスの収集 ===
: "${ONEAPI_ROOT:=/opt/intel/oneapi}"
RPATH_CANDIDATES=(
  "${ONEAPI_ROOT}/compiler/latest/lib"
  "${ONEAPI_ROOT}/compiler/latest/lib/intel64"
  "${ONEAPI_ROOT}/compiler/latest/linux/lib"
  "${ONEAPI_ROOT}/compiler/latest/linux/lib/intel64"
  "${ONEAPI_ROOT}/compiler/2025.3/lib/intel64"
  "${ONEAPI_ROOT}/mkl/latest/lib/intel64"
  "${ONEAPI_ROOT}/mpi/latest/lib/release"
  "${ONEAPI_ROOT}/mpi/latest/libfabric/lib"
  "${ONEAPI_ROOT}/tbb/latest/lib/intel64/gcc4.8"
)
ONEAPI_RPATHS=()
for path_candidate in "${RPATH_CANDIDATES[@]}"; do
  [[ -d "${path_candidate}" ]] && ONEAPI_RPATHS+=("${path_candidate}")
done
if (( ${#ONEAPI_RPATHS[@]} )); then
  # de-duplicate while preserving order
  mapfile -t ONEAPI_RPATHS < <(printf '%s\n' "${ONEAPI_RPATHS[@]}" | awk '!seen[$0]++' || true)
  ONEAPI_RPATH_STR="$(IFS=:; echo "${ONEAPI_RPATHS[*]}")"
else
  ONEAPI_RPATH_STR=""
fi

# === ツールチェーン ===
WRAPPER_DIR="$(mktemp -d "${SCRIPT_WORK_DIR}/.toolchain_wrappers.XXXXXX")"
cleanup() {
  local status=$?
  [[ -n "${WRAPPER_DIR:-}" && -d "${WRAPPER_DIR}" ]] && rm -rf "${WRAPPER_DIR}"
  exit $status
}
trap 'cleanup' EXIT

create_wrapper() {
  local name="$1" target="$2"
  cat >"${WRAPPER_DIR}/${name}" <<EOF
#!/usr/bin/env bash
exec ${target} "\$@"
EOF
  chmod +x "${WRAPPER_DIR}/${name}"
}
create_wrapper ifort ifx
create_wrapper ifc ifx
create_wrapper mpiifort mpiifx
export PATH="${WRAPPER_DIR}:${PATH}"

# env
unset CC CXX FC
export I_MPI_F90=ifx
export I_MPI_FC=ifx
export I_MPI_F77=ifx
export CC=mpiicx
export CXX=mpiicpx
export FC=ifx
export F77=ifx
export F90=ifx
export FC_SERIAL=ifx
export MPIF90="mpiifx -fc=ifx"
export MPIF77=mpiifx
export CC_SERIAL=icx
[[ -n "${AR_BIN}" ]] && export AR="${AR_BIN}"
export ARFLAGS=rcs
[[ -n "${RANLIB_BIN}" ]] && export RANLIB="${RANLIB_BIN}"
: "${AR:=}"
: "${RANLIB:=}"
export CFLAGS="${CFLAGS:-} -include math.h"

echo "==> Toolchain:"
command -v ifx || true
command -v mpiifx || true
command -v mpiicx || true
[[ -n "${AR_BIN}" ]] && echo "  AR=${AR_BIN}" || echo "  AR will be inferred by make"
[[ -n "${RANLIB_BIN}" ]] && echo "  RANLIB=${RANLIB_BIN}" || echo "  RANLIB will be inferred by make"

if (( AENET_ENABLE )); then
  [[ -d "${AENET_STAGE_DIR:-}" ]] || { echo "ERROR: Internal error - AENET stage dir missing" >&2; exit 1; }
  build_aenet_components "${AENET_STAGE_DIR}" "${MAKE_JOBS}" "${SRC_DIR}/lib" "${AENET_MAKEFILE_PATH}"
fi

# === n2p2 の用意 ===
CMAKE_ENABLE_N2P2=0
if [[ "${BUILD_MODE}" == "cmake" ]]; then
  if [[ -d "${N2P2_ROOT}" ]]; then
    echo "==> Preparing n2p2"
    if [[ ! -d "${N2P2_MOD}" ]]; then
      echo "==> Running getandapply_patch.sh"
      [[ -x "${N2P2_ROOT}/getandapply_patch.sh" ]] || chmod +x "${N2P2_ROOT}/getandapply_patch.sh"
      if ( cd "${N2P2_ROOT}" && ./getandapply_patch.sh ); then
        :
      else
        echo "WARNING: getandapply_patch.sh failed; continuing without n2p2" >&2
      fi
    fi

    if [[ -d "${N2P2_MOD}" ]]; then
      echo "==> Building n2p2 static libraries"
      pushd "${N2P2_MOD}" >/dev/null
      make -C ./src/libnnp clean || true
      make -C ./src/libnnp COMP=intel PROJECT_CC=icpx PROJECT_MPICC=mpiicx \
        ${AR:+PROJECT_AR="${AR}"} ${RANLIB:+PROJECT_RANLIB="${RANLIB}"} \
        PROJECT_CFLAGS="-O3 -march=native -std=c++11"

      make -C ./src/libnnptrain clean || true
      make -C ./src/libnnptrain COMP=intel PROJECT_CC=icpx PROJECT_MPICC=mpiicx \
        ${AR:+PROJECT_AR="${AR}"} ${RANLIB:+PROJECT_RANLIB="${RANLIB}"} \
        PROJECT_CFLAGS="-O3 -march=native -std=c++11"

      make -C ./src/libnnpif clean || true
      make -C ./src/libnnpif COMP=intel PROJECT_CC=icpx PROJECT_MPICC=mpiicx \
        ${AR:+PROJECT_AR="${AR}"} ${RANLIB:+PROJECT_RANLIB="${RANLIB}"} \
        PROJECT_CFLAGS="-O3 -march=native -std=c++11"

      mkdir -p "${SRC_DIR}/lib"
      cp ./lib/libnnp*.a "${SRC_DIR}/lib/" || true
      popd >/dev/null
      CMAKE_ENABLE_N2P2=1
    else
      echo "==> n2p2 patched sources missing; skipping n2p2 build"
    fi
  else
    echo "==> n2p2 sources not found; skipping n2p2 build"
  fi
fi

# === QE アーカイブの用意 ===
if [[ "${BUILD_MODE}" == "cmake" ]]; then
  echo "==> Ensuring QE ${QE_VERSION} archive"
  mkdir -p "${QE_DIR}"
  if [[ ! -f "${QE_ARCHIVE}" ]]; then
    curl -L -o "${QE_ARCHIVE}" "${QE_URL}"
  fi
else
  prepare_legacy_qe "${SRC_DIR}" "${QE_VERSION}"
fi

# === CMake 構成・ビルド ===
if [[ "${BUILD_MODE}" == "cmake" ]]; then
  echo "==> Configuring CMake"
  rm -rf "${BUILD_DIR}"
  mkdir -p "${BUILD_DIR}"

  CMAKE_COMMON_ARGS=(
    -DMKLUSE=ON
    -DQE=ON
    "-DQEVERSION=${QE_VERSION}"
    "-DQEFILES=${QE_ARCHIVE}"
    -DCMAKE_C_COMPILER=mpiicx
    -DCMAKE_CXX_COMPILER=mpiicpx
    -DCMAKE_Fortran_COMPILER=mpiifx
  )
  if (( CMAKE_ENABLE_N2P2 )); then
    CMAKE_COMMON_ARGS+=(-DN2P2=ON)
  else
    CMAKE_COMMON_ARGS+=(-DN2P2=OFF)
  fi
  if [[ -n "${ONEAPI_RPATH_STR}" ]]; then
    RPATH_FLAG="-Wl,-rpath,${ONEAPI_RPATH_STR}"
    EXE_LD_FLAGS="${CMAKE_EXE_LINKER_FLAGS:-}"
    if [[ -n "${EXE_LD_FLAGS}" ]]; then
      EXE_LD_FLAGS="${EXE_LD_FLAGS} ${RPATH_FLAG}"
    else
      EXE_LD_FLAGS="${RPATH_FLAG}"
    fi
    FORTRAN_LINK_EXEC="${CMAKE_Fortran_LINK_EXECUTABLE:-<CMAKE_Fortran_COMPILER> <FLAGS> <CMAKE_Fortran_LINK_FLAGS> <LINK_FLAGS> <OBJECTS> -o <TARGET> <LINK_LIBRARIES>}"
    if [[ "${FORTRAN_LINK_EXEC}" != *"-Wl,-rpath"* ]]; then
      FORTRAN_LINK_EXEC="${FORTRAN_LINK_EXEC} ${RPATH_FLAG}"
    fi
    CMAKE_COMMON_ARGS+=(
      "-DCMAKE_BUILD_RPATH=${ONEAPI_RPATH_STR}"
      "-DCMAKE_INSTALL_RPATH=${ONEAPI_RPATH_STR}"
      -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON
      "-DCMAKE_EXE_LINKER_FLAGS=${EXE_LD_FLAGS}"
      "-DCMAKE_Fortran_LINK_EXECUTABLE=${FORTRAN_LINK_EXEC}"
    )
  fi

  if (( AENET_ENABLE )); then
    CMAKE_COMMON_ARGS+=(-DAENET=ON)
  fi

  cmake -S "${SRC_DIR}" -B "${BUILD_DIR}" "${CMAKE_COMMON_ARGS[@]}"

  echo "==> Building (jobs=${MAKE_JOBS})"
  cmake --build "${BUILD_DIR}" -- -j "${MAKE_JOBS}"

  echo "==> Staging binaries"
  mkdir -p "${BUILD_DIR}/bin"
  for bin in pimd.mpi.x pimd.x polymers.x; do
    if [[ -f "${BUILD_DIR}/${bin}" ]]; then
      cp "${BUILD_DIR}/${bin}" "${BUILD_DIR}/bin/${bin}"
    fi
  done

  echo "==> Artifacts (if present):"
  ( cd "${BUILD_DIR}" && ls -1 pimd.mpi.x pimd.x polymers.x 2>/dev/null || true )
else
  echo "==> Building via legacy makefiles"
  LEGACY_MAKEFILE="${USER_LEGACY_MAKEFILE:-makefiles/makefile.aenet.icex}"
  LEGACY_FCMP="${USER_LEGACY_FCMP:-mpiifx}"
  LEGACY_CC="${USER_LEGACY_CC:-icx}"

  if [[ "${LEGACY_MAKEFILE}" != /* ]]; then
    [[ -f "${SRC_DIR}/${LEGACY_MAKEFILE}" ]] || { echo "ERROR: Legacy makefile ${LEGACY_MAKEFILE} not found under ${SRC_DIR}" >&2; exit 1; }
  else
    [[ -f "${LEGACY_MAKEFILE}" ]] || { echo "ERROR: Legacy makefile ${LEGACY_MAKEFILE} not found" >&2; exit 1; }
  fi

  LEGACY_PARALLEL=()
  if [[ "${MAKE_JOBS}" =~ ^[0-9]+$ ]] && (( MAKE_JOBS > 1 )); then
    LEGACY_PARALLEL=(-j "${MAKE_JOBS}")
  fi

  echo "    makefile : ${LEGACY_MAKEFILE}"
  echo "    FCMP      : ${LEGACY_FCMP}"
  echo "    CC        : ${LEGACY_CC}"

  pushd "${SRC_DIR}" >/dev/null
  make -f "${LEGACY_MAKEFILE}" "${LEGACY_PARALLEL[@]}" clean || true
  make -f "${LEGACY_MAKEFILE}" "${LEGACY_PARALLEL[@]}" \
    ${LEGACY_FCMP:+FCMP=${LEGACY_FCMP}} \
    ${LEGACY_CC:+CC=${LEGACY_CC}} \
    ${AR:+AR=${AR}} \
    ${RANLIB:+RANLIB=${RANLIB}}
  popd >/dev/null

  mkdir -p "${BUILD_DIR}/bin"
  for bin in pimd.mpi.x pimd.x polymers.x; do
    if [[ -f "${SRC_DIR}/${bin}" ]]; then
      cp "${SRC_DIR}/${bin}" "${BUILD_DIR}/bin/${bin}"
    fi
  done

  echo "==> Artifacts (if present):"
  ( cd "${BUILD_DIR}/bin" && ls -1 pimd.mpi.x pimd.x polymers.x 2>/dev/null || true )
fi

echo "==> Done."