#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
QE_CONFIG="${QE_CONFIG:-f1}"
source "${SCRIPT_DIR}/config/${QE_CONFIG}.env"

PREFIX="${QE_PREFIX:-${HOME}/opt/qe-${QE_VERSION}}"
NP="${QE_VERIFY_NP:-4}"
USE_SBATCH=0
ACCOUNT="${SBATCH_ACCOUNT:-}"
PARTITION="${SBATCH_PARTITION:-development}"
TOLERANCE_RY="1e-6"
WORK_ROOT="${QE_VERIFY_DIR:-${HOME}/.cache/qe-install/verify}"
REFERENCE_ENERGY="$(cat "${SCRIPT_DIR}/test/si.scf.ref")"

die() { echo "error: $*" >&2; exit 1; }

usage() {
    cat <<USAGE
Run a 2-atom Si SCF with the installed pw.x and compare the total energy with test/si.scf.ref.

usage: $0 [--prefix DIR] [--np N] [--sbatch [--account A] [--partition P]]

  --prefix DIR    install to test (default: ${PREFIX})
  --np N          MPI ranks (default: ${NP})
  --sbatch        submit through Slurm and wait, instead of mpirun on this node
  --account A     Slurm account (default: first account of ${USER})
  --partition P   Slurm partition (default: ${PARTITION})
  -h, --help      this text
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --prefix)    PREFIX="$2"; shift 2 ;;
            --np)        NP="$2"; shift 2 ;;
            --sbatch)    USE_SBATCH=1; shift ;;
            --account)   ACCOUNT="$2"; shift 2 ;;
            --partition) PARTITION="$2"; shift 2 ;;
            -h|--help)   usage; exit 0 ;;
            *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
        esac
    done
}

check_install_exists() {
    [[ -r "${PREFIX}/env.sh" ]] || die "no install at ${PREFIX}; run install.sh first"
}

prepare_work_dir() {
    mkdir -p "${WORK_ROOT}"
    WORK="$(mktemp -d "${WORK_ROOT}/run.XXXXXX")"
    trap 'rm -rf "${WORK}"' EXIT
    cp "${SCRIPT_DIR}/test/Si.pz-vbc.UPF" "${WORK}/"
    sed -e "s|@PSEUDO_DIR@|${WORK}|" -e "s|@OUTDIR@|${WORK}/tmp|" \
        "${SCRIPT_DIR}/test/si.scf.in" > "${WORK}/si.scf.in"
}

pw_command() {
    printf "set -e\nsource '%s/env.sh'\ncd '%s'\nmpirun -np %s pw.x -in si.scf.in > si.scf.out\n" \
        "${PREFIX}" "${WORK}" "${NP}"
}

run_on_this_node() {
    echo "running mpirun -np ${NP} pw.x on $(hostname)"
    bash -c "$(pw_command)"
}

run_through_slurm() {
    [[ -n "${ACCOUNT}" ]] || ACCOUNT="$(sacctmgr -n show assoc user="${USER}" format=account | awk 'NR==1{print $1}')"
    [[ -n "${ACCOUNT}" ]] || die "no Slurm account found for ${USER}; pass --account"
    echo "submitting to partition ${PARTITION}, account ${ACCOUNT}, ${NP} tasks"
    local jobid
    jobid="$(sbatch --parsable --job-name=qe-verify --account="${ACCOUNT}" --partition="${PARTITION}" \
        --nodes=1 --ntasks="${NP}" --time=00:10:00 --output="${WORK}/slurm.out" --wait \
        --wrap="$(pw_command)")"
    echo "job ${jobid} finished"
}

check_pw_finished() {
    [[ -s "${WORK}/si.scf.out" ]] || die "pw.x produced no output"
    grep -q 'JOB DONE' "${WORK}/si.scf.out" || { tail -20 "${WORK}/si.scf.out"; die "pw.x did not finish"; }
}

compare_total_energy() {
    local got diff within_tolerance
    got="$(grep -m1 '^!' "${WORK}/si.scf.out" | awk '{print $(NF-1)}')"
    diff="$(awk -v a="${got}" -v b="${REFERENCE_ENERGY}" 'BEGIN{d=a-b; if(d<0)d=-d; print d}')"
    within_tolerance="$(awk -v d="${diff}" -v t="${TOLERANCE_RY}" 'BEGIN{print (d<=t)?1:0}')"
    printf 'total energy: %s Ry   reference: %s Ry   |diff| = %s Ry\n' "${got}" "${REFERENCE_ENERGY}" "${diff}"
    grep -m1 'PWSCF.*WALL' "${WORK}/si.scf.out" | sed 's/^ *//'
    [[ "${within_tolerance}" == 1 ]] || die "energy differs from reference by more than ${TOLERANCE_RY} Ry; see ${PREFIX}/manifest.txt for the build that produced it"
}

print_next_steps() {
    echo "PASS"
    echo "next: source ${PREFIX}/env.sh && mpirun -np ${NP} pw.x -in your.scf.in"
}

main() {
    parse_args "$@"
    check_install_exists
    prepare_work_dir
    if [[ ${USE_SBATCH} -eq 1 ]]; then run_through_slurm; else run_on_this_node; fi
    check_pw_finished
    compare_total_energy
    print_next_steps
}

main "$@"
