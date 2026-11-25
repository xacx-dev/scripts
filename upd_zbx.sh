#!/usr/bin/env bash
# Interactive source-only Zabbix rollout. Requires Bash 4+, OpenSSH, coreutils.
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C
STATE=${ZABBIX_SOURCE_STATE:-"$HOME/.local/state/zabbix-cod-source"}
declare -A CFG=() SUDO_SECRET=() H_ADDR=() H_PORT=() H_USER=() H_ROUTE=() H_KEY=()
TARGET_VERSION=7.0.32

say() { printf '%s\n' "$*"; }
err() { printf 'ОШИБКА: %s\n' "$*" >&2; return 1; }
valid_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$ ]]; }
valid_addr() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]; }
valid_user() { [[ $1 =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]]; }
valid_port() { [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
valid_path() { [[ $1 == /* && $1 != *$'\n'* && $1 != *$'\r'* && $1 != *$'\t'* ]]; }
tty_read() {
  local name=$1 prompt=$2 secret=${3:-no}
  [[ -r /dev/tty && -w /dev/tty ]] || { err 'Нужен интерактивный терминал.'; return 1; }
  printf '%s' "$prompt" >/dev/tty
  if [[ $secret == yes ]]; then IFS= read -r -s "$name" </dev/tty; printf '\n' >/dev/tty
  else IFS= read -r "$name" </dev/tty; fi
}
confirm_host() {
  local answer
  tty_read answer "Для выполнения введите имя узла $1: "
  [[ $answer == "$1" ]] || { say 'Отменено.'; return 1; }
}
kv_get() {
  local file=$1 key=$2 line
  [[ -r $file ]] || return 0
  line=$(awk -F '\t' -v k="$key" '$1==k {print $2; exit}' "$file")
  [[ -z $line ]] || printf '%s' "$line" | base64 -d 2>/dev/null
}
kv_set() {
  local file=$1 key=$2 value=$3 temp
  [[ $key =~ ^[a-z][a-z0-9_]*$ ]] || return 1
  temp=$(mktemp "$STATE/tmp/kv.XXXXXX")
  if [[ -f $file ]]; then awk -F '\t' -v k="$key" '$1!=k' "$file" >"$temp"; fi
  printf '%s\t' "$key" >>"$temp"
  printf '%s' "$value" | base64 | tr -d '\n' >>"$temp"
  printf '\n' >>"$temp"
  chmod 600 "$temp"; mv -f -- "$temp" "$file"
}
option_get() { kv_get "$STATE/options/$1.tsv" "$2"; }
option_set() { kv_set "$STATE/options/$1.tsv" "$2" "$3"; }

init_state() {
  local tool
  ((BASH_VERSINFO[0] >= 4)) || { err 'Требуется Bash 4 или новее.'; return 1; }
  for tool in ssh scp sha256sum awk sed base64 tar mktemp; do
    command -v "$tool" >/dev/null || { err "На управляющем сервере отсутствует $tool. Автоматической установки нет."; return 1; }
  done
  mkdir -p -- "$STATE" "$STATE/tmp" "$STATE/options" "$STATE/audit" "$STATE/builds" "$STATE/sources" "$STATE/sockets" "$STATE/logs"
  chmod 700 "$STATE" "$STATE/tmp" "$STATE/options" "$STATE/audit" "$STATE/builds" "$STATE/sources" "$STATE/sockets" "$STATE/logs"
  STATE=$(cd -- "$STATE" && pwd)
  [[ $STATE != *$'\n'* && $STATE != *$'\r'* && $STATE != *$'\t'* && $STATE != *'"'* ]] || { err 'Недопустимый путь состояния.'; return 1; }
  [[ ${#STATE} -lt 64 ]] || { err 'Слишком длинный путь состояния: задайте ZABBIX_SOURCE_STATE=/root/zabbix-src-state'; return 1; }
  if [[ ! -f $STATE/settings.tsv ]]; then
    kv_set "$STATE/settings.tsv" version "$TARGET_VERSION"
    kv_set "$STATE/settings.tsv" jump_host 176.211.53.177
    kv_set "$STATE/settings.tsv" jump_port 2074
    kv_set "$STATE/settings.tsv" jump_user root
  fi
  load_settings
  if [[ ! -f $STATE/hosts.tsv ]]; then
    printf '#name\taddress\tport\tuser\troute\tidentity_file\n' >"$STATE/hosts.tsv"
  fi
  load_hosts
}
load_settings() {
  local key
  for key in version jump_host jump_port jump_user jump_key; do CFG[$key]=$(kv_get "$STATE/settings.tsv" "$key"); done
  [[ ${CFG[version]} =~ ^7\.0\.[0-9]+$ ]] || { err 'В settings.tsv неверная версия: допустима 7.0.x.'; return 1; }
  valid_addr "${CFG[jump_host]}" && valid_port "${CFG[jump_port]}" && valid_user "${CFG[jump_user]}" || { err 'Некорректные настройки SSH-прокси.'; return 1; }
}
load_hosts() {
  local name address port user route key
  H_ADDR=(); H_PORT=(); H_USER=(); H_ROUTE=(); H_KEY=()
  while IFS=$'\t' read -r name address port user route key; do
    [[ -z $name || $name == \#* ]] && continue
    valid_id "$name" && valid_addr "$address" && valid_port "$port" && valid_user "$user" || { err "Некорректная строка hosts.tsv: $name"; return 1; }
    [[ $route == jump || $route == direct ]] || { err "Некорректный маршрут: $name"; return 1; }
    [[ ! ${H_ADDR[$name]+yes} ]] || { err "Повтор имени узла: $name"; return 1; }
    [[ -z $key ]] || valid_path "$key" || { err "Неверный путь ключа: $name"; return 1; }
    H_ADDR[$name]=$address; H_PORT[$name]=$port; H_USER[$name]=$user; H_ROUTE[$name]=$route; H_KEY[$name]=$key
  done <"$STATE/hosts.tsv"
}
require_host() { [[ ${H_ADDR[$1]+yes} ]] || { err "Нет узла $1. Используйте add или отредактируйте $STATE/hosts.tsv"; return 1; }; }
seed_known() {
  local id address
  while read -r id address;do
    [[ ${H_ADDR[$id]+yes} ]] || save_host "$id" "$address" 22 sysop jump ''
  done <<'KNOWN_ASTRA_COD'
COD05 192.168.1.41
COD09 192.168.1.45
COD13 192.168.1.49
COD14 192.168.1.188
COD15 192.168.1.62
COD16 192.168.1.63
COD17 192.168.1.64
COD18 192.168.1.65
COD19 192.168.1.66
COD20 192.168.1.67
COD21 192.168.1.68
KNOWN_ASTRA_COD
  say 'Добавлены 11 COD, отмеченных Astra в исправленной таблице. Остальные актуальные адреса добавьте через add; 25 адресов не угадываются.'
}
save_host() {
  local id=$1 address=$2 port=$3 user=$4 route=$5 key=${6:-} tmp
  valid_id "$id" && valid_addr "$address" && valid_port "$port" && valid_user "$user" || { err 'Неверные имя, адрес, пользователь или порт.'; return 1; }
  [[ $route == jump || $route == direct ]] || { err 'Маршрут должен быть jump или direct.'; return 1; }
  [[ -z $key ]] || valid_path "$key" || return 1
  tmp=$(mktemp "$STATE/tmp/hosts.XXXXXX")
  awk -F '\t' -v id="$id" '$1!=id' "$STATE/hosts.tsv" >"$tmp"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$address" "$port" "$user" "$route" "$key" >>"$tmp"
  mv -- "$tmp" "$STATE/hosts.tsv"; load_hosts
}
render_ssh() {
  local key=${CFG[jump_key]} escaped
  {
    printf 'Host zabbix-source-jump\n  HostName %s\n  Port %s\n  User %s\n' "${CFG[jump_host]}" "${CFG[jump_port]}" "${CFG[jump_user]}"
    if [[ -n $key ]]; then
      valid_path "$key" || return 1
      escaped=${key//\\/\\\\}; escaped=${escaped//\"/\\\"}
      printf '  IdentityFile "%s"\n' "$escaped"
    fi
    printf '  HostKeyAlias cod-source-jump\nHost *\n  ForwardAgent no\n  StrictHostKeyChecking accept-new\n'
    printf '  UserKnownHostsFile "%s/known_hosts"\n  ConnectTimeout 15\n  ServerAliveInterval 30\n  ServerAliveCountMax 3\n' "$STATE"
  } >"$STATE/ssh_config"
  chmod 600 "$STATE/ssh_config"
}
declare -a SSH_ARGS SCP_ARGS
connection_args() {
  local id=$1 socket_id
  require_host "$id"; render_ssh
  socket_id=$(printf '%s' "$id|${H_ADDR[$id]}|${H_PORT[$id]}|${H_USER[$id]}|${H_ROUTE[$id]}|${H_KEY[$id]}|${CFG[jump_host]}|${CFG[jump_port]}|${CFG[jump_user]}|${CFG[jump_key]}" | sha256sum | cut -c 1-16)
  SSH_ARGS=(-F "$STATE/ssh_config" -p "${H_PORT[$id]}" -l "${H_USER[$id]}" -o "HostKeyAlias=cod-source-$id" -o ControlMaster=auto -o ControlPersist=180 -o "ControlPath=$STATE/sockets/$socket_id")
  SCP_ARGS=(-F "$STATE/ssh_config" -P "${H_PORT[$id]}" -o "User=${H_USER[$id]}" -o "HostKeyAlias=cod-source-$id" -o ControlMaster=auto -o ControlPersist=180 -o "ControlPath=$STATE/sockets/$socket_id")
  if [[ ${H_ROUTE[$id]} == jump ]]; then SSH_ARGS+=(-J zabbix-source-jump); SCP_ARGS+=(-J zabbix-source-jump); fi
  if [[ -n ${H_KEY[$id]} ]]; then SSH_ARGS+=(-i "${H_KEY[$id]}"); SCP_ARGS+=(-i "${H_KEY[$id]}"); fi
}
quote_command() { printf '%q ' "$@"; }
worker_payload() {
  cat <<'ZABBIX_EMBEDDED_WORKER_20261125'
#!/usr/bin/env bash
set +x
# Remote half of source-only Zabbix deployment. No package manager is invoked.
set -euo pipefail
umask 077
export LC_ALL=C
export GOPROXY=off GOTOOLCHAIN=local GOSUMDB=off

emit() { printf '%s\t' "$1"; printf '%s' "${2-}" | base64 | tr -d '\n'; printf '\n'; }
begin() { printf 'ZA_AUDIT_V1\n'; }
die() { emit error "$*"; printf '%s\n' "$*" >&2; exit 1; }
safe_path() { [[ "$1" =~ ^/[A-Za-z0-9_./+:-]+$ && "$1" != / && "$1" != *'/../'* && "$1" != */.. ]]; }
safe_service() { [[ "$1" =~ ^[A-Za-z0-9_@.-]+\.service$ && "$1" != .* ]]; }
safe_version() { [[ "$1" =~ ^7\.0\.[0-9]+$ ]]; }
require_root() { [[ $EUID -eq 0 ]] || die 'This action requires root or sudo.'; }
release_value() {
    local key=$1
    [[ -r /etc/os-release ]] || return 0
    awk -F= -v key="$key" '$1==key {v=substr($0,index($0,"=")+1);gsub(/^"|"$/, "",v);gsub(/^\047|\047$/, "",v);print v;exit}' /etc/os-release
}
is_astra() {
    [[ $(uname -s 2>/dev/null) == Linux ]] || return 1
    local id
    id=$(release_value ID)
    [[ -r /etc/astra_version || "${id,,}" == *astra* ]]
}
require_astra() { is_astra || die 'Only an actually detected Astra Linux host may be changed.'; }
canonical() { readlink -f -- "$1" 2>/dev/null || printf '%s' "$1"; }
version_of() {
    local line
    line=$("$1" -V 2>/dev/null | head -n 1) || return 1
    if [[ "$line" =~ \(Zabbix\)[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+)([[:space:]]|$) ]]; then printf '%s' "${BASH_REMATCH[1]}"; else return 1; fi
}
variant_of() {
    local line
    line=$("$1" -V 2>/dev/null | head -n 1) || return 1
    line=${line,,}
    if [[ "$line" == *agent2* || "$line" == *'agent 2'* ]]; then printf agent2
    elif [[ "$line" == *agentd* || "$line" == *'agent (daemon)'* || "$line" == *'zabbix agent'* ]]; then printf classic
    else return 1; fi
}
unit_prop() { systemctl show "$1" --no-pager -p "$2" --value 2>/dev/null || true; }

# Read literal KEY=/absolute/path only. Never execute EnvironmentFile content.
literal_assignment() {
    local file=$1 key=$2 value
    [[ -r "$file" ]] || return 0
    value=$(awk -v k="$key" '$0 ~ "^[ \\t]*(export[ \\t]+)?" k "=" {v=$0; sub("^[ \\t]*(export[ \\t]+)?" k "=", "", v);gsub(/^"|"$/, "",v);gsub(/^\047|\047$/, "",v);print v;exit}' "$file")
    if [[ -n "$value" ]] && safe_path "$value"; then printf '%s' "$value"; fi
}
resolved_config() {
    local service=$1 binary=$2 exec argv token envfile value name
    exec=$(unit_prop "$service" ExecStart)
    argv=${exec#*argv[]=}; argv=${argv%% ;*}
    token=$(printf '%s\n' "$argv" | sed -nE 's/.*(^|[[:space:]])(-c|--config)[=[:space:]]+([^[:space:];]+).*/\3/p' | head -n 1)
    if [[ -z "$token" ]];then token=$(printf '%s\n' "$argv" | sed -nE 's/.*(^|[[:space:]])-c(\/[^[:space:];]+).*/\2/p' | head -n 1);fi
    token=${token#\"};token=${token%\"};token=${token#\'};token=${token%\'}
    if [[ -n "$token" ]] && safe_path "$token"; then printf '%s' "$token"; return; fi
    if [[ "$token" =~ ^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ ]]; then
        name=${BASH_REMATCH[1]}
        value=$(unit_prop "$service" Environment | tr ' ' '\n' | sed -n "s/^${name}=//p" | head -n 1)
        value=${value#\"};value=${value%\"}
        if [[ -n "$value" ]] && safe_path "$value"; then printf '%s' "$value"; return; fi
        while IFS= read -r envfile; do
            [[ -n "$envfile" ]] || continue
            value=$(literal_assignment "$envfile" "$name")
            if [[ -n "$value" ]]; then printf '%s' "$value"; return; fi
        done < <(unit_prop "$service" EnvironmentFiles | grep -oE '/[A-Za-z0-9_./+-]+' || true)
    fi
    # No guessing of a compiled-in default: an explicit override is required.
}
service_binary() {
    local value
    value=$(unit_prop "$1" ExecStart)
    printf '%s\n' "$value" | sed -nE 's/.*path=([^ ;}]+).*/\1/p' | head -n 1
}
library_fingerprint() {
    local ldconfig paths file output=''
    ldconfig=$(command -v ldconfig 2>/dev/null || true)
    [[ -n "$ldconfig" ]] || { [[ ! -x /sbin/ldconfig ]] || ldconfig=/sbin/ldconfig; }
    [[ -n "$ldconfig" ]] || return 0
    paths=$("$ldconfig" -p 2>/dev/null | awk '/lib(pcre2-8|ssl|crypto|c|pthread|resolv|gcc_s)\.so[. ]/ {print $NF}' | sort -u)
    [[ -n "$paths" ]] || return 0
    while IFS= read -r file; do
        [[ -r "$file" ]] || return 0
        output+="$(sha256sum -- "$file")"$'\n'
    done <<< "$paths"
    printf '%s' "$output" | sha256sum | awk '{print $1}'
}
audit() {
    local arch glibc services='' candidates='' service binary config state pid actual
    local selected_service='' selected_binary='' selected_config='' selected_variant='' selected_state='' count=0
    local found='' path variant tools_missing='' build_ready=yes pcre='' openssl='' go_version='' orphan_configs='' classic_found='' agent2_found=''
    begin
    emit system "$(uname -s 2>/dev/null || true)"
    emit initial_user "$(id -un)"
    emit initial_uid "$(id -u)"
    emit os_id "$(release_value ID)"
    emit os_version "$(release_value VERSION_ID)"
    emit os_name "$(release_value PRETTY_NAME)"
    if is_astra; then emit astra yes; else emit astra no; fi
    emit astra_version "$(cat /etc/astra_version 2>/dev/null || true)"
    emit astra_build "$(cat /etc/astra/build_version 2>/dev/null || true)"
    emit architecture "$(uname -m 2>/dev/null || true)"
    emit glibc "$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    emit kernel "$(uname -r 2>/dev/null || true)"
    emit disk_tmp_free_kb "$(df -Pk /tmp 2>/dev/null | awk 'NR==2 {print $4}')"
    for path in cc make tar sha256sum; do
        if ! command -v "$path" >/dev/null 2>&1; then tools_missing+="$path ";build_ready=no;fi
    done
    if command -v pkg-config >/dev/null 2>&1; then
        pcre=$(pkg-config --modversion libpcre2-8 2>/dev/null || true)
        openssl=$(pkg-config --modversion openssl 2>/dev/null || true)
    fi
    if [[ -z "$pcre" ]] && command -v pcre2-config >/dev/null; then pcre=$(pcre2-config --version 2>/dev/null || true); fi
    [[ -r /usr/include/pcre2.h || -n "$pcre" ]] || { tools_missing+='PCRE2-development-files ';build_ready=no; }
    [[ -r /usr/include/openssl/ssl.h || -n "$openssl" ]] || { tools_missing+='OpenSSL-development-files ';build_ready=no; }
    emit tools_missing "$tools_missing"
    emit build_ready "$build_ready"
    emit pcre2_version "$pcre"
    emit openssl_version "$(openssl version 2>/dev/null || true)"
    emit go_version "$(go version 2>/dev/null || true)"
    emit library_fingerprint "$(library_fingerprint)"
    for variant in classic agent2; do
        if [[ "$variant" == classic ]]; then path=zabbix_agentd; else path=zabbix_agent2;fi
        found=$(command -v "$path" 2>/dev/null || true)
        if [[ -z "$found" ]]; then
            for binary in /usr/sbin/"$path" /usr/local/sbin/"$path" /usr/bin/"$path" /usr/local/bin/"$path"; do
                if [[ -x "$binary" ]]; then found=$binary;break;fi
            done
        fi
        emit "${variant}_binary" "$found"
        if [[ "$variant" == classic ]];then classic_found=$found;else agent2_found=$found;fi
        if [[ -n "$found" ]]; then emit "${variant}_version" "$(version_of "$found" || true)"; fi
    done
    if command -v systemctl >/dev/null 2>&1; then
        services=$(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '$1 ~ /^zabbix[-_]agent(d|2)?([-_]source)?[.]service$/ {print $1}' || true)
        while IFS= read -r service; do
            [[ -n "$service" ]] || continue
            binary=$(service_binary "$service")
            config=$(resolved_config "$service" "$binary")
            state=$(unit_prop "$service" ActiveState)
            pid=$(unit_prop "$service" MainPID)
            actual=''
            if [[ "$pid" =~ ^[1-9][0-9]*$ ]]; then actual=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true);fi
            candidates+="$service|$binary|$config|$state|$pid|$actual"$'\n'
            if [[ "$binary" == *zabbix_agentd || "$binary" == *zabbix_agent2 ]]; then
                ((count+=1))
                selected_service=$service;selected_binary=$binary;selected_config=$config;selected_state=$state
                if [[ -x "$binary" ]]; then selected_variant=$(variant_of "$binary" || true);fi
            fi
        done <<< "$services"
    fi
    emit candidates "$candidates"
    emit services "$services"
    for path in /etc/zabbix/zabbix_agentd.conf /etc/zabbix/zabbix_agent2.conf /usr/local/etc/zabbix_agentd.conf /usr/local/etc/zabbix_agent2.conf;do
        [[ ! -f "$path" ]] || orphan_configs+="$path"$'\n'
    done
    emit orphan_configs "$orphan_configs"
    if [[ $(printf '%s' "$orphan_configs" | grep -c . || true) == 1 ]];then emit orphan_config "${orphan_configs%$'\n'}";fi
    if [[ $count -eq 1 ]]; then
        emit service "$selected_service";emit binary "$selected_binary";emit config "$selected_config";emit service_state "$selected_state";emit variant "$selected_variant"
        emit version "$(version_of "$selected_binary" || true)"
        if [[ -n "$selected_config" ]]; then
            emit config_exists "$([[ -f "$selected_config" ]] && printf yes || printf no)"
            emit config_readable "$([[ -r "$selected_config" ]] && printf yes || printf no)"
            emit config_sha256 "$(sha256sum -- "$selected_config" 2>/dev/null | awk '{print $1}' || true)"
        else emit config_exists no;fi
        emit ambiguous no
    elif [[ $count -gt 1 ]];then emit ambiguous yes
    elif [[ -n "$classic_found$agent2_found" ]];then
        emit ambiguous yes;emit service '';emit service_state unknown
        if [[ -n "$classic_found" && -z "$agent2_found" ]];then
            emit binary "$classic_found";emit variant classic;emit version "$(version_of "$classic_found" || true)"
        elif [[ -n "$agent2_found" && -z "$classic_found" ]];then
            emit binary "$agent2_found";emit variant agent2;emit version "$(version_of "$agent2_found" || true)"
        else emit binary '';emit variant '';fi
        emit config '';emit config_exists no
    else emit ambiguous no; emit service '';emit binary '';emit config '';emit config_exists no;emit variant '';emit version '';emit service_state absent
    fi
    emit sudo_noninteractive "$([[ $EUID -eq 0 ]] && printf yes || printf not-tested)"
    emit sudo_command "$(command -v sudo 2>/dev/null || true)"
    emit package_installation prohibited
}
workspace() {
    require_astra
    local dir
    dir=$(mktemp -d /tmp/zabbix-source.XXXXXXXX)
    chmod 0700 "$dir"
    begin;emit workspace "$dir"
}
build_agent() {
    local dir=${1-} source_sha=${2-} version=${3-} jobs=${4-2} variant=${5-classic}
    require_astra
    safe_path "$dir" && [[ "$dir" == /tmp/zabbix-source.* && -d "$dir" && ! -L "$dir" ]] || die 'Invalid private workspace.'
    [[ $(stat -c %u -- "$dir") == "$EUID" ]] || die 'Build workspace is owned by another user.'
    [[ "$source_sha" =~ ^[A-Fa-f0-9]{64}$ ]] || die 'Invalid source SHA-256.'
    safe_version "$version" || die 'Only stable Zabbix 7.0.x is supported.'
    [[ "$jobs" =~ ^[1-9][0-9]?$ ]] || die 'Build jobs must be an integer from 1 to 99.'
    [[ "$variant" == classic || "$variant" == agent2 ]] || die 'Invalid agent variant.'
    [[ -f "$dir/source.tar.gz" && ! -L "$dir/source.tar.gz" ]] || die 'Upload source.tar.gz into the workspace first.'
    [[ $(sha256sum "$dir/source.tar.gz" | awk '{print $1}') == "${source_sha,,}" ]] || die 'Source checksum mismatch.'
    for tool in cc make tar; do command -v "$tool" >/dev/null || die "Missing build prerequisite: $tool. Package installation is prohibited.";done
    if [[ "$variant" == agent2 ]]; then command -v go >/dev/null || die 'Agent2 requires an existing local Go compiler; no compiler/packages will be installed.';fi
    [[ ! -e "$dir/src" && ! -e "$dir/artifact" ]] || die 'Use a fresh workspace for each build.'
    # Only regular files/directories are accepted. Prevent source-archive path/link escape.
    tar -tzf "$dir/source.tar.gz" | awk 'BEGIN{bad=0} /^\// {bad=1} /(^|\/)\.\.($|\/)/ {bad=1} END{exit bad}' || die 'Unsafe archive member path.'
    if tar -tvzf "$dir/source.tar.gz" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END{exit !bad}'; then die 'Source archive links/special files are not accepted.';fi
    mkdir -m 0700 "$dir/src" "$dir/artifact"
    tar --no-same-owner --no-same-permissions -xzf "$dir/source.tar.gz" -C "$dir/src"
    local candidates=() item source='' output='' name
    while IFS= read -r item; do candidates+=("$item");done < <(find "$dir/src" -maxdepth 2 -type f -name configure -print)
    [[ ${#candidates[@]} -eq 1 ]] || die 'Archive must contain exactly one source release with configure.'
    source=$(dirname "${candidates[0]}")
    local configure_flags=(--prefix=/usr/local --sysconfdir=/etc/zabbix --with-libpcre2 --with-openssl)
    if [[ "$variant" == classic ]];then configure_flags+=(--enable-agent);name=zabbix_agentd;else configure_flags+=(--enable-agent2);name=zabbix_agent2;fi
    local log="$dir/build.log"
    # No make install. Go is offline and may use only existing local modules/toolchain.
    if ! (cd "$source"; export GOPROXY=off GOTOOLCHAIN=local GOSUMDB=off GOFLAGS=-mod=readonly GOAMD64=v1 CFLAGS='-O2' CXXFLAGS='-O2'; unset GOARCH GOOS; ./configure "${configure_flags[@]}" && make -j "$jobs") >"$log" 2>&1; then
        begin;emit build_log "$log";die 'Source compilation failed. Inspect the private build.log; missing dependencies are not installed automatically.'
    fi
    if [[ "$variant" == classic ]];then output="$source/src/zabbix_agent/zabbix_agentd";else output="$source/src/go/bin/zabbix_agent2";fi
    [[ -x "$output" ]] || die 'Build completed without the expected agent binary.'
    [[ $(variant_of "$output") == "$variant" && $(version_of "$output") == "$version" ]] || die 'Built binary reports an unexpected release or agent type.'
    cp -- "$output" "$dir/artifact/$name"
    chmod 0755 "$dir/artifact/$name"
    begin
    emit artifact "$dir/artifact/$name"
    emit sha256 "$(sha256sum "$dir/artifact/$name" | awk '{print $1}')"
    emit source_sha256 "${source_sha,,}"
    emit version "$version";emit variant "$variant"
    emit build_log "$log"
    emit os_id "$(release_value ID)";emit os_version "$(release_value VERSION_ID)"
    emit astra_version "$(cat /etc/astra_version 2>/dev/null || true)"
    emit astra_build "$(cat /etc/astra/build_version 2>/dev/null || true)"
    emit architecture "$(uname -m)";emit glibc "$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    emit library_fingerprint "$(library_fingerprint)"
    emit package_installation prohibited
}

metadata_set() { printf '%s' "$2" | base64 | tr -d '\n' >"$1";printf '\n' >>"$1";chmod 0600 "$1"; }
metadata_get() { [[ -f "$1" && ! -L "$1" ]] || return 1; base64 -d "$1"; }
check_exec_config() {
    local service=$1 binary=$2 config=$3 configured actual pid resolved
    configured=$(service_binary "$service")
    [[ -n "$configured" ]] || die 'Cannot parse service ExecStart. Select a standard binary service or fix its explicit command first.'
    [[ $(canonical "$configured") == $(canonical "$binary") ]] || die 'Selected binary does not match the service ExecStart executable.'
    resolved=$(resolved_config "$service" "$binary")
    if [[ -n "$resolved" && "$resolved" != "$config" ]];then die 'Selected config differs from the config specified by the service.';fi
    # New builds have /etc/zabbix as their compiled default. Unknown defaults are rejected.
    if [[ -z "$resolved" ]];then
        if unit_prop "$service" ExecStart | grep -Eq '(^|[[:space:]])(-c[^[:space:]]*|--config[^[:space:]]*)([[:space:]]|$)';then
            die 'Service has an unresolved explicit -c/--config argument; refusing to guess its default.'
        fi
        if [[ "$binary" == *agent2 ]];then actual=/etc/zabbix/zabbix_agent2.conf;else actual=/etc/zabbix/zabbix_agentd.conf;fi
        [[ "$config" == "$actual" ]] || die 'Service has no resolvable -c argument; only the explicitly confirmed standard /etc/zabbix default is accepted.'
    fi
    pid=$(unit_prop "$service" MainPID)
    if [[ "$pid" =~ ^[1-9][0-9]*$ ]];then
        actual=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
        [[ "$actual" != *' (deleted)' && "$actual" == $(canonical "$binary") ]] || die 'Running process executable differs from the selected binary. Refusing ambiguous replacement.'
    fi
}
check_staged() {
    local binary=$1 config=$2 version=$3 variant=$4 log=$5 ping
    [[ $(version_of "$binary") == "$version" ]] || die 'Staged executable version mismatch.'
    [[ $(variant_of "$binary") == "$variant" ]] || die 'Staged agent variant mismatch.'
    if ! "$binary" -c "$config" -T >"$log" 2>&1;then die "Configuration validation failed. Private log: $log";fi
    if ! ping=$("$binary" -c "$config" -t agent.ping 2>>"$log");then die 'Staged agent.ping failed.';fi
    printf '%s\n' "$ping" >>"$log"
    [[ "$ping" =~ \[(u|d|s|t)\|1(\.0)?\] ]] || die 'Staged agent.ping did not return 1.'
}
verify_running() {
    local service=$1 binary=$2 version=$3 pid actual count
    for count in 1 2 3 4 5;do
        if systemctl is-active --quiet "$service";then
            pid=$(unit_prop "$service" MainPID)
            if [[ "$pid" =~ ^[1-9][0-9]*$ ]];then
                actual=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
                if [[ "$actual" == $(canonical "$binary") && "$actual" != *' (deleted)' && $(version_of "$binary" || true) == "$version" ]];then return 0;fi
            fi
        fi
        sleep 1
    done
    return 1
}
backup_root() {
    [[ ! -L /var/backups/zabbix-source ]] || die 'Backup directory must not be a symlink.'
    mkdir -p /var/backups/zabbix-source
    chmod 0700 /var/backups/zabbix-source
    chown root:root /var/backups/zabbix-source
    mktemp -d /var/backups/zabbix-source/transaction.XXXXXXXX
}
snapshot_configs() {
    local backup=$1 config=$2
    if [[ -d /etc/zabbix && ! -L /etc/zabbix ]];then cp -a -- /etc/zabbix "$backup/etc-zabbix";fi
    if [[ -f "$config" ]];then cp -a -- "$config" "$backup/config.previous";fi
}
copy_existing_metadata() {
    local original=$1 staged=$2 attrs='' helper_dir=$3
    chown --reference="$original" "$staged"
    chmod --reference="$original" "$staged"
    if command -v getfattr >/dev/null && command -v setfattr >/dev/null;then
        attrs=$(getfattr -d -m - --absolute-names -- "$original" 2>/dev/null) || die 'Cannot inspect the existing binary extended attributes.'
        # Old content signatures/capability grants must not be copied onto a
        # different ELF. Signed installations need their approved signing flow.
        if printf '%s\n' "$attrs" | grep -Eiq '^[^#=]*(ima|evm|digsig|bsign|capability)[^=]*=';then
            die 'Existing binary carries a signature or capability attribute. Use the approved signing/capability workflow before replacement.'
        fi
        if [[ -n "$attrs" ]];then
            printf '%s\n' "$attrs" | awk -v path="$staged" '/^# file:/ {print "# file: " path; next} {print}' | setfattr --restore=-
        fi
    else
        # The deployment already requires a compiler for source builds. When
        # attribute utilities are absent, build this small metadata helper from
        # the embedded source; never install or download a utility package.
        command -v cc >/dev/null || die 'Cannot safely inspect/copy extended attributes: neither installed attribute utilities nor a C compiler are available.'
        cat >"$helper_dir/metadata-copy.c" <<'C_SOURCE'
#define _GNU_SOURCE
#include <sys/xattr.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
static void fail(const char *s){perror(s);exit(1);}
int main(int argc,char **argv){
  if(argc!=3)return 2;
  ssize_t n=listxattr(argv[1],NULL,0);
  if(n<0){if(errno==ENOTSUP||errno==EOPNOTSUPP)return 0;fail("listxattr");}
  if(!n)return 0;
  char *names=malloc((size_t)n);if(!names)fail("malloc");
  n=listxattr(argv[1],names,(size_t)n);if(n<0)fail("listxattr");
  for(char *p=names;p<names+n;p+=strlen(p)+1){
    if(strcasestr(p,"digsig")||strcasestr(p,"bsign")||strcasestr(p,"capability")||
       !strcasecmp(p,"security.ima")||!strcasecmp(p,"security.evm")){
      fprintf(stderr,"Protected signature/capability attribute requires approved signing workflow: %s\n",p);return 1;
    }
    ssize_t z=getxattr(argv[1],p,NULL,0);if(z<0)fail("getxattr");
    void *value=malloc((size_t)z+1);if(!value)fail("malloc");
    if(getxattr(argv[1],p,value,(size_t)z)!=z)fail("getxattr");
    if(setxattr(argv[2],p,value,(size_t)z,0))fail("setxattr");
    ssize_t actual=getxattr(argv[2],p,NULL,0);if(actual!=z){fprintf(stderr,"Attribute size verification failed\n");return 1;}
    void *check=malloc((size_t)z+1);if(!check)fail("malloc");
    if(getxattr(argv[2],p,check,(size_t)z)!=z||memcmp(value,check,(size_t)z)){fprintf(stderr,"Attribute verification failed\n");return 1;}
    free(value);free(check);
  }
  free(names);return 0;
}
C_SOURCE
        cc -O2 -o "$helper_dir/metadata-copy" "$helper_dir/metadata-copy.c" >"$helper_dir/metadata-build.log" 2>&1 || die 'Cannot compile the embedded attribute helper; original binary remains unchanged.'
        chmod 0700 "$helper_dir/metadata-copy"
        "$helper_dir/metadata-copy" "$original" "$staged" || die 'Cannot safely copy/verify original extended attributes; original binary remains unchanged.'
    fi
}
deployment_exit() {
    local rc=$1 rollback_rc=0
    trap - EXIT
    set +e
    if [[ -n "${TX_STAGED-}" ]];then rm -f -- "$TX_STAGED";fi
    if [[ $rc -ne 0 && -n "${TX_BACKUP-}" ]];then
        if [[ "${TX_MODE-}" == install || "${TX_BINARY_REPLACED-}" == yes ]];then
            printf 'Deployment failed; attempting rollback from %s\n' "$TX_BACKUP" >&2
            (set -e;do_rollback "$TX_BACKUP") >&2
            rollback_rc=$?
            if [[ $rollback_rc -ne 0 ]];then printf 'Automatic rollback failed; keep backup %s\n' "$TX_BACKUP" >&2;fi
        fi
        begin;emit status failed;emit backup "$TX_BACKUP"
    fi
    exit "$rc"
}
do_rollback() {
    local backup=${1-} mode binary config service was_active version unit
    require_astra;require_root
    safe_path "$backup" && [[ "$backup" == /var/backups/zabbix-source/transaction.* && -d "$backup" && ! -L "$backup" ]] || die 'Invalid transaction backup directory.'
    [[ $(stat -c %u "$backup") == 0 && $(stat -c %a "$backup") == 700 ]] || die 'Backup metadata must be root-owned and private.'
    mode=$(metadata_get "$backup/mode");binary=$(metadata_get "$backup/binary");config=$(metadata_get "$backup/config");service=$(metadata_get "$backup/service")
    safe_path "$binary" && safe_path "$config" && safe_service "$service" || die 'Invalid backup metadata.'
    if [[ "$mode" == update ]];then
        [[ -f "$backup/binary.previous" ]] || die 'Original binary backup is missing.'
        local stage
        stage=$(mktemp "$(dirname "$binary")/.zabbix-restore.XXXXXXXX")
        cp --preserve=all -- "$backup/binary.previous" "$stage"
        mv -fT -- "$stage" "$binary"
        was_active=$(metadata_get "$backup/was_active");version=$(metadata_get "$backup/version_before")
        if [[ "$was_active" == yes ]];then
            systemctl restart "$service"
            verify_running "$service" "$binary" "$version" || die 'Original binary restored, but its service did not verify.'
        else
            systemctl stop "$service" || true
        fi
    elif [[ "$mode" == install ]];then
        # Delete only paths marked as newly created by this transaction.
        unit="/etc/systemd/system/$service"
        [[ ! -L "$unit" ]] || die 'New service file was replaced by a symlink; manual rollback is required.'
        if [[ $(metadata_get "$backup/new_unit") == yes ]];then
            systemctl disable --now "$service" >/dev/null 2>&1 || true
            rm -f -- "$unit"
        fi
        [[ $(metadata_get "$backup/new_binary") == yes ]] && rm -f -- "$binary"
        [[ $(metadata_get "$backup/new_config") == yes ]] && rm -f -- "$config"
        systemctl daemon-reload
        # Service account and shared runtime/log directories are retained.
    else die 'Unknown transaction mode.';fi
    begin;emit backup "$backup";emit status rolled_back
}
deploy_agent() {
    local mode=${1-} artifact=${2-} expected_sha=${3-} version=${4-} binary=${5-} config=${6-} service=${7-} supplied_config=${8-}
    local variant current_variant='' current_version='' backup='' staged='' validation_log='' was_active=no new_config=no binary_replaced=no
    require_astra;require_root
    [[ "$mode" == update || "$mode" == install ]] || die 'Mode must be update or install.'
    safe_path "$artifact" && safe_path "$binary" && safe_path "$config" && safe_service "$service" || die 'Unsafe path or service name.'
    [[ "$expected_sha" =~ ^[A-Fa-f0-9]{64}$ ]] && safe_version "$version" || die 'Invalid checksum or release.'
    [[ -f "$artifact" && ! -L "$artifact" ]] || die 'Prepared source-build artifact is missing.'
    [[ "$artifact" == /tmp/zabbix-source.*/* ]] || die 'Upload the verified source-build artifact into a private source workspace first.'
    [[ $(sha256sum "$artifact" | awk '{print $1}') == "${expected_sha,,}" ]] || die 'Transferred artifact checksum mismatch.'
    # SCP/SFTP or streamed upload may have stripped execute bits; this is only
    # the private uploaded artifact, never the installed target executable.
    chmod 0755 -- "$artifact"
    [[ ! -L "$binary" && ! -L "$config" ]] || die 'Symlinked binary/config needs manual review.'
    variant=$(variant_of "$artifact") || die 'Artifact is not a Zabbix agent.'
    [[ $(version_of "$artifact") == "$version" ]] || die 'Artifact version mismatch.'
    command -v systemctl >/dev/null || die 'A systemd host is required.'
    if [[ "$mode" == update ]];then
        [[ -x "$binary" && -f "$config" ]] || die 'Update requires an existing binary and configuration.'
        current_variant=$(variant_of "$binary");current_version=$(version_of "$binary")
        [[ "$variant" == "$current_variant" ]] || die 'Changing classic agent to/from Agent2 is prohibited.'
        [[ $(printf '%s\n%s\n' "$current_version" "$version" | sort -V | tail -n 1) == "$version" ]] || die 'Downgrades are not supported.'
        check_exec_config "$service" "$binary" "$config"
        if [[ $(sha256sum "$binary" | awk '{print $1}') == "${expected_sha,,}" ]];then
            systemctl is-active --quiet "$service" || die 'Binary already matches, but its service is inactive. Inspect/start it explicitly before continuing.'
            verify_running "$service" "$binary" "$version" || die 'Binary matches, but the expected running process could not be verified.'
            begin;emit status unchanged;emit version "$version";return
        fi
        systemctl is-active --quiet "$service" && was_active=yes || true
        if command -v getcap >/dev/null && [[ -n $(getcap "$binary" 2>/dev/null) ]];then die 'The existing binary has file capabilities. Apply an approved source-build capability policy manually; refusing to lose it.';fi
    else
        [[ ! -e "$binary" ]] || die 'Install target binary already exists. Audit it and use update instead.'
        local known_binary known_name
        for known_name in zabbix_agentd zabbix_agent2;do
            known_binary=$(command -v "$known_name" 2>/dev/null || true)
            [[ -z "$known_binary" ]] || die 'An agent binary already exists outside the selected install path. Audit its service/config rather than creating a second agent.'
            for known_binary in /usr/sbin/"$known_name" /usr/local/sbin/"$known_name" /usr/bin/"$known_name" /usr/local/bin/"$known_name";do
                [[ ! -x "$known_binary" ]] || die 'An orphan agent binary exists. Resolve its intended service before a new installation.'
            done
        done
        [[ $(unit_prop "$service" LoadState) == not-found || -z $(unit_prop "$service" LoadState) ]] || die 'Install would replace an existing service. Use a new source service name.'
        [[ ! -e "/etc/systemd/system/$service" && ! -L "/etc/systemd/system/$service" ]] || die 'Service path already exists.'
        if [[ ! -f "$config" ]];then
            [[ -n "$supplied_config" ]] && safe_path "$supplied_config" && [[ -f "$supplied_config" && ! -L "$supplied_config" ]] || die 'A new installation requires a prepared config file when no old config exists.'
            new_config=yes
        fi
    fi
    backup=$(backup_root)
    metadata_set "$backup/mode" "$mode";metadata_set "$backup/binary" "$binary";metadata_set "$backup/config" "$config";metadata_set "$backup/service" "$service"
    metadata_set "$backup/was_active" "$was_active";metadata_set "$backup/version_before" "$current_version"
    metadata_set "$backup/new_binary" no;metadata_set "$backup/new_config" no;metadata_set "$backup/new_unit" no
    snapshot_configs "$backup" "$config"
    validation_log="$backup/validation.log"
    if [[ "$mode" == update ]];then cp -a -- "$binary" "$backup/binary.previous";fi
    # EXIT also catches an explicit validation die(), not only set -e failures.
    # A rejected staged build must not restart an unchanged existing service.
    TX_MODE=$mode;TX_BACKUP=$backup;TX_BINARY_REPLACED=no;TX_STAGED=''
    trap 'deployment_exit "$?"' EXIT
    begin;emit backup "$backup"
    mkdir -p -- "$(dirname "$binary")"
    if [[ "$mode" == install ]];then
        local process_comm process_name
        for process_comm in /proc/[0-9]*/comm;do
            [[ -r "$process_comm" ]] || continue
            IFS= read -r process_name <"$process_comm" || true
            [[ "$process_name" != zabbix_agentd && "$process_name" != zabbix_agent2 ]] || die 'An agent process already runs. Resolve its current service/config before installing another one.'
        done
        getent group zabbix >/dev/null || groupadd --system zabbix
        if ! getent passwd zabbix >/dev/null;then
            local nologin=/usr/sbin/nologin
            [[ -x "$nologin" ]] || nologin=/sbin/nologin
            useradd --system --gid zabbix --home-dir /var/lib/zabbix --no-create-home --shell "$nologin" zabbix
        fi
        if [[ "$new_config" == yes ]];then
            mkdir -p -- "$(dirname "$config")"
            metadata_set "$backup/new_config" yes
            install -m 0640 -o root -g zabbix -- "$supplied_config" "$config"
        fi
        local runtime_dir
        for runtime_dir in /var/log/zabbix /var/lib/zabbix;do
            [[ ! -L "$runtime_dir" ]] || die "Refusing a symlinked state/log directory: $runtime_dir"
            if [[ ! -d "$runtime_dir" ]];then install -d -m 0750 -o zabbix -g zabbix "$runtime_dir";fi
        done
    fi
    staged=$(mktemp "$(dirname "$binary")/.zabbix-new.XXXXXXXX")
    TX_STAGED=$staged
    cp -- "$artifact" "$staged"
    chmod 0755 "$staged"
    if [[ "$mode" == update ]];then copy_existing_metadata "$binary" "$staged" "$backup";fi
    [[ $(sha256sum "$staged" | awk '{print $1}') == "${expected_sha,,}" ]] || die 'Staged binary checksum mismatch; refusing to execute it.'
    check_staged "$staged" "$config" "$version" "$variant" "$validation_log"
    if [[ "$mode" == update ]];then
        [[ $(sha256sum "$binary" | awk '{print $1}') == $(sha256sum "$backup/binary.previous" | awk '{print $1}') ]] || die 'Installed binary changed during validation; refusing to replace it.'
    else metadata_set "$backup/new_binary" yes;fi
    mv -fT -- "$staged" "$binary";binary_replaced=yes;TX_BINARY_REPLACED=yes;staged='';TX_STAGED=''
    if [[ "$mode" == install ]];then
        metadata_set "$backup/new_unit" yes
        local unit="/etc/systemd/system/$service"
        cat >"$unit" <<UNIT
[Unit]
Description=Zabbix agent built from approved source
After=network.target

[Service]
Type=simple
User=zabbix
Group=zabbix
RuntimeDirectory=zabbix-source
RuntimeDirectoryMode=0755
ExecStart=$binary $([[ "$variant" == classic ]] && printf -- '-f ')-c $config
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
        chmod 0644 "$unit"
        systemctl daemon-reload
        systemctl enable "$service"
        systemctl start "$service"
    else systemctl restart "$service";fi
    verify_running "$service" "$binary" "$version"
    check_staged "$binary" "$config" "$version" "$variant" "$validation_log"
    trap - EXIT
    metadata_set "$backup/completed" yes
    begin;emit status "$([[ "$mode" == install ]] && printf installed || printf updated)";emit backup "$backup";emit version "$version";emit variant "$variant"
    emit config "$config";emit binary "$binary";emit service "$service"
}
status_agent() {
    local service=${1-}
    require_astra
    safe_service "$service" || die 'Invalid service name.'
    begin;emit service "$service";emit service_state "$(unit_prop "$service" ActiveState)";emit main_pid "$(unit_prop "$service" MainPID)"
    local binary
    binary=$(service_binary "$service")
    emit binary "$binary";emit version "$(version_of "$binary" || true)"
}

action=${1-audit}
if [[ $# -gt 0 ]];then shift;fi
case "$action" in
    audit) audit ;;
    workspace) workspace ;;
    build) build_agent "$@" ;;
    deploy) deploy_agent "$@" ;;
    rollback) do_rollback "$@" ;;
    status) status_agent "$@" ;;
    *) begin;die 'Unknown remote action.' ;;
esac
ZABBIX_EMBEDDED_WORKER_20261125
}
prepare_sudo() {
  local id=$1 answer
  [[ ${H_USER[$id]} != root ]] || return 0
  [[ ${SUDO_SECRET[$id]+yes} ]] && return 0
  connection_args "$id"
  if ssh -n "${SSH_ARGS[@]}" "${H_ADDR[$id]}" 'sudo -n true' 2>/dev/null; then SUDO_SECRET[$id]=''; return 0; fi
  tty_read answer "Пароль sudo для ${H_USER[$id]}@$id (не сохраняется): " yes
  SUDO_SECRET[$id]=$answer
  unset answer
}
remote_worker() {
  local id=$1 privileged=$2 command status
  shift 2
  connection_args "$id"
  if [[ $privileged == yes && ${H_USER[$id]} != root ]]; then
    # Always consume the secret line before sudo, even when sudo is NOPASSWD.
    local launcher='IFS= read -r password || exit 90; if [ -n "$password" ]; then printf "%s\n" "$password" | sudo -S -p "" -v || exit 91; else sudo -n -v || exit 91; fi; unset password; sudo -n bash -s -- "$@"'
    command=$(quote_command bash -c "$launcher" bash "$@")
    { printf '%s\n' "${SUDO_SECRET[$id]-}"; worker_payload; } | ssh "${SSH_ARGS[@]}" "${H_ADDR[$id]}" "$command"
  else
    command=$(quote_command bash -s -- "$@")
    worker_payload | ssh "${SSH_ARGS[@]}" "${H_ADDR[$id]}" "$command"
  fi
}
upload_file() {
  local id=$1 source=$2 destination=$3 remote
  [[ $destination =~ ^/[A-Za-z0-9_./-]+$ ]] || { err 'Worker returned an unsafe upload path.'; return 1; }
  connection_args "$id"
  remote="${H_ADDR[$id]}:$destination"
  [[ ${H_ADDR[$id]} != *:* ]] || remote="[${H_ADDR[$id]}]:$destination"
  scp "${SCP_ARGS[@]}" -- "$source" "$remote"
}
download_file() {
  local id=$1 source=$2 destination=$3 remote
  [[ $source =~ ^/[A-Za-z0-9_./-]+$ ]] || return 1
  connection_args "$id"
  remote="${H_ADDR[$id]}:$source"
  [[ ${H_ADDR[$id]} != *:* ]] || remote="[${H_ADDR[$id]}]:$source"
  scp "${SCP_ARGS[@]}" -- "$remote" "$destination"
}
audit_one() {
  local id=$1 privileged=${2:-no} file tmp
  require_host "$id"
  [[ $privileged != yes ]] || prepare_sudo "$id"
  file="$STATE/audit/$id.tsv"; tmp=$(mktemp "$STATE/tmp/audit.XXXXXX")
  say "Аудит $id (${H_ADDR[$id]})..." >&2
  if remote_worker "$id" "$privileged" audit >"$tmp"; then
    grep -q '^ZA_AUDIT_V1$' "$tmp" || { err 'Нет заголовка отчёта'; rm -f -- "$tmp"; return 1; }
    mv -- "$tmp" "$file"
    kv_set "$file" collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    option_set "$id" last_audit_status ok
    show_one "$id"
    [[ $(kv_get "$file" astra) == yes ]] || { option_set "$id" last_audit_status blocked;err "$id: фактически обнаружена не Astra Linux. Изменения запрещены."; return 1; }
  else
    mv -- "$tmp" "$STATE/logs/$id.audit-failed.tsv"
    option_set "$id" last_audit_status failed
    err "Аудит $id не выполнен. ОС Windows и не-Astra блокируются; проверьте SSH/маршрут."
    return 1
  fi
}
show_one() {
  local id=$1 file="$STATE/audit/$1.tsv" key value
  [[ -f $file ]] || { err 'Сначала выполните audit.'; return 1; }
  printf '\n%s (%s, user=%s, route=%s); последний аудит: %s\n' "$id" "${H_ADDR[$id]}" "${H_USER[$id]}" "${H_ROUTE[$id]}" "$(option_get "$id" last_audit_status)"
  for key in collected_at os_name os_version astra_version astra_build architecture glibc variant version classic_version agent2_version binary config service service_state ambiguous tools_missing build_ready pcre2_version openssl_version go_version candidates; do
    value=$(kv_get "$file" "$key")
    printf '  %-18s %s\n' "$key" "${value:--}"
  done
}
selected() {
  local value
  value=$(option_get "$1" "$2")
  [[ -n $value ]] || value=$(kv_get "$STATE/audit/$1.tsv" "$2")
  printf '%s' "$value"
}
workspace_for() {
  local id=$1 file path
  file=$(mktemp "$STATE/tmp/workspace.XXXXXX")
  if ! remote_worker "$id" no workspace >"$file"; then rm -f -- "$file"; return 1; fi
  path=$(kv_get "$file" workspace); rm -f -- "$file"
  [[ $path =~ ^/[A-Za-z0-9_./-]+$ ]] || { err 'Unsafe worker workspace'; return 1; }
  option_set "$id" workspace "$path"
  printf '%s' "$path"
}
register_source() {
  local source=$1 expected=$2 actual destination
  [[ -f $source && $expected =~ ^[a-fA-F0-9]{64}$ ]] || { err 'source FILE SHA256: нужен локальный .tar.gz и ожидаемый SHA-256.'; return 1; }
  actual=$(sha256sum -- "$source" | awk '{print $1}')
  [[ $actual == "${expected,,}" ]] || { err 'SHA-256 исходников не совпадает.'; return 1; }
  destination="$STATE/sources/$actual.tar.gz"
  if [[ ! -f $destination ]]; then cp -- "$source" "$destination"; chmod 400 "$destination"; fi
  kv_set "$STATE/settings.tsv" source_path "$destination"
  kv_set "$STATE/settings.tsv" source_sha "$actual"
  say "Исходники зарегистрированы: $actual"
}
build_one() {
  local id=$1 source sha workspace result artifact digest variant jobs dir
  require_host "$id"; audit_one "$id" no
  source=$(kv_get "$STATE/settings.tsv" source_path); sha=$(kv_get "$STATE/settings.tsv" source_sha)
  [[ -f $source && $sha =~ ^[a-f0-9]{64}$ ]] || { err 'Сначала source FILE SHA256.'; return 1; }
  [[ $(sha256sum -- "$source" | awk '{print $1}') == "$sha" ]] || return 1
  variant=$(selected "$id" variant); [[ -n $variant && $variant != none ]] || variant=classic
  [[ $variant == classic || $variant == agent2 ]] || { err 'Выберите variant classic или agent2.'; return 1; }
  jobs=$(option_get "$id" jobs); jobs=${jobs:-2}; [[ $jobs =~ ^[1-8]$ ]] || return 1
  printf 'Сборка из исходников %s на %s, тип=%s, jobs=%s\n' "${CFG[version]}" "$id" "$variant" "$jobs"
  confirm_host "$id" || return 1
  workspace=$(workspace_for "$id")
  upload_file "$id" "$source" "$workspace/source.tar.gz"
  result=$(mktemp "$STATE/tmp/build.XXXXXX")
  say "Сборка на $id; удалённый журнал: $workspace/build.log"
  if ! remote_worker "$id" no build "$workspace" "$sha" "${CFG[version]}" "$jobs" "$variant" >"$result"; then
    say "$(kv_get "$result" error)" >&2
    mv -- "$result" "$STATE/logs/$id.build-failed.tsv"; return 1
  fi
  artifact=$(kv_get "$result" artifact); digest=$(kv_get "$result" sha256)
  [[ $digest =~ ^[a-f0-9]{64}$ ]] || { err 'Worker did not return build SHA-256'; return 1; }
  dir="$STATE/builds/$id"; mkdir -p -- "$dir"; chmod 700 "$dir"
  download_file "$id" "$artifact" "$dir/agent.new"
  [[ $(sha256sum -- "$dir/agent.new" | awk '{print $1}') == "$digest" ]] || { err 'Загруженная сборка повреждена.'; rm -f -- "$dir/agent.new"; return 1; }
  chmod 700 "$dir/agent.new"; mv -- "$dir/agent.new" "$dir/agent"
  cp -- "$STATE/audit/$id.tsv" "$dir/audit.tsv"
  mv -- "$result" "$dir/build.tsv"
  kv_set "$dir/build.tsv" source_sha "$sha"
  kv_set "$dir/build.tsv" version "${CFG[version]}"
  kv_set "$dir/build.tsv" variant "$variant"
  option_set "$id" build_from "$id"
  say "Сборка сохранена: $dir/agent. Установка ещё не выполнялась."
}
compatible_build() {
  local target=$1 builder=$2 key expected actual
  [[ -f $STATE/builds/$builder/agent && -f $STATE/builds/$builder/build.tsv ]] || { err 'Указанная сборка отсутствует.'; return 1; }
  [[ $(kv_get "$STATE/builds/$builder/build.tsv" version) == "${CFG[version]}" ]] || { err 'Версия сборки отличается от целевой.'; return 1; }
    for key in os_id os_version astra_version architecture glibc library_fingerprint; do
      expected=$(kv_get "$STATE/builds/$builder/audit.tsv" "$key")
      actual=$(kv_get "$STATE/audit/$target.tsv" "$key")
      [[ -n $actual && $actual == "$expected" ]] || { err "Сборка $builder не подтверждена для $target: отличается/не определено $key."; return 1; }
    done
}
make_install_config() {
  local id=$1 file=$2 variant=${3:-classic} server active hostname answer
  server=$(option_get "$id" server); active=$(option_get "$id" server_active); hostname=$(option_get "$id" hostname)
  hostname=${hostname:-$id}
  if [[ -z $server && -z $active ]]; then
    tty_read server 'Server (разрешённый сервер/proxy пассивных проверок; пусто для active-only): '
    tty_read active 'ServerActive (сервер/proxy активных проверок; пусто для passive-only): '
    tty_read answer "Hostname в Zabbix [$hostname]: "
    hostname=${answer:-$hostname}
  fi
  [[ -n $server || -n $active ]] || { err 'Нужен Server или ServerActive.'; return 1; }
  [[ $server =~ ^[A-Za-z0-9_.,:/-]*$ && $active =~ ^[A-Za-z0-9_.,:/-]*$ && $hostname =~ ^[A-Za-z0-9_.-]+$ ]] || { err 'Некорректные параметры нового конфига.'; return 1; }
  {
    printf 'LogFile=/var/log/zabbix/zabbix_agent_source.log\nPidFile=/run/zabbix-source/agent.pid\n'
    printf 'Hostname=%s\n' "$hostname"
    if [[ -n $server ]]; then printf 'Server=%s\n' "$server"; elif [[ $variant == classic ]]; then printf 'StartAgents=0\n'; fi
    if [[ -n $active ]]; then printf 'ServerActive=%s\n' "$active"; fi
  } >"$file"
  chmod 600 "$file"
}
deploy_one() {
  local id=$1 request=$2 builder file mode binary config service variant workspace source checksum result new_config='' template
  require_host "$id"; prepare_sudo "$id"; audit_one "$id" yes
  file="$STATE/audit/$id.tsv"
  if [[ $(kv_get "$file" ambiguous) == yes ]]; then
    local choice
    for choice in binary config service variant; do
      [[ -n $(option_get "$id" "$choice") ]] || { err "Обнаружено несколько агентов/служб. Укажите явно set $id binary/config/service/variant перед изменениями."; return 1; }
    done
  fi
  binary=$(selected "$id" binary); config=$(selected "$id" config); service=$(selected "$id" service); variant=$(selected "$id" variant)
  if [[ -n $binary && $binary != none ]]; then mode=update; else mode=install; fi
  [[ $request == apply || $request == "$mode" ]] || { err "Нужна команда $mode, состояние узла изменилось."; return 1; }
  if [[ $mode == install ]]; then
    [[ -n $variant && $variant != none ]] || variant=classic
    if [[ $variant == agent2 ]]; then
      binary=${binary:-/usr/local/sbin/zabbix_agent2}; config=${config:-/etc/zabbix/zabbix_agent2.conf}
    else
      binary=${binary:-/usr/local/sbin/zabbix_agentd}; config=${config:-/etc/zabbix/zabbix_agentd.conf}
    fi
    [[ $binary != none ]] || binary=/usr/local/sbin/zabbix_agentd
    service=${service:-zabbix-agent-source.service}
  fi
  [[ -n $binary && -n $config && -n $service ]] || { err 'Неоднозначные параметры. Укажите set HOST binary/config/service.'; return 1; }
  builder=$(option_get "$id" build_from); builder=${builder:-$id}
  compatible_build "$id" "$builder"
  [[ $(kv_get "$STATE/builds/$builder/build.tsv" variant) == "$variant" ]] || { err 'Тип агента сборки не совпадает с существующим/выбранным.'; return 1; }
  checksum=$(kv_get "$STATE/builds/$builder/build.tsv" sha256)
  source="$STATE/builds/$builder/agent"
  [[ $(sha256sum -- "$source" | awk '{print $1}') == "$checksum" ]] || { err 'SHA-256 сборки изменился.'; return 1; }
  printf '\nПЛАН %s: %s\n  версия: %s\n  тип: %s\n  бинарник: %s\n  конфиг: %s\n  служба: %s\n  сборка: %s\n' "$id" "$mode" "${CFG[version]}" "$variant" "$binary" "$config" "$service" "$builder"
  say 'Существующий конфиг и параметры запуска обновляемого агента сохраняются.'
  confirm_host "$id" || return 1
  workspace=$(workspace_for "$id")
  upload_file "$id" "$source" "$workspace/agent"
  if [[ $mode == install ]]; then
    template=$(option_get "$id" config_template)
    if [[ -n $template ]]; then
      [[ -f $template ]] || { err 'Локальный config_template отсутствует.'; return 1; }
      upload_file "$id" "$template" "$workspace/new.conf"; new_config="$workspace/new.conf"
    elif [[ $(kv_get "$file" config_exists) != yes ]]; then
      template=$(mktemp "$STATE/tmp/config.XXXXXX")
      make_install_config "$id" "$template" "$variant"
      upload_file "$id" "$template" "$workspace/new.conf"
      rm -f -- "$template"; new_config="$workspace/new.conf"
    fi
  fi
  result=$(mktemp "$STATE/tmp/deploy.XXXXXX")
  if remote_worker "$id" yes deploy "$mode" "$workspace/agent" "$checksum" "${CFG[version]}" "$binary" "$config" "$service" "$new_config" >"$result"; then
    mv -- "$result" "$STATE/logs/$id.deploy.tsv"
    local latest_backup
    latest_backup=$(kv_get "$STATE/logs/$id.deploy.tsv" backup)
    if [[ -n $latest_backup ]]; then option_set "$id" backup "$latest_backup"; fi
    say "Статус: $(kv_get "$STATE/logs/$id.deploy.tsv" status); backup: $(option_get "$id" backup)"
    say "Готово $id. Проверьте agent.version и поступление данных в Zabbix."
  else
    say "$(kv_get "$result" error)" >&2
    local failed_backup
    failed_backup=$(kv_get "$result" backup)
    if [[ -n $failed_backup ]];then option_set "$id" backup "$failed_backup";say "Резервная копия: $failed_backup" >&2;fi
    mv -- "$result" "$STATE/logs/$id.deploy-failed.tsv"
    err "Операция $id завершилась ошибкой; смотрите сообщение об откате и журнал."
    return 1
  fi
}
plan_one() {
  local id=$1
  audit_one "$id" no
  printf '\nЦелевая версия: %s\nСборка: %s\n' "${CFG[version]}" "$(option_get "$id" build_from)"
  say 'Пустые/неоднозначные binary, config, service задаются командой set HOST FIELD VALUE.'
}
rollback_one() {
  local id=$1 backup result
  require_host "$id"; backup=$(option_get "$id" backup)
  [[ -n $backup ]] || { err 'Нет сохранённого пути backup для этого узла.'; return 1; }
  printf 'Откат %s из %s\n' "$id" "$backup"; confirm_host "$id" || return 1
  prepare_sudo "$id"; result=$(mktemp "$STATE/tmp/rollback.XXXXXX")
  remote_worker "$id" yes rollback "$backup" >"$result"
  say "Статус: $(kv_get "$result" status)"
  mv -- "$result" "$STATE/logs/$id.rollback.tsv"
}
report_csv() {
  local destination="$STATE/audit-summary.csv" id file key value
  local -a fields=(collected_at os_name os_version astra_version astra_build architecture glibc variant version service service_state config binary tools_missing build_ready)
  printf 'host;last_audit_status' >"$destination"
  for key in "${fields[@]}";do printf ';%s' "$key" >>"$destination";done
  printf '\n' >>"$destination"
  for id in "${!H_ADDR[@]}";do
    file="$STATE/audit/$id.tsv"; [[ -f $file ]] || continue
    printf '"%s";"%s"' "$id" "$(option_get "$id" last_audit_status)" >>"$destination"
    for key in "${fields[@]}";do
      value=$(kv_get "$file" "$key");value=${value//$'\n'/ | };value=${value//\"/\"\"}
      printf ';"%s"' "$value" >>"$destination"
    done
    printf '\n' >>"$destination"
  done
  chmod 600 "$destination";say "$destination"
}
status_one() {
  local id=$1 service result
  require_host "$id";service=$(selected "$id" service)
  [[ -n $service ]] || { err 'Сначала audit или set HOST service NAME.service';return 1; }
  result=$(mktemp "$STATE/tmp/status.XXXXXX")
  remote_worker "$id" no status "$service" >"$result"
  printf '%s: %s; версия %s\n' "$id" "$(kv_get "$result" service_state)" "$(kv_get "$result" version)"
  rm -f -- "$result"
}
set_value() {
  local id=$1 key=$2 value=${3:-}
  if [[ $id == global ]]; then
    case "$key" in
      version) [[ $value =~ ^7\.0\.[0-9]+$ ]] || return 1 ;;
      jump_host) valid_addr "$value" || return 1 ;;
      jump_port) valid_port "$value" || return 1 ;;
      jump_user) valid_user "$value" || return 1 ;;
      jump_key) [[ -z $value ]] || valid_path "$value" || return 1 ;;
      *) err 'Глобальные поля: version,jump_host,jump_port,jump_user,jump_key'; return 1 ;;
    esac
    kv_set "$STATE/settings.tsv" "$key" "$value"; load_settings; return
  fi
  require_host "$id"
  case "$key" in
    user|port|address|route|identity)
      local address=${H_ADDR[$id]} port=${H_PORT[$id]} user=${H_USER[$id]} route=${H_ROUTE[$id]} identity=${H_KEY[$id]}
      case "$key" in user) user=$value;;port) port=$value;;address) address=$value;;route) route=$value;;identity) identity=$value;;esac
      save_host "$id" "$address" "$port" "$user" "$route" "$identity" ;;
    binary|config|config_template) valid_path "$value" || return 1; option_set "$id" "$key" "$value" ;;
    service) [[ $value =~ ^[A-Za-z0-9_.@-]+\.service$ ]] || return 1; option_set "$id" "$key" "$value" ;;
    variant) [[ $value == classic || $value == agent2 ]] || return 1; option_set "$id" "$key" "$value" ;;
    jobs) [[ $value =~ ^[1-8]$ ]] || return 1; option_set "$id" "$key" "$value" ;;
    build_from) require_host "$value"; option_set "$id" "$key" "$value" ;;
    server|server_active|hostname) [[ $value =~ ^[A-Za-z0-9_.,:/-]*$ ]] || return 1; option_set "$id" "$key" "$value" ;;
    *) err 'Неизвестное поле узла.'; return 1 ;;
  esac
}
guide_text() {
  cat <<'ZABBIX_EMBEDDED_GUIDE_20261125'
# Zabbix на Astra Linux: только исходники

Итоговый `zabbix_cod_source.sh` — самостоятельный Bash-скрипт. Ansible и Python
для его работы не требуются. Он не устанавливает пакеты и не скачивает готовые
агенты, компиляторы или Go-зависимости. Сборка выполняется из вашего локального
архива исходников на выбранном COD, без глобального `make install`.

## Начало

Скопируйте скрипт на управляющий сервер и откройте меню:

```bash
bash /root/zabbix_cod_source.sh
```

Данные хранятся в `~/.local/state/zabbix-cod-source` с закрытыми правами.
Другой короткий путь можно задать переменной `ZABBIX_SOURCE_STATE`.
Начальный список пуст: адреса 25 актуальных COD неизвестны. Команда `seed-known`
добавляет только 11 COD, отмеченных Astra в вашей исправленной таблице.
Она не подставляет машины, отмеченные там как Windows.

В меню:

```text
seed-known
hosts
set COD05 user sysop
audit COD05
audit all
report
```

Остальные адреса добавляются явно:

```text
add COD22 ACTUAL_ADDRESS sysop 22 jump
```

Вместо `ACTUAL_ADDRESS` нужен настоящий IP или DNS. Для прямого подключения
последний аргумент — `direct`. Список также можно редактировать в `hosts.tsv`
в каталоге состояния: NAME,ADDRESS,PORT,USER,ROUTE,IDENTITY_FILE разделены TAB.

## SSH и sudo

По умолчанию `jump` означает проход через `root@176.211.53.177:2074`.
Ключ берётся из обычного SSH-agent или явно указанного существующего файла.
Закрытые ключи на COD и jump не копируются. Сам SSH-agent на jump не пересылается.
Первый ключ сервера запоминается через `accept-new`; изменение ключа отвергается.

```text
set global jump_user root
set global jump_host 176.211.53.177
set global jump_port 2074
set global jump_key /root/.ssh/EXISTING_JUMP_KEY
set COD05 identity /root/.ssh/EXISTING_TARGET_KEY
```

Имена `EXISTING_*` замените на свои пути; если ключ доступен через ssh-agent,
эти команды не нужны. Пароль SSH при необходимости спрашивает сам OpenSSH.
Пароль sudo вводится скрыто через терминал, передаётся по stdin и не сохраняется
в файлы, аргументы процессов или журналы. Меню запускает каждую команду отдельно,
поэтому пароль может запрашиваться повторно. Нужен действующий доступ root либо
sudo, допускающий запуск Bash без обязательного TTY. Пользователи `sysop`, SSH
ключи и настройки sudo этим скриптом не перенастраиваются.

## Что собирается

`audit` не меняет службу и конфигурацию. Он получает реальные ОС/версию/сборку
Astra, архитектуру, glibc, версии библиотек, инструменты и заголовки сборки,
оба варианта агента, службы systemd, ExecStart, конфиг и состояние процесса.
Содержимое PSK, приватных ключей и конфигураций в отчёт не выгружается.

```text
audit COD05 root
show COD05
plan COD05
report
```

`root` нужен только для чтения недоступных обычному пользователю параметров.
CSV аудита создаётся командой `report`. В нём есть время последнего успешного
сбора и статус последней попытки, чтобы отличать старые данные от свежих.

Любое изменение разрешено только после фактического обнаружения Astra Linux.
Несколько агентов, нестандартные wrapper-службы, симлинки и неразрешимые параметры
не подменяются догадками. При необходимости задайте проверенные значения:

```text
set COD05 service zabbix-agent.service
set COD05 binary /usr/sbin/zabbix_agentd
set COD05 config /etc/zabbix/zabbix_agentd.conf
set COD05 variant classic
```

Скрипт дополнительно сверяет эти значения с реальным ExecStart и процессом.

## Исходники и сборка

Получите официальный архив исходников выбранного выпуска 7.0.x отдельно.
Текущая целевая версия — 7.0.32; её можно изменить командой `set global version`.
При регистрации укажите SHA-256, проверенный по вашему доверенному источнику:

```text
source /root/zabbix-7.0.32.tar.gz EXPECTED_SHA256
build COD05
```

Вместо `EXPECTED_SHA256` нужны 64 шестнадцатеричных символа. Подмена файла после
регистрации также проверяется. Исходный архив должен содержать один release с
`configure`, обычные файлы/каталоги, без ссылок, специальных файлов и `..`-путей.

Сборка использует имеющиеся `cc`, `make`, PCRE2/OpenSSL и их development-файлы.
Недостающие инструменты и заголовки **не устанавливаются**. В этом случае сборка
останавливается, а путь к закрытому `build.log` выводится на экран. Подготовьте
сборочные зависимости из исходников отдельно либо выберите совместимый COD,
где инструменты уже есть. Системный Python не нужен и не меняется.

Тип существующего агента сохраняется. Для Agent2 нужны уже имеющиеся Go и
исходные модули в локальном cache; сетевое скачивание и автоматическое обновление
Go выключены. При их отсутствии сборка остановится. Новая установка по умолчанию
использует обычный C-агент; явный выбор Agent2: `set COD20 variant agent2`.

Собранный файл сохраняется на управляющем сервере вместе с SHA-256 и данными
исходников/окружения. Для другой машины разрешается выбрать эту сборку только
при совпадении ОС, версии Astra, архитектуры, glibc и контрольных сумм библиотек:

```text
set COD09 build_from COD05
```

Если даже одна характеристика отличается или неизвестна, перенос блокируется.
После обновления ОС проверка выполняется заново и для самого узла сборки.

## Установка и обновление

```text
update COD05
install COD20
apply COD20
```

`update` требует существующего агента. `install` требует отсутствия агента.
`apply` выбирает действие по результатам свежего аудита. Перед выполнением
показывается план, затем нужно ввести точное имя COD для подтверждения.

При обновлении прежние конфиг, Include, Hostname, TLS, UserParameter и systemd
команда остаются на месте. Проверяются SHA-256, версия, тип, `-T`, `agent.ping`.
До замены создаётся закрытая резервная копия; замена бинарника атомарная.
Проверяются процесс и версия после перезапуска. При ошибке выполняется откат.
Если файл уже совпадает, работающая служба не перезапускается.

Если при новой установке сохранился старый конфиг — он используется. Если
конфига нет, скрипт спросит Server, ServerActive и Hostname. Можно предоставить
собственный полный конфиг, в том числе TLS-параметры:

```text
set COD20 config_template /root/approved_zabbix_agentd.conf
```

Новая служба запускается от `zabbix`. Только если этого служебного пользователя
нет, он создаётся стандартными командами ОС. Установка пакетов для этого не нужна.
Существующие служебные каталоги и конфиги сохраняются. После неудачной новой
установки удаляются созданные этим запуском служба/бинарник/новый конфиг;
созданная служебная учётная запись и общие каталоги могут остаться.

```text
status COD05
rollback COD05
```

При потере SSH автоматическое восстановление гарантировать нельзя: путь к backup
сохраняется заранее для повторного подключения. Защиты Astra, ЗПС, подписи и
политики целостности скрипт не отключает. Если они не допускают новый файл,
нужна штатная процедура допуска/подписания администратора.

База версий старых системных пакетов при бинарной замене не обновляется.
Фактическая версия проверяется по бинарнику и `agent.version`. После пилота
проверьте поступление данных на сервере Zabbix: локальный `agent.ping` не
подтверждает сетевое соединение с сервером.

Команды `apply all`, `install all`, `update all` последовательны и спрашивают
подтверждение каждого узла. При ошибке партия останавливается. Сначала выполните
пилот на одном COD. Для просмотра этой инструкции: `bash zabbix_cod_source.sh guide`.

Официальные источники:
https://www.zabbix.com/documentation/7.0/en/manual/installation/install
https://www.zabbix.com/documentation/7.0/en/manual/appendix/config/zabbix_agent2
https://docs.astralinux.ru/latest/szi/szi/cse/
ZABBIX_EMBEDDED_GUIDE_20261125
}
help_text() {
  cat <<'HELP'
Команды (Bash 4+, только исходники; пакетные менеджеры не вызываются):
  guide                         полная инструкция
  hosts                         список узлов
  seed-known                    добавить 11 известных Astra COD из исправленной таблицы
  add NAME ADDRESS [USER [PORT [jump|direct [KEYFILE]]]]
  set global version 7.0.32     целевая версия
  set global jump_user root    настройки прокси (также jump_host/jump_port/jump_key)
  set NAME FIELD VALUE          user,port,address,route,identity,binary,config,service,
                                variant,jobs,build_from,config_template,server,
                                server_active,hostname
  source ARCHIVE.tar.gz SHA256  зарегистрировать локальные исходники
  audit NAME|all [root]         только сбор информации; root — через sudo
  show NAME                     последний отчёт
  report                        сохранить сводный CSV аудита
  status NAME                   состояние службы и версия
  plan NAME                     аудит и план
  build NAME                    сборка на узле без make install
  set TARGET build_from BUILDER использовать уже собранный файл при точной совместимости
  install NAME|all              новая установка (лишь если агента нет)
  update NAME|all               обновление с прежним конфигом
  apply NAME|all                выбрать install/update по фактическому состоянию
  rollback NAME                 восстановить предыдущий бинарник
  forget-passwords              забыть sudo-пароли в памяти
  quit                          выход

Новый список узлов изначально пуст: не подставляйте адреса Windows из старой таблицы.
Источник — локальный официальный .tar.gz; скачивание и установка пакетов отсутствуют.
Если инструментов сборки/заголовков нет, скрипт остановится. Сборку можно выполнить
на другом совместимом узле и зарегистрировать через build_from.
В меню аргументы разделяются пробелами. Пути с пробелами задавайте отдельным запуском:
  bash zabbix_cod_source.sh source "/path with space/zabbix.tar.gz" SHA256
HELP
}
dispatch() {
  local cmd=${1:-help} id name
  [[ $# -eq 0 ]] || shift
  case "$cmd" in
    help|--help|-h) help_text ;;
    guide) guide_text ;;
    hosts) printf '%-16s %-24s %-12s %-6s %s\n' NAME ADDRESS USER PORT ROUTE; for id in "${!H_ADDR[@]}"; do printf '%-16s %-24s %-12s %-6s %s\n' "$id" "${H_ADDR[$id]}" "${H_USER[$id]}" "${H_PORT[$id]}" "${H_ROUTE[$id]}"; done | sort ;;
    seed-known) [[ $# -eq 0 ]] || return 1;seed_known ;;
    add) [[ $# -ge 2 && $# -le 6 ]] || { err 'add NAME ADDRESS [USER PORT ROUTE KEYFILE]'; return 1; };save_host "$1" "$2" "${4:-22}" "${3:-sysop}" "${5:-jump}" "${6:-}" ;;
    set) [[ $# -eq 3 ]] || return 1;set_value "$@" ;;
    source) [[ $# -eq 2 ]] || return 1;register_source "$@" ;;
    audit|install|update|apply)
      [[ $# -ge 1 && $# -le 2 ]] || return 1; id=$1
      local failed=0
      local -a targets=()
      if [[ $id == all ]]; then
        ((${#H_ADDR[@]} > 0)) || { err 'Список узлов пуст.'; return 1; }
        mapfile -t targets < <(printf '%s\n' "${!H_ADDR[@]}" | sort)
      else require_host "$id";targets=("$id");fi
      for name in "${targets[@]}"; do
        if [[ $cmd == audit ]]; then
          if ! audit_one "$name" "$( [[ ${2:-} == root ]] && printf yes || printf no )"; then say "Не удалось: $name" >&2; failed=1; fi
        else deploy_one "$name" "$cmd"; fi
      done
      [[ $failed -eq 0 ]] ;;
    report) [[ $# -eq 0 ]] || return 1;report_csv ;;
    build|plan|show|rollback|status) [[ $# -eq 1 ]] || return 1; case "$cmd" in build)build_one "$1";;plan)plan_one "$1";;show)show_one "$1";;rollback)rollback_one "$1";;status)status_one "$1";;esac ;;
    forget-passwords) SUDO_SECRET=();say 'Пароли удалены из переменных текущей сессии.' ;;
    quit|exit) return 99 ;;
    *) err "Неизвестная команда: $cmd" ;;
  esac
}
cleanup_controller() { SUDO_SECRET=(); }
trap cleanup_controller EXIT

main() {
  if [[ ${1:-} == --help || ${1:-} == -h || ${1:-} == help ]]; then help_text; return; fi
  if [[ ${1:-} == guide ]]; then guide_text; return; fi
  init_state
  if [[ $# -gt 0 ]]; then dispatch "$@"; return; fi
  say "Zabbix из исходников. Состояние: $STATE"
  say "Узлов: ${#H_ADDR[@]}; целевая версия: ${CFG[version]}. help — список команд."
  local line status
  local -a words
  while true; do
    tty_read line 'zabbix-source> ' || break
    [[ -n $line ]] || continue
    read -r -a words <<<"$line"
    # Execute outside a conditional context: `if dispatch` would disable Bash
    # errexit inside every nested build/deploy function.
    set +e
    ( set -Eeuo pipefail; dispatch "${words[@]}" )
    status=$?
    set -e
    [[ $status != 99 ]] || break
    if [[ $status != 0 ]]; then say "Команда не выполнена (код $status)." >&2; fi
    load_settings; load_hosts
  done
}
main "$@"
