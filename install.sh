#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QE_CONFIG="${QE_CONFIG:-f1}"
source "${SCRIPT_DIR}/config/${QE_CONFIG}.env"
read -ra QE_MODULE_LIST <<< "${QE_MODULES}"
read -ra QE_CONFIGURE_OPT_LIST <<< "${QE_CONFIGURE_OPTS}"
read -ra QE_TARGET_LIST <<< "${QE_TARGETS}"

PREFIX="${QE_PREFIX:-${HOME}/opt/qe-${QE_VERSION}}"
BUILD_ROOT="${QE_BUILD_DIR:-${HOME}/.cache/qe-install}"
SRC="${BUILD_ROOT}/q-e-${QE_VERSION}"
JOBS="${QE_JOBS:-${SLURM_CPUS_ON_NODE:-8}}"
FORCE=0
KEEP_BUILD=0

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { echo "error: $*" >&2; exit 1; }
trap 'echo "error: ${BASH_SOURCE[0]}:${LINENO}: command failed: ${BASH_COMMAND}" >&2' ERR

usage() {
    cat <<USAGE
Build Quantum ESPRESSO ${QE_VERSION} with the toolchain pinned in config/${QE_CONFIG}.env.

usage: $0 [--prefix DIR] [--jobs N] [--force] [--keep-build]

  --prefix DIR    install location (default: ${PREFIX})
  --jobs N        parallel make jobs (default: ${JOBS})
  --force         rebuild even if an identical install exists
  --keep-build    keep the source tree under ${BUILD_ROOT}
  -h, --help      this text

Environment overrides: QE_PREFIX, QE_BUILD_DIR, QE_JOBS, QE_CONFIG (config/<name>.env)
and every QE_* variable in config/${QE_CONFIG}.env.
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)     PREFIX="$2"; shift 2 ;;
            --jobs)       JOBS="$2"; shift 2 ;;
            --force)      FORCE=1; shift ;;
            --keep-build) KEEP_BUILD=1; shift ;;
            -h|--help)    usage; exit 0 ;;
            *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
}

compute_build_id() {
    printf 'qe=%s\nmodules=%s\ncc=%s f90=%s mpif90=%s\nfflags=%s\ncflags=%s\nconfigure=%s\ntargets=%s' \
        "${QE_GIT_SHA}" "${QE_MODULES}" "${QE_CC}" "${QE_F90}" "${QE_MPIF90}" \
        "${QE_FFLAGS}" "${QE_CFLAGS}" "${QE_CONFIGURE_OPTS}" "${QE_TARGETS}" \
        | sha256sum | cut -c1-16
}

install_is_current() {
    [[ ${FORCE} -eq 0 ]] \
        && [[ -x "${PREFIX}/bin/pw.x" ]] \
        && grep -qsx "build_id: ${BUILD_ID}" "${PREFIX}/manifest.txt"
}

start_logging() {
    mkdir -p "${PREFIX}" "${BUILD_ROOT}"
    exec > >(tee -a "${PREFIX}/install.log") 2>&1
    log "log: ${PREFIX}/install.log"
    log "prefix: ${PREFIX}  jobs: ${JOBS}  build_id: ${BUILD_ID}"
}

load_toolchain() {
    set +u
    if ! type module >/dev/null 2>&1; then
        [[ -r "${QE_MODULES_INIT}" ]] || die "Lmod init not found: ${QE_MODULES_INIT}"
        source "${QE_MODULES_INIT}"
    fi
    module purge
    local m
    for m in "${QE_MODULE_LIST[@]}"; do module load "${m}"; done
    module list 2>&1 | sed 's/^/    /'
    set -u
}

check_toolchain() {
    local tool
    for tool in "${QE_CC}" "${QE_F90}" "${QE_MPIF90}" git make; do
        command -v "${tool}" >/dev/null || die "${tool} not in PATH after loading modules"
    done
    [[ -n "${MKLROOT:-}" ]] || die "MKLROOT unset; MKL provides BLAS/LAPACK/ScaLAPACK/FFTW"
    "${QE_MPIF90}" -show | grep -q "^${QE_F90} " \
        || die "${QE_MPIF90} wraps $("${QE_MPIF90}" -show | cut -d' ' -f1), expected ${QE_F90}"
}

fetch_source() {
    if [[ ! -d "${SRC}/.git" ]]; then
        log "cloning ${QE_GIT_URL} tag qe-${QE_VERSION}"
        rm -rf "${SRC}"
        git -c advice.detachedHead=false clone --quiet --depth 1 --branch "qe-${QE_VERSION}" \
            --recurse-submodules --shallow-submodules "${QE_GIT_URL}" "${SRC}"
    fi
    git -C "${SRC}" reset -q --hard "${QE_GIT_SHA}" 2>/dev/null || true
    git -C "${SRC}" clean -qfdx
    git -C "${SRC}" submodule -q foreach --recursive 'git reset -q --hard && git clean -qfdx'
}

check_source_is_pinned() {
    HEAD_SHA="$(git -C "${SRC}" rev-parse HEAD)"
    [[ "${HEAD_SHA}" == "${QE_GIT_SHA}" ]] \
        || die "tag qe-${QE_VERSION} resolves to ${HEAD_SHA}, expected ${QE_GIT_SHA}"
    git -C "${SRC}" submodule status | sed 's/^/    submodule /'
}

configure_source() {
    log "configure"
    ./configure --prefix="${PREFIX}" "${QE_CONFIGURE_OPT_LIST[@]}" \
        CC="${QE_CC}" F90="${QE_F90}" MPIF90="${QE_MPIF90}" \
        CFLAGS="${QE_CFLAGS}" FFLAGS="${QE_FFLAGS}" FOXFLAGS="${QE_FFLAGS}"
}

check_configure_used_mkl_and_mpi() {
    grep -E '^(BLAS|LAPACK|SCALAPACK)_LIBS|^DFLAGS' make.inc | sed 's/^/    /'
    grep -q -- '-D__DFTI' make.inc      || die "configure did not pick MKL FFT (__DFTI)"
    grep -q -- '-D__SCALAPACK' make.inc || die "configure did not pick ScaLAPACK"
    grep -q -- '-D__MPI' make.inc       || die "configure did not enable MPI"
}

build_and_install() {
    log "make -j${JOBS} ${QE_TARGETS}"
    make -j"${JOBS}" "${QE_TARGET_LIST[@]}"
    make install >/dev/null
    cp -f make.inc "${PREFIX}/make.inc"
}

write_env_sh() {
    cat > "${PREFIX}/env.sh" <<ENV
case \$- in *u*) _qe_u=1 ;; esac; set +u
if ! type module >/dev/null 2>&1; then source "${QE_MODULES_INIT}"; fi
module load ${QE_MODULE_LIST[*]}
[ -n "\${_qe_u:-}" ] && set -u; unset _qe_u
export QE_ROOT="${PREFIX}"
export PATH="${PREFIX}/bin:\${PATH}"
export OMP_NUM_THREADS="\${OMP_NUM_THREADS:-1}"
ENV
}

write_modulefile() {
    mkdir -p "${PREFIX}/modulefiles/qe"
    cat > "${PREFIX}/modulefiles/qe/${QE_VERSION}.lua" <<LUA
help([[Quantum ESPRESSO ${QE_VERSION}, build_id ${BUILD_ID}]])
whatis("Quantum ESPRESSO ${QE_VERSION}")
$(for m in "${QE_MODULE_LIST[@]}"; do echo "always_load(\"${m}\")"; done)
setenv("QE_ROOT", "${PREFIX}")
prepend_path("PATH", "${PREFIX}/bin")
setenv("OMP_NUM_THREADS", "1")
LUA
}

write_manifest() {
    {
        echo "build_id: ${BUILD_ID}"
        echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "host: $(hostname)"
        echo "user: ${USER}"
        echo "qe_version: ${QE_VERSION}"
        echo "qe_git_url: ${QE_GIT_URL}"
        echo "qe_git_sha: ${HEAD_SHA}"
        echo "config: ${QE_CONFIG}"
        echo "installer_git_sha: $(git -C "${SCRIPT_DIR}" rev-parse HEAD 2>/dev/null || echo unknown)"
        echo "modules: ${QE_MODULES}"
        echo "cc: $("${QE_CC}" --version | head -1)"
        echo "f90: $("${QE_F90}" --version | head -1)"
        echo "mpif90: $("${QE_MPIF90}" -show | cut -c1-80)"
        echo "mklroot: ${MKLROOT}"
        echo "fflags: ${QE_FFLAGS}"
        echo "cflags: ${QE_CFLAGS}"
        echo "configure_opts: ${QE_CONFIGURE_OPTS}"
        echo "targets: ${QE_TARGETS}"
        echo "binaries:"
        (cd "${PREFIX}/bin" && sha256sum ./*.x | sed 's/^/  /')
    } > "${PREFIX}/manifest.txt"
}

smoke_test_pw() {
    [[ -x "${PREFIX}/bin/pw.x" ]] || die "pw.x missing after install"
    local banner
    banner="$(timeout 60 "${PREFIX}/bin/pw.x" </dev/null 2>/dev/null | grep -m1 'Program PWSCF' || true)"
    [[ "${banner}" == *"v.${QE_VERSION}"* ]] || die "pw.x banner mismatch: '${banner}'"
    log "smoke: ${banner#*Program }"
}

print_next_steps() {
    log "installed Quantum ESPRESSO ${QE_VERSION} to ${PREFIX}"
    log "activate with:  source ${PREFIX}/env.sh"
    log "or:             module use ${PREFIX}/modulefiles && module load qe/${QE_VERSION}"
    log "run with:       mpirun -np 8 pw.x -in your.scf.in"
    log "validate with:  ${SCRIPT_DIR}/verify.sh --prefix ${PREFIX}"
    log "build record:   ${PREFIX}/manifest.txt"
}

main() {
    parse_args "$@"
    BUILD_ID="$(compute_build_id)"
    if install_is_current; then
        log "identical install already present at ${PREFIX} (build_id ${BUILD_ID}); use --force to rebuild"
        log "activate with:  source ${PREFIX}/env.sh"
        exit 0
    fi
    start_logging
    load_toolchain
    check_toolchain
    fetch_source
    check_source_is_pinned
    cd "${SRC}"
    configure_source
    check_configure_used_mkl_and_mpi
    build_and_install
    write_env_sh
    write_modulefile
    write_manifest
    smoke_test_pw
    [[ ${KEEP_BUILD} -eq 1 ]] || rm -rf "${SRC}"
    print_next_steps
}

main "$@"
