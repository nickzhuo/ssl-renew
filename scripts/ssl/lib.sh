#!/bin/bash
# =============================================================================
#  lib.sh —— ssl 脚本共用函数库
#  由 ssl-issue.sh / ssl-status.sh / ssl-setup.sh source 使用，请勿直接执行本文件。
#
#  ★ 本套脚本只有**一套**。不同消费方（Traefik / nginx / 别的）之间的差别
#    全部外置到配置文件里（ssl.conf 的输出目录与 unit 名、renewpost.sh 钩子），
#    代码里**不留任何消费方分支** —— 免得复制出第二套、日后同步漏改。
# =============================================================================

# -----------------------------------------------------------------------------
#  ★★ HOME 兜底 —— 必须放在最前面，且必须在任何 ${HOME} 之前
# -----------------------------------------------------------------------------
#  systemd 给 root 的 service **不注入 HOME**（只有配了 User= / DynamicUser= 才给，
#  CentOS 8 的 systemd 239 还没有 SetLoginEnvironment=）。
#  而这三个脚本都写了 `set -u` —— 裸用 ${HOME} 在 nounset 下是**致命错误**：
#     lib.sh: line 21: HOME: unbound variable     → 进程 exit 1，日志里一句话都不留。
#  实测症状：定时任务每天 03:17 稳定失败、renew.log 完全空白，
#  而同一台机器上手动执行（登录 shell 有 HOME）一切正常 —— 极难定位。
#  这里统一兜一次并 export，脚本自身与 acme.sh 子进程都能拿到 HOME。
if [ -z "${HOME:-}" ]; then
  HOME="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"
  [ -n "$HOME" ] || HOME=/root
  export HOME
fi

# -----------------------------------------------------------------------------
#  路径
# -----------------------------------------------------------------------------
SSL_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "${SSL_LIB_DIR}/../.." && pwd)"

# 三个配置文件各司其职，都可以用环境变量覆盖：
#   SECRETS_FILE  DNS 服务商的 API 凭据   （保密，gitignore）
#   DOMAINS_FILE  域名列表，每行一张证书   （可提交）
#   POLICY_FILE   全局策略                （可提交）
SECRETS_FILE="${SECRETS_FILE:-${SSL_LIB_DIR}/secrets.env}"
DOMAINS_FILE="${DOMAINS_FILE:-${SSL_LIB_DIR}/domains.conf}"
POLICY_FILE="${POLICY_FILE:-${SSL_LIB_DIR}/ssl.conf}"

# ★ 解析顺序：显式 ACME_HOME → 当前用户 HOME → /root。
#   最后一层兜底是必需的：root 的 systemd service **不注入 $HOME**
#   （systemd 的默认行为，只有配了 User= 才会给），此时 ${HOME}/.acme.sh
#   会退化成 /.acme.sh —— 一个不存在的路径，于是脚本误判"acme.sh 没装"，
#   转去联网重新下载，在国内服务器上大概率失败并中途退出。
#   加了兜底，定时任务才和手动执行看到同一个 acme.sh。
ACME_HOME="${ACME_HOME:-${HOME:-/root}/.acme.sh}"
ACME_BIN="${ACME_HOME}/acme.sh"

LE_PROD_DIR="https://acme-v02.api.letsencrypt.org/directory"
LE_STAGING_DIR="https://acme-staging-v02.api.letsencrypt.org/directory"

# -----------------------------------------------------------------------------
#  输出
# -----------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_CYN=$'\033[36m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''; C_BLD=''; C_DIM=''; C_RST=''
fi

STEP_NO=0
step() { STEP_NO=$((STEP_NO + 1)); printf '\n%s──── [%d] %s ────%s\n' "$C_CYN$C_BLD" "$STEP_NO" "$*" "$C_RST"; }
info() { printf '     %s\n' "$*"; }
ok()   { printf '  %s✔%s %s\n' "$C_GRN" "$C_RST" "$*"; }
warn() { printf '  %s!%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
die()  { printf '\n  %s✘ %s%s\n\n' "$C_RED" "$*" "$C_RST" >&2; exit 1; }
rule() { printf '  %s──────────────────────────────────────────────────────────────────────%s\n' "$C_DIM" "$C_RST"; }

# =============================================================================
#  DNS 服务商规格表  ★ 新增一个服务商，主要是加一行
# =============================================================================
#  字段（用 | 分隔）：
#    1 provider    domains.conf 里 dns= 写的东西，全小写
#    2 acme 钩子   acme.sh --dns 后面跟的名字
#    3 ID 变量     acme.sh 钩子**硬编码**读取的变量名（凭据的"输出槽"）
#    4 KEY 变量    同上
#    5 展示名      打印给人看的
#    6 NS 特征     体检时用来判断"这个域名的解析是不是托管在该服务商"
#    7 探针 URL    体检时 curl 一下看能不能连通（返回非 000 即算通）
#
#  ⚠️ 第 3、4 列不能自己起名 —— 必须照 acme.sh 的钩子源码写，否则钩子读不到凭据。
#     例：dns_gd 里是 `GD_Key="${GD_Key:-$(_readaccountconf_mutable GD_Key)}"`。
#  ⚠️ 多账号时，secrets.env 里用 `<ID变量>_<账号名>` / `<KEY变量>_<账号名>`，
#     而"输出槽"永远是上面这两个**不带后缀**的名字（account_activate 负责搬运）。
#  ⚠️ 新增一个服务商，一共要动 4 处（都在 lib.sh 里，都有"新增服务商"标记）：
#       ① 这张表   ② load_secrets 的扫描 case
#       ③ account_activate 的写入 case   ④ provider_cred_help 的获取指引
# =============================================================================
PROVIDER_SPECS=(
  "tencent|dns_tencent|Tencent_SecretId|Tencent_SecretKey|腾讯云 DNSPod|dnspod|https://dnspod.tencentcloudapi.com"
  "godaddy|dns_gd|GD_Key|GD_Secret|GoDaddy|domaincontrol.com|https://api.godaddy.com/v1"
)

provider_spec() {
  local p="$1" s
  for s in "${PROVIDER_SPECS[@]}"; do
    case "$s" in "$p|"*) printf '%s' "$s"; return 0 ;; esac
  done
  return 1
}
provider_valid() { provider_spec "$1" >/dev/null 2>&1; }
provider_field() {
  local spec
  spec="$(provider_spec "$1")" || return 1
  printf '%s' "$spec" | cut -d'|' -f"$2"
}
provider_hook()    { provider_field "$1" 2; }
provider_id_var()  { provider_field "$1" 3; }
provider_key_var() { provider_field "$1" 4; }
provider_display()   { provider_field "$1" 5; }
provider_ns_hint()   { provider_field "$1" 6; }
provider_check_url() { provider_field "$1" 7; }

# 所有服务商名（空格分隔）
provider_list() {
  local s out=""
  for s in "${PROVIDER_SPECS[@]}"; do out="${out}${s%%|*} "; done
  printf '%s' "${out% }"
}

# 各服务商的凭据获取指引（写进报错里，省得再翻文档）
# ★ 新增服务商第 ④ 处
provider_cred_help() {
  case "$1" in
    tencent) printf '  获取：腾讯云控制台 → 访问管理(CAM) → API 密钥管理\n      https://console.cloud.tencent.com/cam/capi\n  建议建子账号，只授予 QcloudDNSPodFullAccess。\n  注意要用“生产”密钥，不是 DNSPod 旧版 Token。' ;;
    godaddy) printf '  获取：GoDaddy → 我的账户 → API 密钥（Developer Portal）\n      https://developer.godaddy.com/keys\n  ★ 必须创建 Production（生产）Key/Secret —— acme.sh 的 dns_gd 只打\n    api.godaddy.com，OTE（测试）密钥无效。\n  ★ 域名的 DNS 必须真的托管在 GoDaddy，否则 TXT 记录写不进去。' ;;
    *) printf '' ;;
  esac
}

# =============================================================================
#  systemd unit 名
# =============================================================================
#  ★ 一台机器上可能同时跑多套（Traefik 一套、nginx 一套），unit 同名会互相覆盖 ——
#    所以名字必须**每台机器自己指定**，写在 ssl.conf 的 SSL_UNIT_NAME 里。
#    代码里绝对不要再写死具体名字：曾经两套各写死一个，复制套件时漏改过一次，
#    结果 ssl-status.sh 一直去查另一套的 unit，报「未安装」，白白误导排查。
unit_name() {
  local n="${SSL_UNIT_NAME:-ssl-renew}"
  case "$n" in
    ''|*[!A-Za-z0-9_.@-]*) printf 'ssl-renew' ;;
    *) printf '%s' "$n" ;;
  esac
}
timer_unit()   { printf '%s.timer' "$(unit_name)"; }
service_unit() { printf '%s.service' "$(unit_name)"; }

# =============================================================================
#  全局策略（由 ssl.conf 覆盖）
# =============================================================================
SSL_EMAIL=""
SSL_OUTPUT_DIR="ssl"
SSL_OUTPUT_LAYOUT="subdir"
SSL_KEY_LENGTH="ec-256"
SSL_RENEW_DAYS="30"
SSL_DNS_SLEEP="20"
SSL_RELOAD_CMD=""
SSL_POST_HOOK=""
SSL_KEEP_GOING="1"
SSL_UNIT_NAME="ssl-renew"
SSL_DIR=""
SSL_RUN_LOG=""
# 备用日志：配置还没解析出来就失败时（ssl.conf 缺失 / 内容非法，load_policy 里直接 die）
# 用它兜底，保证"脚本跑过并失败"这件事仍然有痕迹。
# 放在脚本目录下（必然可写，且已被 .gitignore 的 *.log 规则覆盖）。
# 没有它，renew.log 空白就有两种解释 ——「任务没跑」和「一进来就崩了」无法区分。
SSL_RUN_LOG_FALLBACK="${SSL_LIB_DIR}/renew-fallback.log"
IS_ECC=0

# =============================================================================
#  证书列表（由 domains.conf 填充）
# =============================================================================
CERT_COUNT=0
CERT_DIR=()
CERT_DOMAINS=()
CERT_RENEW=()
CERT_PRIMARY=()
CERT_ACCOUNT=()
CERT_PROV=()

# =============================================================================
#  DNS 账号（多服务商 × 多账号，域名按需归属）
# =============================================================================
#  secrets.env 里的命名规则：
#      <ID变量>            / <KEY变量>             -> 该服务商的账号 "default"
#      <ID变量>_<名字>      / <KEY变量>_<名字>       -> 该服务商的账号 "<名字>"
#  以腾讯云为例（ID变量=Tencent_SecretId，KEY变量=Tencent_SecretKey）：
#      Tencent_SecretId          / Tencent_SecretKey           -> tencent / default
#      Tencent_SecretId_ACC2     / Tencent_SecretKey_ACC2      -> tencent / ACC2
#  GoDaddy（ID变量=GD_Key，KEY变量=GD_Secret）：
#      GD_Key                    / GD_Secret                   -> godaddy / default
#      GD_Key_GD2                / GD_Secret_GD2               -> godaddy / GD2
#
#  填完由 load_secrets 解析成下面这些数组；
#  domains.conf 里用 dns=<服务商> 选服务商、account=<名字> 选账号，
#  不写就是默认值（dns=tencent、account=default）—— 所以老配置零改动。
#
#  ★ ACCOUNT_IDS / ACCOUNT_KEYS 是权威存储，<ID变量> / <KEY变量> 只是"当前生效"
#    的输出槽（acme.sh 只认它们）。千万不要在切换账号时从当前槽位回读 ——
#    default 账号的值就在槽位里，切走之后再回读只会读到上一个账号的密钥（串号）。
ACCOUNT_COUNT=0
ACCOUNT_PROV=()     # 服务商
ACCOUNT_NAMES=()    # 账号名
ACCOUNT_TAILS=()    # ID 尾号（日志里用来辨认账号，不泄露完整密钥）
ACCOUNT_IDS=()
ACCOUNT_KEYS=()

# =============================================================================
#  载入策略 ssl.conf
# =============================================================================
load_policy() {
  if [ ! -f "$POLICY_FILE" ]; then
    die "找不到策略文件：${POLICY_FILE}
  仓库里应自带该文件，请确认目录结构完整。"
  fi

  # set -a：让文件里的变量自动导出，后续 acme.sh 子进程也能读到
  set -a
  # shellcheck disable=SC1090
  . "$POLICY_FILE"
  set +a

  SSL_EMAIL="${SSL_EMAIL:-}"
  SSL_OUTPUT_DIR="${SSL_OUTPUT_DIR:-ssl}"
  SSL_OUTPUT_LAYOUT="${SSL_OUTPUT_LAYOUT:-subdir}"
  SSL_KEY_LENGTH="${SSL_KEY_LENGTH:-ec-256}"
  SSL_RENEW_DAYS="${SSL_RENEW_DAYS:-30}"
  SSL_DNS_SLEEP="${SSL_DNS_SLEEP:-20}"
  SSL_RELOAD_CMD="${SSL_RELOAD_CMD:-}"
  SSL_POST_HOOK="${SSL_POST_HOOK:-}"
  SSL_KEEP_GOING="${SSL_KEEP_GOING:-1}"
  SSL_UNIT_NAME="${SSL_UNIT_NAME:-ssl-renew}"

  case "$SSL_OUTPUT_LAYOUT" in
    subdir | flat) ;;
    *) die "SSL_OUTPUT_LAYOUT 只能是 subdir 或 flat，当前为：${SSL_OUTPUT_LAYOUT}" ;;
  esac

  if ! [[ "$SSL_RENEW_DAYS" =~ ^[0-9]+$ ]]; then
    die "SSL_RENEW_DAYS 必须是整数天数，当前为：${SSL_RENEW_DAYS}"
  fi

  case "$SSL_KEY_LENGTH" in
    ec-*)           IS_ECC=1 ;;
    2048|3072|4096) IS_ECC=0 ;;
    *) die "SSL_KEY_LENGTH 只支持 ec-256 / ec-384 / 2048 / 3072 / 4096，当前为：${SSL_KEY_LENGTH}" ;;
  esac

  case "$SSL_UNIT_NAME" in
    ''|*[!A-Za-z0-9_.@-]*)
      die "SSL_UNIT_NAME 只能是字母 / 数字 / _ . @ -，当前为：${SSL_UNIT_NAME}
  它用来拼 systemd unit 名（<SSL_UNIT_NAME>.service / <SSL_UNIT_NAME>.timer）。" ;;
  esac

  case "$SSL_OUTPUT_DIR" in
    /*) SSL_DIR="${SSL_OUTPUT_DIR}" ;;
    *)  SSL_DIR="${PROJECT_ROOT}/${SSL_OUTPUT_DIR}" ;;
  esac

  # 运行摘要日志，放在证书目录下（该目录已被 .gitignore 整体排除）。
  # 为什么不只靠 systemd journal：CentOS 8 的 journal 默认**不持久化**
  # （只写 /run/log/journal），一重启就没了 —— 事后没法判断"上次到底成没成"。
  SSL_RUN_LOG="${SSL_DIR}/renew.log"
}

# -----------------------------------------------------------------------------
#  载入密钥 secrets.env（多服务商 × 多账号）
#
#  ★ 判断"有哪些账号"只看文件内容，不看环境变量 ——
#    否则外部环境里恰好存在的同名变量会被误当成一个账号。
# -----------------------------------------------------------------------------
SECRET_ID_TAIL=""   # default 账号（腾讯云）的尾号（保留给旧调用点）

# 检测"同名凭据变量被定义多次"（纯文本扫描，不读值，文件不存在时静默跳过）
#
#  ★ 为什么要单独做这一道：secrets.env 是 source 进来的，同名变量**后者覆盖前者**。
#    如果文件里躺着两组凭据，最坏情况是 ID 取到第一组、KEY 取到第二组 ——
#    拿着 A 的 SecretId 配 B 的 SecretKey 去签名。腾讯云只会回一句
#    AuthFailure.SignatureFailure，而两组 Key 的**长度和字符集都完全合法**，
#    从形状上根本查不出来（2026-10-28 生产踩过，排查了两轮）。
#    宁可在这里明确报错，也不要在两套凭据之间默默挑一个。
check_duplicate_secret_vars() {
  [ -f "$SECRETS_FILE" ] || return 0

  local dup_names
  dup_names="$(
    sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\?\(Tencent_SecretId[A-Za-z0-9_]*\|Tencent_SecretKey[A-Za-z0-9_]*\|GD_Key[A-Za-z0-9_]*\|GD_Secret[A-Za-z0-9_]*\)[[:space:]]*=.*/\2/p' "$SECRETS_FILE" \
      | sort | uniq -d | tr '\n' ' '
  )"
  if [ -n "${dup_names// /}" ]; then
    die "${SECRETS_FILE}：以下变量被定义了多次：${dup_names}
  本文件是 source 进来的，同名变量**后面的会覆盖前面的**。
  一旦两组凭据的 ID 与 KEY 顺序错开，就会拿 A 的 SecretId 配 B 的 SecretKey 去签名，
  腾讯云只会回 AuthFailure.SignatureFailure（两组 Key 的形状都合法，查不出来）。
  请只保留一组，其余整组注释掉（行首加 #）或删除：
      grep -n 'Tencent_SecretId\\|Tencent_SecretKey\\|GD_Key\\|GD_Secret' ${SECRETS_FILE}"
  fi
}

load_secrets() {
  if [ ! -f "$SECRETS_FILE" ]; then
    die "找不到密钥文件：${SECRETS_FILE}
  请执行：
      cp ${SSL_LIB_DIR}/secrets.env.example ${SECRETS_FILE}
      chmod 600 ${SECRETS_FILE}
  然后填入 DNS 服务商的 API 凭据（可以填多个服务商、每个服务商多个账号）。"
  fi

  set -a
  # shellcheck disable=SC1090
  . "$SECRETS_FILE"
  set +a

  check_duplicate_secret_vars

  ACCOUNT_COUNT=0
  ACCOUNT_PROV=()
  ACCOUNT_NAMES=()
  ACCOUNT_TAILS=()
  ACCOUNT_IDS=()
  ACCOUNT_KEYS=()

  # 扫描顺序：腾讯云（Tencent_SecretId*）→ GoDaddy（GD_Key*）
  # ★ 新增服务商第 ② 处
  local vn prov suffix name sid skey clean_id clean_key keyv perm
  while IFS= read -r vn; do
    case "$vn" in
      Tencent_SecretId)   prov="tencent"; name="default"; suffix="" ;;
      Tencent_SecretId_*) prov="tencent"; name="${vn#Tencent_SecretId_}"; suffix="_${name}" ;;
      GD_Key)             prov="godaddy"; name="default"; suffix="" ;;
      GD_Key_*)           prov="godaddy"; name="${vn#GD_Key_}"; suffix="_${name}" ;;
      *) continue ;;
    esac
    [ -n "$name" ] || continue

    sid="${!vn:-}"
    keyv="$(provider_key_var "$prov")${suffix}"
    skey="${!keyv:-}"
    clean_id="${sid//[[:space:]]/}"
    clean_key="${skey//[[:space:]]/}"

    if [ -z "$clean_id" ] || [ -z "$clean_key" ]; then
      die "${SECRETS_FILE}：$(provider_display "$prov") 账号 '${name}' 没填全。
  id 和 key 必须成对出现，变量名后缀要完全一致：
      $(provider_id_var "$prov")${suffix}=\"...\"
      $(provider_key_var "$prov")${suffix}=\"...\"
$(provider_cred_help "$prov")"
    fi

    # 腾讯云的 SecretId 以 AKID 开头、长度固定；GoDaddy 的 Key 短一些，
    # 所以只做"别明显是空的 / 半个"这种粗校验，不卡具体长度。
    if [ "$prov" = "tencent" ] && [ "${#clean_id}" -lt 8 ]; then
      die "${SECRETS_FILE}：腾讯云账号 '${name}' 的 SecretId 看起来不完整（长度 ${#clean_id}）"
    fi
    if [ "${#clean_id}" -lt 4 ] || [ "${#clean_key}" -lt 4 ]; then
      die "${SECRETS_FILE}：$(provider_display "$prov") 账号 '${name}' 的凭据太短，像是没填完"
    fi

    ACCOUNT_PROV+=("$prov")
    ACCOUNT_NAMES+=("$name")
    ACCOUNT_TAILS+=("${clean_id: -4}")
    ACCOUNT_IDS+=("$clean_id")
    ACCOUNT_KEYS+=("$clean_key")
  done < <(sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\?\(Tencent_SecretId[A-Za-z0-9_]*\|GD_Key[A-Za-z0-9_]*\)[[:space:]]*=.*/\2/p' "$SECRETS_FILE")

  ACCOUNT_COUNT="${#ACCOUNT_NAMES[@]}"

  if [ "$ACCOUNT_COUNT" -eq 0 ]; then
    local w="" p
    for p in $(provider_list); do
      w="${w}
      $(provider_id_var "$p")=\"\"
      $(provider_key_var "$p")=\"\""
    done
    die "没有在 ${SECRETS_FILE} 里识别到任何 DNS 凭据。至少要填一个服务商的一组：
${w}

  多个账号：给变量名加后缀（后缀就是 domains.conf 里的 account= 名字）：
      Tencent_SecretId_ACC2 / Tencent_SecretKey_ACC2     （腾讯云）
      GD_Key_GD2           / GD_Secret_GD2               （GoDaddy）

  然后在 domains.conf 里用 dns= 选服务商、account= 选账号。"
  fi

  local i
  for ((i = 0; i < ACCOUNT_COUNT; i++)); do
    if [ "${ACCOUNT_PROV[i]}" = "tencent" ] && [ "${ACCOUNT_NAMES[i]}" = "default" ]; then
      SECRET_ID_TAIL="${ACCOUNT_TAILS[i]}"
    fi
  done

  # 权限体检：密钥文件不应该对 group/other 可读
  perm="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || stat -f '%A' "$SECRETS_FILE" 2>/dev/null || echo '')"
  case "$perm" in
    600|400|'') ;;
    *) warn "${SECRETS_FILE} 权限是 ${perm}，建议收紧：chmod 600 ${SECRETS_FILE}" ;;
  esac
}

# -----------------------------------------------------------------------------
#  账号辅助函数（account_* 需先 load_secrets；accounts_declared_in_file 不需要）
# -----------------------------------------------------------------------------

# 账号是否已定义：  account_exists <服务商> <账号名>
account_exists() {
  local prov="$1" want="$2" i
  for ((i = 0; i < ACCOUNT_COUNT; i++)); do
    if [ "${ACCOUNT_PROV[i]}" = "$prov" ] && [ "${ACCOUNT_NAMES[i]}" = "$want" ]; then
      return 0
    fi
  done
  return 1
}

# ID 尾号 —— 日志里用尾号辨认账号，不泄露完整密钥。
#   account_tail <服务商> <账号名>
account_tail() {
  local prov="$1" want="$2" i
  for ((i = 0; i < ACCOUNT_COUNT; i++)); do
    if [ "${ACCOUNT_PROV[i]}" = "$prov" ] && [ "${ACCOUNT_NAMES[i]}" = "$want" ]; then
      printf '%s' "${ACCOUNT_TAILS[i]}"; return 0
    fi
  done
  printf '?'
}

# 已定义的账号，形如 "tencent:default godaddy:GD2"（空格分隔）
account_list_names() {
  local i out=""
  for ((i = 0; i < ACCOUNT_COUNT; i++)); do
    out="${out}${ACCOUNT_PROV[i]}:${ACCOUNT_NAMES[i]} "
  done
  printf '%s' "${out% }"
}

# 切换当前生效的凭据到指定账号：  account_activate <服务商> <账号名>
#
# acme.sh 的钩子固定读"输出槽"（tencent→Tencent_SecretId/Tencent_SecretKey，
# godaddy→GD_Key/GD_Secret），所以把槽位覆盖成目标账号的值就够了。
#
# ★ 值一律从 ACCOUNT_IDS / ACCOUNT_KEYS 里取，绝不从当前槽位回读 ——
#   因为 default 账号的密钥就"住"在那个槽位里，
#   一旦被别的账号覆写，回读只会拿到上一个账号的密钥（串号）。
# ★ 先把**所有**服务商的槽位清空，再写入目标服务商的那一组 ——
#   这样即使前一张证书用的是另一个服务商的账号，也不会残留串过来。
account_activate() {
  local prov="$1" acct="$2" i
  export Tencent_SecretId="" Tencent_SecretKey="" GD_Key="" GD_Secret=""

  for ((i = 0; i < ACCOUNT_COUNT; i++)); do
    if [ "${ACCOUNT_PROV[i]}" = "$prov" ] && [ "${ACCOUNT_NAMES[i]}" = "$acct" ]; then
      # 刻意写成显式 case（而不是用 provider_id_var 动态取变量名）：
      # 这是凭据切换的关键路径，可读、可审计比"少写两行"重要。
      # ★ 新增服务商第 ③ 处
      case "$prov" in
        tencent)
          export Tencent_SecretId="${ACCOUNT_IDS[i]}"
          export Tencent_SecretKey="${ACCOUNT_KEYS[i]}" ;;
        godaddy)
          export GD_Key="${ACCOUNT_IDS[i]}"
          export GD_Secret="${ACCOUNT_KEYS[i]}" ;;
      esac
      return 0
    fi
  done

  # 账号不存在：槽位保持清空。宁可让 acme.sh 明确报"没给密钥"，
  # 也绝不能让它拿着上一个账号的凭据去签 —— 那才是最坏的结果。
  return 1
}

# 校验 domains.conf 里出现的 (服务商, 账号) 都已在 secrets.env 里定义
verify_accounts() {
  local i bad=0 acct prov
  for ((i = 0; i < CERT_COUNT; i++)); do
    prov="${CERT_PROV[i]}"
    acct="${CERT_ACCOUNT[i]}"
    if ! account_exists "$prov" "$acct"; then
      warn "${DOMAINS_FILE}：${CERT_PRIMARY[i]} 指定了 dns=${prov} account=${acct}，但 ${SECRETS_FILE} 里没有这个组合"
      bad=1
    fi
  done
  if [ "$bad" = 1 ]; then
    local recipe="" p
    for p in $(provider_list); do
      recipe="${recipe}
      ${p} default ： $(provider_id_var "$p") / $(provider_key_var "$p")
      ${p} 其他    ： $(provider_id_var "$p")_<账号名> / $(provider_key_var "$p")_<账号名>"
    done
    die "已定义的账号：$(account_list_names)
  在 ${SECRETS_FILE} 里补一组配对的变量（后缀必须和 account= 完全一致）：${recipe}"
  fi
}

# 只提取密钥文件里"声明了哪些账号"（纯读变量名，不读密钥值），
# 输出形如 "tencent:default" / "godaddy:GD2"。
# 给 ssl-status.sh 用 —— 它不该为了看状态而载入密钥，但需要校验账号名拼写。
accounts_declared_in_file() {
  local f="${1:-$SECRETS_FILE}" vn name
  [ -f "$f" ] || return 0
  while IFS= read -r vn; do
    case "$vn" in
      Tencent_SecretId)   printf 'tencent:default\n' ;;
      Tencent_SecretId_*)
        name="${vn#Tencent_SecretId_}"
        [ -n "$name" ] && printf 'tencent:%s\n' "$name" ;;
      GD_Key)             printf 'godaddy:default\n' ;;
      GD_Key_*)
        name="${vn#GD_Key_}"
        [ -n "$name" ] && printf 'godaddy:%s\n' "$name" ;;
    esac
  done < <(sed -n 's/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\?\(Tencent_SecretId[A-Za-z0-9_]*\|GD_Key[A-Za-z0-9_]*\)[[:space:]]*=.*/\2/p' "$f")
}

# 清掉 acme.sh 写进 ~/.acme.sh/account.conf 的凭据副本。
# 钩子会调 _saveaccountconf_mutable 存一份（腾讯云：SAVED_Tencent_SecretId/Key；
# GoDaddy：SAVED_GD_Key/Secret）。多账号下这个副本既多余、又可能和当前账号
# 不一致，所以签完就清掉。我们每次签发前都会显式导出凭据，清掉不影响续期。
#
# ★ 用 ^SAVED_ 一把清，不逐个服务商列 —— 以后加服务商不用再回来改这里。
#   前提：调度用本套自己的 timer，且 ensure_acme 已移除 acme.sh 自带的 cronjob，
#   所以不存在"别的任务依赖 account.conf 里那份凭据"的情况。
# 返回 0 = 确实清掉了，返回 1 = 本来就没有 / 文件不存在。
scrub_acme_account_conf() {
  local f="${ACME_HOME}/account.conf"
  [ -f "$f" ] || return 1
  if grep -q '^SAVED_' "$f" 2>/dev/null; then
    if sed -i '/^SAVED_/d' "$f" 2>/dev/null; then
      return 0
    fi
  fi
  return 1
}

# -----------------------------------------------------------------------------
#  载入域名列表 domains.conf
#
#  每行一张证书，格式：
#      <域名1> <域名2> ...   [|  选项]
#  选项： renew=<天数>  dir=<输出子目录名>  dns=<服务商>  account=<账号名>
#
#  ★ 同一行的所有域名必须同属一个 DNS 服务商、且同属该服务商下的同一个账号 ——
#    DNS-01 验证是一次调用写完整行的 TXT 记录，acme.sh 一次只能用一套凭据。
#    域名跨服务商 / 跨账号时必须拆成两行。
# -----------------------------------------------------------------------------
load_domains() {
  if [ ! -f "$DOMAINS_FILE" ]; then
    die "找不到域名列表：${DOMAINS_FILE}"
  fi

  CERT_DIR=(); CERT_DOMAINS=(); CERT_RENEW=(); CERT_PRIMARY=()
  CERT_ACCOUNT=(); CERT_PROV=()

  local raw line lineno=0 domains opts kv k v dir renew acct prov
  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))

    # 去掉注释与首尾空白
    line="${raw%%#*}"
    line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    if [ -z "$line" ]; then continue; fi

    # 用 | 拆出域名部分和选项部分
    domains="${line%%|*}"
    if [ "$domains" = "$line" ]; then
      opts=""
    else
      opts="${line#*|}"
    fi
    domains="$(printf '%s' "$domains" | tr -s '[:space:]' ' ' | sed -e 's/^ *//' -e 's/ *$//')"

    dir=""; renew=""; acct=""; prov=""
    for kv in $opts; do
      k="${kv%%=*}"; v="${kv#*=}"
      case "$k" in
        renew)   renew="$v" ;;
        dir)     dir="$v" ;;
        dns)     prov="$v" ;;
        account) acct="$v" ;;
        *) die "${DOMAINS_FILE} 第 ${lineno} 行：未知选项 '${k}'（本版本支持 renew= / dir= / dns= / account=）" ;;
      esac
    done

    if [ -z "$domains" ]; then
      die "${DOMAINS_FILE} 第 ${lineno} 行：只写了选项、没有域名"
    fi

    # set -f 关闭 glob：否则 *.example.com 会被 shell 展开成当前目录下的文件名
    local -a darr=()
    set -f
    # shellcheck disable=SC2206
    darr=( $domains )
    set +f

    if [ "${#darr[@]}" -eq 0 ]; then
      die "${DOMAINS_FILE} 第 ${lineno} 行：域名解析为空"
    fi

    local d
    for d in "${darr[@]}"; do
      if ! [[ "$d" =~ ^(\*\.)?([A-Za-z0-9_]([A-Za-z0-9_-]*[A-Za-z0-9_])?\.)+[A-Za-z]{2,}$ ]]; then
        die "${DOMAINS_FILE} 第 ${lineno} 行：域名格式不合法 '${d}'"
      fi
    done

    local primary="${darr[0]}"
    case "$primary" in
      \*.*)
        die "${DOMAINS_FILE} 第 ${lineno} 行：第一个域名不能是泛域名（${primary}）。
  acme.sh 用第一个域名作为证书目录名，请把主域名放最前面，例如：
      ${primary#\*.} *.${primary#\*.}" ;;
    esac

    if [ -z "$dir" ]; then dir="$primary"; fi
    case "$dir" in
      */*|.|..) die "${DOMAINS_FILE} 第 ${lineno} 行：dir= 只能是目录名，不能包含 / 或 ." ;;
    esac

    if [ -z "$renew" ]; then renew="$SSL_RENEW_DAYS"; fi
    if ! [[ "$renew" =~ ^[0-9]+$ ]]; then
      die "${DOMAINS_FILE} 第 ${lineno} 行：renew= 必须是整数天数，当前为 '${renew}'"
    fi

    # DNS 服务商：不写就是 tencent（老配置零改动）
    if [ -z "$prov" ]; then prov="tencent"; fi
    if ! provider_valid "$prov"; then
      die "${DOMAINS_FILE} 第 ${lineno} 行：dns= 只支持 $(provider_list)，当前为 '${prov}'"
    fi

    # 账号名：不写就是 default。这里只校验"格式"；
    # "这个 (服务商, 账号) 到底定义了没有"由 verify_accounts 在载入密钥后校验
    # —— 这样 --check-only（不载入密钥）也能正常体检。
    if [ -z "$acct" ]; then acct="default"; fi
    if ! [[ "$acct" =~ ^[A-Za-z0-9_]+$ ]]; then
      die "${DOMAINS_FILE} 第 ${lineno} 行：account= 只能用字母 / 数字 / 下划线，当前为 '${acct}'。
  它对应 ${SECRETS_FILE} 里的变量名（以 dns=${prov} 为例）：
      $(provider_id_var "$prov")_<账号名> / $(provider_key_var "$prov")_<账号名>"
    fi

    CERT_DIR+=("$dir")
    CERT_DOMAINS+=("${darr[*]}")
    CERT_RENEW+=("$renew")
    CERT_PRIMARY+=("$primary")
    CERT_ACCOUNT+=("$acct")
    CERT_PROV+=("$prov")
  done < "$DOMAINS_FILE"

  CERT_COUNT="${#CERT_PRIMARY[@]}"

  if [ "$CERT_COUNT" -eq 0 ]; then
    die "${DOMAINS_FILE} 里没有任何生效的域名。
  请把示例行前面的 # 去掉，改成你自己的域名，例如：
      example.com www.example.com *.example.com"
  fi

  # 重复检查：主域名和输出目录都必须唯一，否则会互相覆盖
  local i j
  for ((i = 0; i < CERT_COUNT; i++)); do
    for ((j = i + 1; j < CERT_COUNT; j++)); do
      if [ "${CERT_PRIMARY[i]}" = "${CERT_PRIMARY[j]}" ]; then
        die "${DOMAINS_FILE}：主域名 ${CERT_PRIMARY[i]} 重复出现（第 $((i + 1)) 条与第 $((j + 1)) 条）。
  每张证书的主域名必须唯一。"
      fi
      if [ "${CERT_DIR[i]}" = "${CERT_DIR[j]}" ]; then
        die "${DOMAINS_FILE}：输出目录 ${CERT_DIR[i]} 重复（第 $((i + 1)) 条与第 $((j + 1)) 条），会互相覆盖。"
      fi
    done
  done
}

# 一次性载入全部配置：策略 -> 密钥 -> 域名
load_all() {
  load_policy
  load_secrets
  load_domains
}

# 该证书列表里实际用到了哪些服务商（空格分隔）—— 体检/连通性检查用
providers_in_use() {
  local i out="" seen=" " p
  for ((i = 0; i < CERT_COUNT; i++)); do
    p="${CERT_PROV[i]}"
    case "$seen" in *" $p "*) continue ;; esac
    seen="${seen}${p} "
    out="${out}${p} "
  done
  printf '%s' "${out% }"
}

# -----------------------------------------------------------------------------
#  续期后置钩子（有证书真的更新了才跑）
# -----------------------------------------------------------------------------

# 解析钩子脚本路径，没有就输出空串。
#   ① ssl.conf 里 SSL_POST_HOOK 非空 -> 用它（相对路径按脚本目录解析）
#   ② 否则用 <脚本目录>/renewpost.sh
#
# ★ 永远 return 0 —— 不然调用处 hook="$(resolve_post_hook)" 在 set -e 下会被判定失败而退出。
resolve_post_hook() {
  local p="${SSL_POST_HOOK:-}"
  if [ -n "$p" ]; then
    case "$p" in
      /*) printf '%s' "$p" ;;
      *)  printf '%s' "${SSL_LIB_DIR}/${p}" ;;
    esac
    return 0
  fi
  if [ -f "${SSL_LIB_DIR}/renewpost.sh" ]; then
    printf '%s' "${SSL_LIB_DIR}/renewpost.sh"
  fi
  return 0
}

# 追加一行运行摘要到 <证书目录>/renew.log。
#   write_run_log <OK|FAIL> <处理数> <更新数> <跳过数> <失败数> [附加说明]
#
# 写失败（比如目录只读）不视为错误，绝不能让记日志这件事影响证书续期本身。
write_run_log() {
  local status="$1" total="$2" updated="$3" skipped="$4" failed="$5" extra="${6:-}"
  local target="${SSL_RUN_LOG:-}"
  if [ -z "$target" ]; then
    # 配置尚未解析就走到这里（load_policy 之前失败）。
    # 退回备用文件 —— 宁可记在"备用"里，也不能让这次运行凭空消失。
    target="${SSL_RUN_LOG_FALLBACK}"
    if [ -n "$extra" ]; then
      extra="${extra}；日志路径未解析，已写入备用文件"
    else
      extra="日志路径未解析，已写入备用文件"
    fi
  fi
  [ -n "$target" ] || return 0
  mkdir -p "$(dirname "$target")" 2>/dev/null || return 0
  {
    printf '%s  %-4s 处理=%-3s 更新=%-3s 跳过=%-3s 失败=%-3s' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$status" "$total" "$updated" "$skipped" "$failed"
    if [ -n "$extra" ]; then printf '  %s' "$extra"; fi
    printf '\n'
  } >> "$target" 2>/dev/null || true
  return 0
}

# =============================================================================
#  证书路径推导
# =============================================================================

# 证书所在目录（绝对路径）： cert_outdir <子目录名>
cert_outdir() {
  case "$SSL_OUTPUT_LAYOUT" in
    flat) printf '%s' "$SSL_DIR" ;;
    *)    printf '%s/%s' "$SSL_DIR" "$1" ;;
  esac
}

# flat 布局下的文件名前缀
cert_prefix() {
  case "$SSL_OUTPUT_LAYOUT" in
    flat) printf '%s.' "$1" ;;
    *)    printf '' ;;
  esac
}

# 证书文件完整路径： cert_file <子目录名> <文件名>
cert_file() {
  printf '%s/%s%s' "$(cert_outdir "$1")" "$(cert_prefix "$1")" "$2"
}

# =============================================================================
#  读取证书信息
# =============================================================================

# 剩余天数；证书不存在或无法解析时输出空字符串
cert_remaining_days() {
  local f; f="$(cert_file "$1" fullchain.pem)"
  if [ ! -f "$f" ]; then printf ''; return 0; fi

  local end e now
  end="$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2)"
  if [ -z "$end" ]; then printf ''; return 0; fi

  e="$(date -d "$end" +%s 2>/dev/null || echo 0)"
  now="$(date +%s)"
  if [ "$e" -le 0 ]; then printf ''; return 0; fi

  printf '%s' "$(( (e - now) / 86400 ))"
}

# 到期时间（原始格式，如 "Dec 17 05:33:31 2026 GMT"）
cert_enddate() {
  local f; f="$(cert_file "$1" fullchain.pem)"
  if [ ! -f "$f" ]; then printf ''; return 0; fi
  openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2
}

# 到期时间（本地格式，便于阅读）
cert_enddate_local() {
  local raw; raw="$(cert_enddate "$1")"
  if [ -z "$raw" ]; then printf ''; return 0; fi
  date -d "$raw" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '%s' "$raw"
}

# 证书里实际包含的域名（排序去重，空格分隔）；取不到时输出空
#
# ★ 不要用 `openssl x509 -ext subjectAltName` —— 这是 OpenSSL 3.0 才有的选项，
#   CentOS 8 自带的 OpenSSL 1.1.1k 没有，会静默失败（报错被 2>/dev/null 吞掉，
#   管道尾部 sed 退出码为 0，所以不会报错、只会返回空），后果是：
#     · "证书域名" 一栏永远空白
#     · cert_decide 里"域名列表变了就重签"那条规则失效
#   改用 -text + awk 抓 SAN 那一段，1.1.1 和 3.x 都能跑。
cert_san_list() {
  local f; f="$(cert_file "$1" fullchain.pem)"
  if [ ! -f "$f" ]; then return 0; fi
  openssl x509 -in "$f" -noout -text 2>/dev/null \
    | awk '/Subject Alternative Name/{getline; print; exit}' \
    | tr -d '[:space:]' | tr ',' '\n' \
    | sed -n 's/^DNS://p' | sort -u | tr '\n' ' ' \
    | sed -e 's/ *$//'
}

# acme.sh 记录的下次续期时间（读取 ~/.acme.sh 里的元数据）；取不到时输出空
acme_next_renew() {
  local primary="$1" f
  for f in "${ACME_HOME}/${primary}_ecc/${primary}.conf" "${ACME_HOME}/${primary}/${primary}.conf"; do
    if [ -f "$f" ]; then
      sed -n "s/^Le_NextRenewTimeStr='\(.*\)'$/\1/p" "$f" | head -n1
      return 0
    fi
  done
}

# 把配置里的域名（空格分隔字符串）转成排序去重的空格分隔字符串
normalize_domain_string() {
  local -a d=()
  set -f
  # shellcheck disable=SC2206
  d=( $1 )
  set +f
  printf '%s\n' "${d[@]}" | sort -u | tr '\n' ' ' | sed -e 's/ *$//'
}

# =============================================================================
#  续期决策 —— 整套逻辑的核心
#
#  输出: "<0|1>|<原因>"
#    0 = 无需动作
#    1 = 需要签发/续期
#
#  判定顺序：
#    1. 证书不存在           -> 需要（首次签发）
#    2. 证书已过期           -> 需要
#    3. 剩余天数 <= 本证书阈值 -> 需要
#    4. 证书里的域名集合 != 配置 -> 需要（改了 domains.conf 就能自动重签）
#    5. 其余                  -> 不需要
#
#  ★ 阈值取自该证书自己的 renew（domains.conf 可覆盖），
#    不依赖 acme.sh 的内部调度，所以这里的判断就是最终结论。
# =============================================================================
cert_decide() {
  local idx="$1"
  local dir="${CERT_DIR[idx]}"
  local renew="${CERT_RENEW[idx]}"
  local remaining
  remaining="$(cert_remaining_days "$dir")"

  if [ -z "$remaining" ]; then
    printf '1|首次签发'
    return 0
  fi

  if [ "$remaining" -lt 0 ]; then
    printf '1|证书已过期 %d 天' "$(( -remaining ))"
    return 0
  fi

  if [ "$remaining" -le "$renew" ]; then
    printf '1|剩余 %d 天 ≤ 本证书阈值 %d 天' "$remaining" "$renew"
    return 0
  fi

  local deployed configured
  deployed="$(cert_san_list "$dir")"
  configured="$(normalize_domain_string "${CERT_DOMAINS[idx]}")"
  if [ -n "$deployed" ] && [ "$deployed" != "$configured" ]; then
    printf '1|域名列表有变化（配置 %s / 证书 %s）' "$configured" "$deployed"
    return 0
  fi

  printf '0|剩余 %d 天 > 阈值 %d 天，未到续期时间' "$remaining" "$renew"
}

# 状态标签（用于表格）： 未签发 / 已过期 / 待续期 / 正常
cert_status_label() {
  local idx="$1"
  local remaining
  remaining="$(cert_remaining_days "${CERT_DIR[idx]}")"
  local renew="${CERT_RENEW[idx]}"

  if [ -z "$remaining" ]; then
    printf '未签发'
  elif [ "$remaining" -lt 0 ]; then
    printf '已过期'
  elif [ "$remaining" -le "$renew" ]; then
    printf '待续期'
  else
    printf '正常'
  fi
}

# 账号列显示内容： provider:account
# （两个服务商下都叫 default 时不会混淆）
cert_account_label() {
  printf '%s:%s' "${CERT_PROV[$1]}" "${CERT_ACCOUNT[$1]}"
}

# 表格表头。空格是按"显示宽度"手工对齐的（CJK 按 2 列计算），
# 所以不能交给 printf 的 %-Ns —— 那按字节算，中文会错位。
#
# 对齐依据（改列宽时照此推算）：
#   状态列：行里是 %-8s，中文标签 3 字 = 9 字节不补、2 字补到 8 字节，
#           两种都恰好占 6 显示列；表头 "状态" 只有 4 列，所以后面补 4 个空格。
#   账号列：行里是 %-18s，前面还有 2 空格 → 下一列在账号起点 +20。
#           表头 "账号" 占 4 列，所以要补 16 个空格才和 plan 模式的"动作"对齐。
table_header() {
  if [ "${1:-}" = "plan" ]; then
    printf '%s' "证书（主域名）                  域名数   阈值天          到期时间     剩余  状态    账号                动作"
  else
    printf '%s' "证书（主域名）                  域名数   阈值天          到期时间     剩余  状态    账号"
  fi
}

# 渲染证书状态表
#   $1 = ""      仅状态
#   $1 = "plan"  额外显示"将要执行的动作"
#   $2 $3        可选，起止下标（配合 --domain 只显示一张）
render_cert_table() {
  local with_plan="${1:-}"
  local from="${2:-0}"
  local to="${3:-$((CERT_COUNT - 1))}"
  local i

  printf '\n  %s%s%s\n' "$C_BLD" "$(table_header "$with_plan")" "$C_RST"
  rule
  printf '  %s账号列格式： 服务商:账号名%s\n' "$C_DIM" "$C_RST"

  for ((i = from; i <= to; i++)); do
    local primary="${CERT_PRIMARY[i]}"
    local dir="${CERT_DIR[i]}"
    local renew="${CERT_RENEW[i]}"
    local -a d=()
    set -f
    # shellcheck disable=SC2206
    d=( ${CERT_DOMAINS[i]} )
    set +f

    local remaining end_str label color
    remaining="$(cert_remaining_days "$dir")"
    label="$(cert_status_label "$i")"

    case "$label" in
      正常)   color="$C_GRN" ;;
      待续期) color="$C_YEL" ;;
      已过期) color="$C_RED" ;;
      *)      color="$C_DIM" ;;
    esac

    local remaining_disp
    if [ -z "$remaining" ]; then
      end_str="—"; remaining_disp="—"
    else
      end_str="$(cert_enddate_local "$dir")"
      remaining_disp="${remaining}天"
    fi

    printf '  %-30s %7s %6s天 %18s %9s  %s%-8s%s  %-18s' \
      "$primary" "${#d[@]}" "$renew" "$end_str" "$remaining_disp" \
      "$color" "$label" "$C_RST" "$(cert_account_label "$i")"

    if [ "$with_plan" = "plan" ]; then
      local decision need why
      decision="$(cert_decide "$i")"
      need="${decision%%|*}"
      why="${decision#*|}"
      if [ "$need" = "1" ]; then
        printf '  %s→ 签发/续期%s\n' "$C_YEL" "$C_RST"
        printf '       %s└ %s%s\n' "$C_DIM" "$why" "$C_RST"
      else
        printf '  %s→ 跳过%s\n' "$C_DIM" "$C_RST"
        printf '       %s└ %s%s\n' "$C_DIM" "$why" "$C_RST"
      fi
    else
      printf '\n'
    fi
  done
}
