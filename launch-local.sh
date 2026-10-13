#!/usr/bin/env bash
# ==============================================================================
# Execução local (Docker) - Laboratório Apache Iceberg Table Format Demo
# Roda em qualquer máquina Linux ou macOS com Docker. Não usa a AWS para nada,
# exceto na Parte IV do roteiro, se houver credenciais em ~/.aws.
# Autor: Prof. Barbosa (infobarbosa@gmail.com)
# Repositório: https://github.com/infobarbosa/iceberg-tableformat-demo
#
#   curl -sS https://raw.githubusercontent.com/infobarbosa/iceberg-tableformat-demo/main/launch-local.sh | bash
#
# Variáveis opcionais:
#   LAB_DIR      pasta do laboratório no host   (padrão: ~/iceberg-lab)
#   LAB_PORTA    porta do code-server no host   (padrão: 8080)
#   IMAGE_TAG    tag da imagem                  (padrão: latest)
#   AWS_PROFILE  perfil AWS para a Parte IV     (padrão: default)
# ==============================================================================

set -euo pipefail

LAB_DIR="${LAB_DIR:-$HOME/iceberg-lab}"
LAB_PORTA="${LAB_PORTA:-8080}"
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGEM="ghcr.io/infobarbosa/iceberg-lab-docker-image:${IMAGE_TAG}"
CONTAINER="iceberg-lab"
ESPACO_MINIMO_GB=5

# Cores para output formatado
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

echo -e "${CYAN}${BOLD}"
echo "==================================================================="
echo "   LABORATÓRIO APACHE ICEBERG TABLE FORMAT - EXECUÇÃO LOCAL        "
echo "   Docker + code-server                                            "
echo "==================================================================="
echo -e "${NC}"

# ------------------------------------------------------------------------------
# 1. Docker
# ------------------------------------------------------------------------------
echo -e "${BLUE}[1/4] Verificando o Docker...${NC}"

if ! command -v docker >/dev/null 2>&1; then
    echo -e "${RED}[ERRO] Docker não encontrado. Instale em https://docs.docker.com/get-docker/${NC}"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo -e "${RED}[ERRO] O Docker está instalado, mas não respondeu. Ele está em execução?${NC}"
    echo -e "        (no macOS e no Windows, abra o Docker Desktop; no Linux, confira o serviço e se o seu usuário está no grupo docker)"
    exit 1
fi
echo -e "  -> Docker ${BOLD}$(docker version --format '{{.Server.Version}}')${NC} ($(docker version --format '{{.Server.Arch}}'))"

# ------------------------------------------------------------------------------
# 2. Container existente: só religa
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[2/4] Procurando um container '${CONTAINER}' existente...${NC}"

if docker container inspect "${CONTAINER}" >/dev/null 2>&1; then
    ESTADO=$(docker container inspect -f '{{.State.Status}}' "${CONTAINER}")
    PORTA_ATUAL=$(docker port "${CONTAINER}" 8080/tcp 2>/dev/null | head -1 | sed 's/.*://' || true)
    echo -e "  -> Encontrado (estado: ${BOLD}${ESTADO}${NC}). Os arquivos do laboratório são preservados."
    if [ "${ESTADO}" != "running" ]; then
        docker start "${CONTAINER}" >/dev/null
        echo -e "  -> Container iniciado."
    fi
    echo -e "\n${GREEN}${BOLD}Laboratório no ar:${NC} ${CYAN}${BOLD}http://localhost:${PORTA_ATUAL:-${LAB_PORTA}}${NC}"
    echo -e "Para recriar do zero: ${BOLD}docker rm -f ${CONTAINER}${NC} e rode este script de novo"
    echo -e "(os arquivos em ${LAB_DIR}/workspace continuam lá).\n"
    exit 0
fi
echo -e "  -> Nenhum. Um container novo será criado."

# ------------------------------------------------------------------------------
# 3. Pré-requisitos: porta e espaço em disco
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[3/4] Verificando porta e espaço em disco...${NC}"

if (exec 3<>"/dev/tcp/127.0.0.1/${LAB_PORTA}") 2>/dev/null; then
    echo -e "${RED}[ERRO] A porta ${LAB_PORTA} já está em uso. Escolha outra, por exemplo:${NC}"
    echo -e "        LAB_PORTA=8081 bash launch-local.sh"
    exit 1
fi
echo -e "  -> Porta ${BOLD}${LAB_PORTA}${NC} livre."

mkdir -p "${LAB_DIR}/workspace"
LIVRE_GB=$(df -Pk "${LAB_DIR}" | awk 'NR == 2 {printf "%d", $4 / 1024 / 1024}')
if ! docker image inspect "${IMAGEM}" >/dev/null 2>&1 && [ "${LIVRE_GB}" -lt "${ESPACO_MINIMO_GB}" ]; then
    echo -e "${RED}[ERRO] Só ${LIVRE_GB} GB livres em disco. A imagem tem cerca de 2,5 GB e o laboratório"
    echo -e "        grava mais algumas centenas de MB: libere pelo menos ${ESPACO_MINIMO_GB} GB.${NC}"
    exit 1
fi
echo -e "  -> ${BOLD}${LIVRE_GB} GB${NC} livres em disco."

# O usuário do container tem UID 1000. No Linux, a pasta do host precisa aceitar
# escrita desse UID (no macOS e no Windows, o Docker Desktop cuida disso).
if [ "$(uname -s)" = "Linux" ] && [ "$(id -u)" != "1000" ]; then
    chmod 777 "${LAB_DIR}/workspace"
    echo -e "${YELLOW}  [AVISO] Seu UID não é 1000: ${LAB_DIR}/workspace foi liberada para escrita do container.${NC}"
fi

# ------------------------------------------------------------------------------
# 4. Imagem e container
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[4/4] Baixando a imagem e iniciando o container...${NC}"
echo -e "  -> ${IMAGEM}"
docker pull --quiet "${IMAGEM}" >/dev/null

ARGS_AWS=()
if [ -d "${HOME}/.aws" ]; then
    ARGS_AWS=(-v "${HOME}/.aws:/home/barbosa/.aws:ro" -e "AWS_PROFILE=${AWS_PROFILE:-default}")
    echo -e "  -> ~/.aws montado somente leitura; perfil AWS: ${BOLD}${AWS_PROFILE:-default}${NC} (Parte IV)"
else
    echo -e "  -> Sem ~/.aws: as Partes I a III funcionam normalmente; a Parte IV precisa de credenciais AWS."
fi

docker run -d \
    --name "${CONTAINER}" \
    --restart unless-stopped \
    -p "${LAB_PORTA}:8080" \
    -v "${LAB_DIR}/workspace:/home/barbosa/project" \
    ${ARGS_AWS[@]+"${ARGS_AWS[@]}"} \
    "${IMAGEM}" >/dev/null

# Aguarda o code-server responder
for _ in $(seq 1 30); do
    if curl -s -o /dev/null "http://localhost:${LAB_PORTA}/"; then
        break
    fi
    sleep 1
done

echo -e "\n${GREEN}${BOLD}===================================================================${NC}"
echo -e "${GREEN}${BOLD}            AMBIENTE DE LABORATÓRIO PRONTO PARA USO!              ${NC}"
echo -e "${GREEN}${BOLD}===================================================================${NC}"
echo -e " ${BOLD}Link de Acesso:${NC}   ${CYAN}${BOLD}http://localhost:${LAB_PORTA}${NC}"
echo -e " ${BOLD}Arquivos:${NC}         ${LAB_DIR}/workspace  (= ~/project no container)"
echo -e "-------------------------------------------------------------------"
echo -e " Parar:            docker stop ${CONTAINER}"
echo -e " Religar:          rode este script de novo (ou docker start ${CONTAINER})"
echo -e " Apagar:           docker rm -f ${CONTAINER}   (os arquivos continuam em ${LAB_DIR})"
echo -e "${GREEN}${BOLD}===================================================================${NC}\n"
