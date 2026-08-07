#!/usr/bin/env bash
# Instala o Herdr no Linux e poe o servidor para subir no login, via systemd
# user unit - o equivalente da tarefa agendada 'HerdrServer' no Windows.
#
# Nao exige root: o Herdr instala em ~/.local/bin e a unit e do usuario.
# A unica parte que precisa de root e o 'loginctl enable-linger', explicado no
# fim e deixado para voce - ele decide se o servidor sobrevive sem sessao.
#
# Uso:
#   ./setup-herdr.sh              instala o que faltar, configura e habilita
#   ./setup-herdr.sh --no-config  nao toca no config.toml
#   ./setup-herdr.sh --check      so relata o estado, nao altera nada

set -euo pipefail

UNIT_NAME="herdr-server.service"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
UNIT_PATH="$UNIT_DIR/$UNIT_NAME"
HERDR_CFG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr"
HERDR_CFG="$HERDR_CFG_DIR/config.toml"

NO_CONFIG=0
CHECK_ONLY=0
for arg in "$@"; do
  case "$arg" in
    --no-config) NO_CONFIG=1 ;;
    --check)     CHECK_ONLY=1 ;;
    *) echo "argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done

log() { printf '  %s\n' "$*"; }

find_herdr() {
  command -v herdr 2>/dev/null && return 0
  [ -x "$HOME/.local/bin/herdr" ] && echo "$HOME/.local/bin/herdr" && return 0
  return 1
}

# --- estado atual ------------------------------------------------------
HERDR_BIN="$(find_herdr || true)"

if [ "$CHECK_ONLY" = "1" ]; then
  echo "=== estado do Herdr (Linux) ==="
  log "binario   : ${HERDR_BIN:-AUSENTE}"
  [ -n "$HERDR_BIN" ] && log "versao    : $("$HERDR_BIN" --version 2>&1)"
  log "config    : $([ -f "$HERDR_CFG" ] && echo "$HERDR_CFG" || echo AUSENTE)"
  log "unit      : $([ -f "$UNIT_PATH" ] && echo "$UNIT_PATH" || echo AUSENTE)"
  if [ -f "$UNIT_PATH" ]; then
    log "habilitada: $(systemctl --user is-enabled "$UNIT_NAME" 2>&1 || true)"
    log "ativa     : $(systemctl --user is-active "$UNIT_NAME" 2>&1 || true)"
  fi
  log "servidor  : $([ -n "$HERDR_BIN" ] && "$HERDR_BIN" status server 2>&1 | head -1 || echo 'n/a')"
  log "linger    : $(loginctl show-user "$USER" --property=Linger 2>/dev/null || echo 'n/a')"
  exit 0
fi

# --- 1) instalar -------------------------------------------------------
if [ -n "$HERDR_BIN" ]; then
  log "Herdr ja instalado: $HERDR_BIN ($("$HERDR_BIN" --version 2>&1))"
else
  log "instalando o Herdr pelo instalador oficial (herdr.dev/install.sh)..."
  # Baixa para arquivo antes de executar, em vez de 'curl | sh': o que rodou
  # fica auditavel e o sha256 e registrado. Mesmo criterio do lado Windows.
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  curl -fsSL https://herdr.dev/install.sh -o "$tmp"
  log "sha256: $(sha256sum "$tmp" | cut -d' ' -f1)"
  grep -qi herdr "$tmp" || { echo "conteudo baixado nao parece o instalador do Herdr" >&2; exit 1; }
  sh "$tmp"
  HERDR_BIN="$(find_herdr || true)"
  [ -n "$HERDR_BIN" ] || { echo "instalador terminou mas o herdr nao foi encontrado" >&2; exit 1; }
  log "instalado: $HERDR_BIN"
fi

# --- 2) config ---------------------------------------------------------
# Nao sobrescreve um config existente: mexer no arquivo de quem ja usa o Herdr
# nao e trabalho de um script de setup inicial.
if [ "$NO_CONFIG" = "0" ]; then
  mkdir -p "$HERDR_CFG_DIR"
  if [ -f "$HERDR_CFG" ]; then
    log "config.toml ja existe - preservado (veja docs/linux.md para as opcoes recomendadas)"
  else
    cat > "$HERDR_CFG" <<'TOML'
# Gerado por setup-rustdesk (scripts/linux/setup-herdr.sh).
# Mesmas opcoes do config/herdr.psd1 do lado Windows - o porque de cada uma
# esta no README, secao "O terminal dentro da sessao (Herdr)".
[ui]
hide_tab_bar_when_single_tab = true
pane_gaps = false
sidebar_collapsed_mode = "hidden"
show_agent_labels_on_pane_borders = true
mobile_width_threshold = 90
redraw_on_focus_gained = true
mouse_capture = true
mouse_scroll_lines = 5

[ui.toast]
delivery = "herdr"

[session]
resume_agents_on_restore = true

[experimental]
pane_history = true

[advanced]
scrollback_limit_bytes = 10485760
TOML
    log "config.toml criado: $HERDR_CFG"
  fi
fi

# --- 3) autostart via systemd user unit --------------------------------
if ! systemctl --user --version >/dev/null 2>&1; then
  log "AVISO: systemd --user indisponivel. Sem autostart; suba com 'herdr server &'."
else
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_PATH" <<UNIT
[Unit]
Description=Herdr headless server
After=default.target

[Service]
Type=simple
ExecStart=$HERDR_BIN server
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  log "unit criada: $UNIT_PATH"
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT_NAME"

  # confirmar em vez de afirmar
  sleep 3
  en="$(systemctl --user is-enabled "$UNIT_NAME" 2>&1 || true)"
  ac="$(systemctl --user is-active  "$UNIT_NAME" 2>&1 || true)"
  log "unit: enabled=$en active=$ac"
  [ "$en" = "enabled" ] || echo "  AVISO: a unit nao ficou habilitada." >&2
fi

# --- 4) verificar o servidor -------------------------------------------
sleep 1
log "servidor: $("$HERDR_BIN" status server 2>&1 | head -1)"

# --- 5) o passo que exige root -----------------------------------------
linger="$(loginctl show-user "$USER" --property=Linger 2>/dev/null | cut -d= -f2 || echo unknown)"
if [ "$linger" != "yes" ]; then
  echo ''
  echo '  FALTA UM PASSO (precisa de root):'
  echo "    sudo loginctl enable-linger $USER"
  echo ''
  echo '  Sem linger, o systemd encerra os servicos do usuario quando a ultima'
  echo '  sessao dele fecha - e o servidor Herdr morre junto, levando o que'
  echo '  estava rodando. E o mesmo problema que no Windows aparece como'
  echo '  "No active console user logged on".'
fi
