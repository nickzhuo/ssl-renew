#!/bin/bash
# =============================================================================
#  证书环境一次性初始化（在服务器上只跑一次）
#  scripts/ssl/ssl-setup.sh
#
#  它做的事：
#    1. 生成 secrets.env（只放 DNS 服务商的 API 凭据）并锁死权限 600
#    1.5 生成续期后置钩子 renewpost.sh（按本机情况自动选 RELOAD_MODE）
#    2. 检查 domains.conf 的域名列表和 ssl.conf 的邮箱
#    3. 环境体检（配置 / 网络 / NS 归属）
#    4. 首次签发：遍历域名列表，逐张签发并部署到证书目录
#    5. 装配 systemd timer：每天自动检查、按各自的阈值自动续期、自动执行后置钩子
#
#  ★ systemd unit 名来自 ssl.conf 的 SSL_UNIT_NAME：
#    同一台机器上若同时跑多套（Traefik / nginx），名字必须不同，否则互相覆盖。
#    默认 ssl-renew；nginx 那台请设成 ssl-nginx-renew（或你原来在用的名字）。
#
#  用法（需要 root，因为要写 /etc/systemd/system）：
#    sudo ./ssl-setup.sh                 # 完整初始化
#    sudo ./ssl-setup.sh --no-timer      # 只签发，不装 systemd 定时器
#    sudo ./ssl-setup.sh --staging       # 用 LE 测试环境演练一遍全流程
#    ./ssl-setup.sh --help
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${SCRIPT_DIR}/lib.sh"

ISSUE_SH="${SCRIPT_DIR}/ssl-issue.sh"
STATUS_SH="${SCRIPT_DIR}/ssl-status.sh"
ENV_FILE="${SCRIPT_DIR}/secrets.env"
ENV_EXAMPLE="${SCRIPT_DIR}/secrets.env.example"
HOOK_FILE="${SCRIPT_DIR}/renewpost.sh"
# 仓库里只有**一个**钩子模板，用 RELOAD_MODE 决定行为（none / nginx / traefik / compose）。
# 这里按本机检测结果把它复制过来、并把 MODE 写成检测到的值，省得你手工改。
HOOK_EXAMPLE="${SCRIPT_DIR}/renewpost.sh.example"

# 只有检测到这个 docker compose 项目目录存在时，才会自动生成容器类钩子 ——
# 免得在没有这个项目的机器上生成一个必然失败的钩子。
DEFAULT_COMPOSE_DIR="/root/docker/api"

INSTALL_TIMER=1
PASS_ARGS=()

usage() {
  cat <<'EOF'

  证书环境一次性初始化

  用法:
    sudo ./ssl-setup.sh [选项]

  选项:
    --no-timer     不安装 systemd 定时器（只做签发，续期自行安排）
    --staging      首次签发走 Let's Encrypt 测试环境
    --force        强制重新签发
    --debug        打开 acme.sh 调试日志
    -h, --help     显示本帮助

EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --no-timer) INSTALL_TIMER=0 ;;
    --staging)  PASS_ARGS+=(--staging) ;;
    --force)    PASS_ARGS+=(--force) ;;
    --debug)    PASS_ARGS+=(--debug) ;;
    -h|--help)  usage; exit 0 ;;
    *)          usage; die "未知参数: $1" ;;
  esac
  shift
done

# 载入策略：SSL_UNIT_NAME（unit 名）和 SSL_OUTPUT_DIR（证书目录）都从 ssl.conf 来。
# ★ 必须在用到这两个变量之前调用 —— 以前漏了这一步，
#   结果结尾打印"证书输出根目录"时 ${SSL_DIR} 是空的（打印成 "/"）。
load_policy

UNIT_DIR="/etc/systemd/system"
SVC_NAME="${SSL_UNIT_NAME}.service"
TIMER_NAME="${SSL_UNIT_NAME}.timer"

printf '\n%s  Let'"'"'s Encrypt 证书环境初始化%s\n' "$C_BLD$C_CYN" "$C_RST"
printf '  %s项目根目录%s  %s\n' "$C_BLD" "$C_RST" "$PROJECT_ROOT"
printf '  %s脚本目录%s    %s\n' "$C_BLD" "$C_RST" "$SCRIPT_DIR"
printf '  %s证书输出%s    %s/  (%s 布局)\n' "$C_BLD" "$C_RST" "$SSL_DIR" "$SSL_OUTPUT_LAYOUT"
printf '  %ssystemd%s     %s  %s(来自 ssl.conf 的 SSL_UNIT_NAME)%s\n' \
  "$C_BLD" "$C_RST" "$TIMER_NAME" "$C_DIM" "$C_RST"

# -----------------------------------------------------------------------------
# 0. 前置检查
# -----------------------------------------------------------------------------
step "前置检查"

[ -f "$ISSUE_SH" ] || die "找不到 ${ISSUE_SH}，目录结构不完整"
[ -f "$STATUS_SH" ] || die "找不到 ${STATUS_SH}，目录结构不完整"
[ -f "$ENV_EXAMPLE" ] || die "找不到 ${ENV_EXAMPLE}，目录结构不完整"
ok "脚本文件齐备（lib.sh / ssl-issue.sh / ssl-status.sh）"

if [ "$(id -u)" -ne 0 ]; then
  if [ "$INSTALL_TIMER" = 1 ]; then
    die "安装 systemd 定时器需要 root 权限，请使用：
      sudo $0
    或者只做签发、不装定时器：
      $0 --no-timer"
  fi
  warn "当前非 root，跳过 systemd 定时器安装"
  INSTALL_TIMER=0
fi

if ! command -v curl >/dev/null 2>&1; then
  die "缺少 curl。CentOS 8 默认自带；若确实缺失，注意 CentOS 8 已 EOL，
      yum 官方源不可用，需先把仓库切到 vault.centos.org 再安装。"
fi
ok "curl 可用"

# -----------------------------------------------------------------------------
# 1. 生成 secrets.env（只放 DNS 服务商的 API 凭据）
# -----------------------------------------------------------------------------
step "密钥文件"

if [ ! -f "$ENV_FILE" ]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  cat <<EOF

  ${C_YEL}已生成密钥文件，请先填入 DNS 服务商的 API 凭据，然后重新运行本脚本：${C_RST}

      ${C_BLD}${ENV_FILE}${C_RST}      （权限已设为 600，且已被 .gitignore 排除）

  ${C_BLD}腾讯云 DNSPod${C_RST}（域名解析托管在腾讯云时用）
      腾讯云控制台 → 访问管理(CAM) → API 密钥管理 → 新建密钥
      https://console.cloud.tencent.com/cam/capi
      建议用子账号并只授予 QcloudDNSPodFullAccess。
      最少填两行：  Tencent_SecretId="AKID..."   Tencent_SecretKey="..."

  ${C_BLD}GoDaddy${C_RST}（域名解析托管在 GoDaddy 时用）
      GoDaddy → 我的账户 → API 密钥（Developer Portal）
      https://developer.godaddy.com/keys
      ★ 必须创建 Production（生产）Key/Secret，OTE 测试密钥无效。
      最少填两行：  GD_Key="..."                 GD_Secret="..."

  哪个服务商有几个账号，就给变量名加后缀（后缀就是 domains.conf 里的 account=）：
      Tencent_SecretId_ACC2 / Tencent_SecretKey_ACC2
      GD_Key_GD2           / GD_Secret_GD2

  填好后重新执行：  sudo $0

EOF
  exit 0
fi

chmod 600 "$ENV_FILE" 2>/dev/null || true
ok "密钥文件已存在：${ENV_FILE}（权限 600）"

# -----------------------------------------------------------------------------
# 1.5 续期后置钩子 renewpost.sh
# -----------------------------------------------------------------------------
step "续期后置钩子"

if [ -f "$HOOK_FILE" ]; then
  chmod +x "$HOOK_FILE" 2>/dev/null || true
  ok "已存在：${HOOK_FILE}（不动它，你自己维护）"
  # 顺手把当前模式念出来 —— 这台机器到底会不会重载、重载什么，一眼可查
  hook_mode="$(sed -n 's/^RELOAD_MODE="\(.*\)".*$/\1/p' "$HOOK_FILE" | head -n1)"
  if [ -n "$hook_mode" ]; then
    info "当前 RELOAD_MODE=${hook_mode}"
  else
    info "没读到 RELOAD_MODE —— 这可能是旧版模板（.example.nginx / .example.docker 时代）"
    info "新版用一个 RELOAD_MODE 区分行为，见 ${HOOK_EXAMPLE}"
  fi
else
  # 检测顺序：
  #   ① 有 nginx 可执行文件        → nginx 机器（证书就是给 nginx 用的，优先）
  #   ② compose 项目里有 Traefik 动态配置 → traefik 机器（走热加载，无中断）
  #   ③ 只有 compose 项目目录      → 普通容器服务（走 force-recreate）
  hook_mode=""
  if command -v nginx >/dev/null 2>&1 || [ -x /usr/sbin/nginx ] || [ -x /usr/bin/nginx ]; then
    hook_mode="nginx"
  elif [ -f "${DEFAULT_COMPOSE_DIR}/dynamic_conf.toml" ]; then
    hook_mode="traefik"
  elif [ -d "$DEFAULT_COMPOSE_DIR" ]; then
    hook_mode="compose"
  fi

  if [ -n "$hook_mode" ] && [ -f "$HOOK_EXAMPLE" ]; then
    sed "s/^RELOAD_MODE=\"none\"/RELOAD_MODE=\"${hook_mode}\"/" "$HOOK_EXAMPLE" > "$HOOK_FILE"
    chmod +x "$HOOK_FILE"
    # ★ 后验：模板默认值将来若改名，sed 会**静默不替换** —— 那会生成一个
    #   "看起来有钩子、实际 RELOAD_MODE 还是 none" 的文件，是最难发现的失败模式。
    #   注意：核对不过时**不能**再打印"已生成（RELOAD_MODE=xxx）"，那是假话。
    if grep -q "^RELOAD_MODE=\"${hook_mode}\"" "$HOOK_FILE"; then
      ok "已生成：${HOOK_FILE}（RELOAD_MODE=${hook_mode}）"
      case "$hook_mode" in
        nginx)   info "证书更新后会自动执行：nginx -t && systemctl restart nginx" ;;
        traefik) info "证书更新后会自动执行：写 ${DEFAULT_COMPOSE_DIR}/dynamic_conf.toml 触发热加载，核对线上证书 serial" ;;
        compose) info "证书更新后会自动执行：cd ${DEFAULT_COMPOSE_DIR} && docker compose up --force-recreate -d --no-deps <服务名>" ;;
      esac
    else
      warn "已生成 ${HOOK_FILE}，但 RELOAD_MODE 没写对（模板默认值可能变了）"
      warn "  请手工把它改成：RELOAD_MODE=\"${hook_mode}\""
    fi
    info "路径 / 服务名不对就改 ${HOOK_FILE} 顶部的配置区"
    info "改完先自测：bash ${HOOK_FILE} --dry-run"
  else
    info "没检测到 nginx，也没检测到 ${DEFAULT_COMPOSE_DIR}，暂不生成 renewpost.sh"
    info "证书更新后要做什么，自己挑一个模式（模板里 RELOAD_MODE 四选一）："
    info "  none     什么都不做（也可以干脆不建这个文件）"
    info "  nginx    nginx -t → systemctl restart nginx → 校验 is-active"
    info "  traefik  写动态配置触发热加载 → 核对线上证书 serial（无中断）"
    info "  compose  docker compose up --force-recreate → 校验容器 running"
    info "  用法：cp ${HOOK_EXAMPLE} ${HOOK_FILE}"
    info "        sed -i 's/^RELOAD_MODE=\"none\"/RELOAD_MODE=\"traefik\"/' ${HOOK_FILE}"
    info "        chmod +x ${HOOK_FILE} && bash ${HOOK_FILE} --dry-run"
  fi
fi

# -----------------------------------------------------------------------------
# 2. 检查域名列表与邮箱
# -----------------------------------------------------------------------------
step "域名列表与策略"

if ! "$ISSUE_SH" --list; then
  die "域名列表校验未通过，请编辑后重试：
      ${DOMAINS_FILE}
  把示例行前面的 # 去掉，改成你自己的域名，例如：
      example.com www.example.com *.example.com"
fi
ok "域名列表校验通过"

if [ -z "${SSL_EMAIL//[[:space:]]/}" ]; then
  die "SSL_EMAIL 还没填。请编辑：
      ${POLICY_FILE}
  设置 ACME 账号邮箱，例如：
      SSL_EMAIL=\"ops@example.com\""
fi
ok "ACME 账号邮箱：${SSL_EMAIL}"

# -----------------------------------------------------------------------------
# 3+4. 体检 + 首次签发
# -----------------------------------------------------------------------------
step "签发证书（遍历域名列表）"
info "下面会自动完成：安装 acme.sh → 逐个域名写 TXT → LE 校验 → 部署到证书目录"
"$ISSUE_SH" ${PASS_ARGS[@]+"${PASS_ARGS[@]}"}

# -----------------------------------------------------------------------------
# 5. 装配 systemd 自动续期
# -----------------------------------------------------------------------------
install_timer() {
  step "装配自动续期（systemd timer）"

  if ! command -v systemctl >/dev/null 2>&1; then
    warn "系统没有 systemctl，跳过定时器安装。请自行用 crontab 实现每日检查："
    info "  17 3 * * * ${ISSUE_SH} >/dev/null 2>&1"
    return 0
  fi

  cat > "${UNIT_DIR}/${SVC_NAME}" <<EOF
[Unit]
Description=Renew Let's Encrypt certificates via DNS-01
Documentation=file:${SCRIPT_DIR}/README.md
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
WorkingDirectory=${PROJECT_ROOT}
# ★ 显式用 /bin/bash 调脚本，不走脚本自己的 shebang ——
#   少一层依赖（不用 /usr/bin/env），也避免 shebang 被改坏/被占用导致定时任务静默失败。
ExecStart=/bin/bash ${ISSUE_SH}
StandardOutput=journal
StandardError=journal
TimeoutStartSec=900
EOF

  cat > "${UNIT_DIR}/${TIMER_NAME}" <<EOF
[Unit]
Description=Daily check for Let's Encrypt certificate renewal

[Timer]
# 每天 03:17 触发（随机抖动 30 分钟，避开整点高峰）
# ⚠️ 按**服务器本地时区**解释：机器是 EDT 的话，实际是北京时间 15:17±30min。
OnCalendar=*-*-* 03:17:00
RandomizedDelaySec=30min
# 关机期间错过的任务，开机后补跑一次
Persistent=true
Unit=${SVC_NAME}

[Install]
WantedBy=timers.target
EOF

  chmod 644 "${UNIT_DIR}/${SVC_NAME}" "${UNIT_DIR}/${TIMER_NAME}"
  ok "已写入 ${UNIT_DIR}/${SVC_NAME}"
  ok "已写入 ${UNIT_DIR}/${TIMER_NAME}"

  systemctl daemon-reload
  if ! systemctl enable --now "$TIMER_NAME" >/dev/null 2>&1; then
    die "启用 ${TIMER_NAME} 失败。请手动排查：
      systemctl status ${TIMER_NAME}
      journalctl -xeu ${TIMER_NAME} -n 50 --no-pager"
  fi
  ok "定时器已启用（每日 03:17 ± 30min，逐域名按各自阈值判断是否续期）"

  printf '\n'
  systemctl list-timers "$TIMER_NAME" --no-pager 2>/dev/null || true
}

if [ "$INSTALL_TIMER" = 1 ]; then
  install_timer
else
  step "跳过定时器安装"
  info "可随时手动续期：${ISSUE_SH}"
fi

# -----------------------------------------------------------------------------
# 收尾
# -----------------------------------------------------------------------------
step "初始化完成"

printf '  %s日常命令%s\n' "$C_BLD" "$C_RST"
printf '    查看每张证书的到期时间   %s\n' "$STATUS_SH"
printf '    详情（含证书域名/权限）  %s --detail\n' "$STATUS_SH"
printf '    先看会做什么（不改动）   %s --check-only\n' "$ISSUE_SH"
printf '    立即续期一次             %s\n' "$ISSUE_SH"
printf '    只续某一个域名           %s --domain <主域名>\n' "$ISSUE_SH"
printf '    强制重签全部             %s --force\n' "$ISSUE_SH"
if [ "$INSTALL_TIMER" = 1 ]; then
  printf '    看定时器                 systemctl list-timers %s\n' "$TIMER_NAME"
  printf '    看续期日志（实时输出）   journalctl -u %s -n 100 --no-pager\n' "$SVC_NAME"
  printf '    立即触发一次定时任务     systemctl start %s\n' "$SVC_NAME"
fi
printf '    看历史运行摘要           cat %s\n' "${SSL_DIR}/renew.log"

printf '\n  %s续期后置钩子%s %s\n' "$C_BLD" "$C_RST" "$HOOK_FILE"
if [ -f "$HOOK_FILE" ]; then
  hook_mode="$(sed -n 's/^RELOAD_MODE="\(.*\)".*$/\1/p' "$HOOK_FILE" | head -n1)"
  printf '    模式 %s；证书有更新时自动执行它\n' "${hook_mode:-（未读到，可能是旧版模板）}"
  printf '    先空跑确认：bash %s --dry-run\n' "$HOOK_FILE"
else
  printf '    未生成（本机不需要重载时不建它也可以）。需要时：\n'
  printf '      cp %s %s\n' "$HOOK_EXAMPLE" "$HOOK_FILE"
  printf '      # 然后按需要把 RELOAD_MODE 改成 nginx / traefik / compose\n'
  printf '      chmod +x %s && bash %s --dry-run\n' "$HOOK_FILE" "$HOOK_FILE"
fi

printf '\n  %s新增域名只需两步%s\n' "$C_BLD" "$C_RST"
printf '    1) 在 %s 里加一行（跨服务商/账号的要分行，并带 dns= / account=）\n' "$(basename "$DOMAINS_FILE")"
printf '    2) 跑一次 %s（新域名会自动签发）\n' "$ISSUE_SH"

printf '\n  %s证书输出根目录%s %s/\n\n' "$C_BLD" "$C_RST" "$SSL_DIR"
