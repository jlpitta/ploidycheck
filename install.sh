#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cat <<'BANNER'

██████╗  ██╗       ██████╗  ██╗ ██████╗  ██╗   ██╗  ██████╗ ██╗  ██╗ ███████╗  ██████╗ ██╗  ██╗
██╔══██╗ ██║      ██╔═══██╗ ██║ ██╔══██╗ ╚██╗ ██╔╝ ██╔════╝ ██║  ██║ ██╔════╝ ██╔════╝ ██║ ██╔╝
██████╔╝ ██║      ██║   ██║ ██║ ██║  ██║  ╚████╔╝  ██║      ███████║ █████╗   ██║      █████╔╝
██╔═══╝  ██║      ██║   ██║ ██║ ██║  ██║   ╚██╔╝   ██║      ██╔══██║ ██╔══╝   ██║      ██╔═██╗
██║      ███████╗ ╚██████╔╝ ██║ ██████╔╝    ██║    ╚██████╗ ██║  ██║ ███████╗ ╚██████╗ ██║  ██╗
╚═╝      ╚══════╝  ╚═════╝  ╚═╝ ╚═════╝     ╚═╝     ╚═════╝ ╚═╝  ╚═╝ ╚══════╝  ╚═════╝ ╚═╝  ╚═╝

                                by João Pitta and Beatriz Toscano

BANNER
echo "Instalador de ambiente"
echo ""

MINIFORGE_DIR="${HOME}/miniforge3"

bootstrap_miniforge() {
    echo "Nenhum gerenciador conda encontrado (mamba, micromamba ou conda)."
    echo "Instalando Miniforge3 em ${MINIFORGE_DIR}..."
    local arch installer_url tmp_installer
    arch="$(uname -m)"
    installer_url="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-${arch}.sh"
    tmp_installer="$(mktemp -t miniforge-installer-XXXXXX.sh)"
    curl -fsSL -o "${tmp_installer}" "${installer_url}"
    bash "${tmp_installer}" -b -p "${MINIFORGE_DIR}"
    rm -f "${tmp_installer}"
    # shellcheck disable=SC1091
    source "${MINIFORGE_DIR}/etc/profile.d/conda.sh"
    if [ -f "${MINIFORGE_DIR}/etc/profile.d/mamba.sh" ]; then
        # shellcheck disable=SC1091
        source "${MINIFORGE_DIR}/etc/profile.d/mamba.sh"
    fi
    echo "Miniforge3 instalado em ${MINIFORGE_DIR}."
    echo "Adicione ao seu ~/.bashrc para uso interativo futuro:"
    echo "  source ${MINIFORGE_DIR}/etc/profile.d/conda.sh"
    echo ""
}

# Antes de decidir que não há gerenciador nenhum (e sair instalando o
# Miniforge de novo), tenta achar uma instalação já existente que só não
# está no PATH desta sessão (ex: terminal novo depois de uma instalação
# anterior, sem source no .bashrc).
find_conda_sh() {
    for base in "${HOME}/miniforge3" "${HOME}/mambaforge" "${HOME}/miniconda3" "${HOME}/anaconda3"; do
        if [ -f "${base}/etc/profile.d/conda.sh" ]; then
            echo "${base}"
            return 0
        fi
    done
    return 1
}

if ! command -v mamba &>/dev/null && ! command -v micromamba &>/dev/null && ! command -v conda &>/dev/null; then
    if CONDA_BASE="$(find_conda_sh)"; then
        # shellcheck disable=SC1091
        source "${CONDA_BASE}/etc/profile.d/conda.sh"
        if [ -f "${CONDA_BASE}/etc/profile.d/mamba.sh" ]; then
            # shellcheck disable=SC1091
            source "${CONDA_BASE}/etc/profile.d/mamba.sh"
        fi
    fi
fi

# detecta gerenciador de pacotes disponível; instala Miniforge se não achar nenhum
if command -v mamba &>/dev/null; then
    PKG=mamba
elif command -v micromamba &>/dev/null; then
    PKG=micromamba
elif command -v conda &>/dev/null; then
    PKG=conda
else
    bootstrap_miniforge
    if command -v mamba &>/dev/null; then
        PKG=mamba
    else
        PKG=conda
    fi
fi

echo "Usando: ${PKG}"
echo ""

echo "==> Instalando ambiente ${SCRIPT_DIR##*/}..."
${PKG} env create -f "${SCRIPT_DIR}/envs/ploidycheck.yaml" --yes || \
    ${PKG} env update -f "${SCRIPT_DIR}/envs/ploidycheck.yaml" --prune

# smudgeplot 0.5.3 (bioconda) quebra com pandas >=3.0 — AttributeError em
# generate_smudge_table/write_smudge_report (issue upstream ainda aberto:
# https://github.com/KamilSJaron/smudgeplot/issues/255). Patch idempotente:
# só aplica se a assinatura do fix ainda não estiver no arquivo instalado.
SMUDGEPLOT_PY=$(${PKG} run -n ploidycheck python -c \
    "import smudgeplot.smudgeplot as m; print(m.__file__)")
if [ -n "${SMUDGEPLOT_PY}" ] && ! grep -q 'astype({"structure": str})' "${SMUDGEPLOT_PY}"; then
    echo "    aplicando patch do smudgeplot (bug pandas 3.x)..."
    patch -p1 -d "$(dirname "$(dirname "${SMUDGEPLOT_PY}")")" \
        < "${SCRIPT_DIR}/patches/smudgeplot_pandas3_fix.patch"
else
    echo "    patch do smudgeplot já aplicado, pulando"
fi

chmod +x "${SCRIPT_DIR}/ploidycheck" "${SCRIPT_DIR}/bin/ploidy_call.py"

echo ""
echo "Instalação concluída."
echo ""
echo "Ambiente instalado:"
${PKG} env list | grep -E 'ploidycheck'
echo ""
echo "Uso:"
echo "  ${SCRIPT_DIR}/ploidycheck --sample NOME --r1 R1.fastq.gz --r2 R2.fastq.gz --outdir results/"
echo ""
echo "Ajuda completa:"
echo "  ${SCRIPT_DIR}/ploidycheck --help"
