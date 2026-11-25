#!/usr/bin/env bash
# Local, source-only Zabbix classic agent maintenance. No SSH or package installation.
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C
LAUNCH_DIR=$(pwd -P)
WORK="$LAUNCH_DIR/.zabbix-source-work"
PREFIX="$WORK/deps/prefix"
TARGET_VERSION=7.0.32
AUDIT=''

say() { printf '%s\n' "$*"; }
fail() { printf 'ОШИБКА: %s\n' "$*" >&2; return 1; }
worker_payload() {
  cat <<'ZABBIX_LOCAL_EMBEDDED_WORKER_20261125'
#!/usr/bin/env bash
set +x
# Local source-only Zabbix operations. No package manager is invoked.
set -euo pipefail
umask 077
export LC_ALL=C
export GOPROXY=off GOTOOLCHAIN=local GOSUMDB=off
LOCAL_WORK_ROOT=${ZABBIX_LOCAL_WORK_ROOT:-"$PWD/.zabbix-source-work"}

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
work_root() {
    safe_path "$LOCAL_WORK_ROOT" && [[ -d "$LOCAL_WORK_ROOT" && ! -L "$LOCAL_WORK_ROOT" ]] || die 'Invalid local work directory.'
    [[ $(canonical "$LOCAL_WORK_ROOT") == "$LOCAL_WORK_ROOT" ]] || die 'Local work directory must not contain symlinks.'
    [[ $(stat -c %u -- "$LOCAL_WORK_ROOT") == "$EUID" ]] || die 'Local work directory must be owned by the current user.'
    printf '%s' "$LOCAL_WORK_ROOT"
}
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
    emit hostname "$(hostname 2>/dev/null || true)"
    emit addresses "$(hostname -I 2>/dev/null || true)"
    emit os_id "$(release_value ID)"
    emit os_version "$(release_value VERSION_ID)"
    emit os_name "$(release_value PRETTY_NAME)"
    if is_astra; then emit astra yes; else emit astra no; fi
    emit astra_version "$(cat /etc/astra_version 2>/dev/null || true)"
    emit astra_build "$(cat /etc/astra/build_version 2>/dev/null || true)"
    emit architecture "$(uname -m 2>/dev/null || true)"
    emit glibc "$(getconf GNU_LIBC_VERSION 2>/dev/null || true)"
    emit kernel "$(uname -r 2>/dev/null || true)"
    emit disk_work_free_kb "$(df -Pk "$PWD" 2>/dev/null | awk 'NR==2 {print $4}')"
    emit cpu_count "$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)"
    emit mem_available_kb "$(awk '/^MemAvailable:/ {print $2;exit}' /proc/meminfo 2>/dev/null || true)"
    for path in cc make tar sha256sum ar ranlib ld perl gzip; do
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
    local extra_features='' dynamic='' feature_binary feature_config
    feature_binary=${selected_binary:-$classic_found}
    feature_config=$selected_config
    if [[ -n "$feature_binary" && -f "$feature_binary" ]];then
        if command -v readelf >/dev/null;then dynamic=$(readelf -d -- "$feature_binary" 2>/dev/null || true)
        elif command -v ldd >/dev/null;then dynamic=$(ldd "$feature_binary" 2>/dev/null || true);fi
        [[ "$dynamic" != *libcurl* ]] || extra_features+='libcurl '
        [[ "$dynamic" != *libldap* && "$dynamic" != *liblber* ]] || extra_features+='libldap '
        [[ "$dynamic" != *libmodbus* ]] || extra_features+='libmodbus '
    fi
    if [[ -n "$feature_config" && -r "$feature_config" ]] && grep -qE '^[[:space:]]*LoadModule[[:space:]]*=' "$feature_config";then
        extra_features+='LoadModule '
    fi
    emit extra_features "$extra_features"
    emit sudo_noninteractive "$([[ $EUID -eq 0 ]] && printf yes || printf not-tested)"
    emit sudo_command "$(command -v sudo 2>/dev/null || true)"
    emit package_installation prohibited
}
workspace() {
    require_astra
    local dir root
    root=$(work_root)
    [[ -d "$root/builds" && ! -L "$root/builds" ]] || die 'Local builds directory is missing.'
    dir=$(mktemp -d "$root/builds/build.XXXXXXXX")
    chmod 0700 "$dir"
    begin;emit workspace "$dir"
}
build_agent() {
    local dir=${1-} source_sha=${2-} version=${3-} jobs=${4-2} variant=${5-classic} deps=${6-} root
    require_astra
    root=$(work_root)
    safe_path "$dir" && [[ "$dir" == "$root"/builds/build.* && -d "$dir" && ! -L "$dir" && $(canonical "$dir") == "$dir" ]] || die 'Invalid private local workspace.'
    [[ $(stat -c %u -- "$dir") == "$EUID" ]] || die 'Build workspace is owned by another user.'
    [[ "$source_sha" =~ ^[A-Fa-f0-9]{64}$ ]] || die 'Invalid source SHA-256.'
    safe_version "$version" || die 'Only stable Zabbix 7.0.x is supported.'
    [[ "$jobs" =~ ^[1-9][0-9]?$ ]] || die 'Build jobs must be an integer from 1 to 99.'
    [[ "$variant" == classic ]] || die 'This local installer supports the classic C agent only; Agent2 will not be replaced.'
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
    local configure_flags=(--prefix=/usr/local --sysconfdir=/etc/zabbix --enable-ipv6)
    if [[ -n "$deps" ]]; then
        safe_path "$deps" && [[ "$deps" == "$root"/deps/prefix && -d "$deps" && ! -L "$deps" && $(canonical "$deps") == "$deps" ]] || die 'Invalid local dependency prefix.'
        for item in include/pcre2.h include/openssl/ssl.h lib/libpcre2-8.a lib/libssl.a lib/libcrypto.a;do
            [[ -f "$deps/$item" && ! -L "$deps/$item" ]] || die "Missing locally built dependency: $item"
        done
        configure_flags+=("--with-libpcre2=$deps" "--with-openssl=$deps")
    else
        configure_flags+=(--with-libpcre2 --with-openssl)
    fi
    if [[ "$variant" == classic ]];then configure_flags+=(--enable-agent);name=zabbix_agentd;else configure_flags+=(--enable-agent2);name=zabbix_agent2;fi
    local log="$dir/build.log"
    # No make install. Go is offline and may use only existing local modules/toolchain.
    if ! (cd "$source"; export TMPDIR="$root/tmp" GOPROXY=off GOTOOLCHAIN=local GOSUMDB=off GOFLAGS=-mod=readonly GOAMD64=v1 CFLAGS='-O2' CXXFLAGS='-O2'; unset GOARCH GOOS LD_LIBRARY_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH; if [[ -n "$deps" ]];then export PATH="$deps/bin:$PATH" CPPFLAGS="-I$deps/include" LDFLAGS="-L$deps/lib" LIBS='-ldl -lpthread' PKG_CONFIG_PATH="$deps/lib/pkgconfig" PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig";fi; ./configure "${configure_flags[@]}" && make -j "$jobs") >"$log" 2>&1; then
        begin;emit build_log "$log";die 'Source compilation failed. Inspect the private build.log; missing dependencies are not installed automatically.'
    fi
    if [[ "$variant" == classic ]];then output="$source/src/zabbix_agent/zabbix_agentd";else output="$source/src/go/bin/zabbix_agent2";fi
    [[ -x "$output" ]] || die 'Build completed without the expected agent binary.'
    if [[ -n "$deps" ]];then
        local dynamic
        command -v ldd >/dev/null || die 'Cannot verify runtime library dependencies: existing ldd is required.'
        dynamic=$(ldd "$output" 2>&1 || true)
        [[ "$dynamic" != *'not found'* && "$dynamic" != *"$root"* && "$dynamic" != *libpcre2-* && "$dynamic" != *libssl.so* && "$dynamic" != *libcrypto.so* ]] || die 'Agent still depends on external/private PCRE2 or OpenSSL libraries. Inspect build.log.'
    fi
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
    local root dir
    root=$(work_root);dir="$root/backups"
    [[ ! -L "$dir" ]] || die 'Backup directory must not be a symlink.'
    mkdir -p -- "$dir"
    chmod 0700 "$dir"
    chown root:root "$dir"
    mktemp -d "$dir/transaction.XXXXXXXX"
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
        TMPDIR="$helper_dir" cc -O2 -o "$helper_dir/metadata-copy" "$helper_dir/metadata-copy.c" >"$helper_dir/metadata-build.log" 2>&1 || die 'Cannot compile the embedded attribute helper; original binary remains unchanged.'
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
    local backup=${1-} mode binary config service was_active version unit root
    require_astra;require_root
    root=$(work_root)
    safe_path "$backup" && [[ "$backup" == "$root"/backups/transaction.* && -d "$backup" && ! -L "$backup" && $(canonical "$backup") == "$backup" ]] || die 'Invalid local transaction backup directory.'
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
    local variant current_variant='' current_version='' backup='' staged='' validation_log='' was_active=no new_config=no binary_replaced=no root
    require_astra;require_root
    root=$(work_root)
    [[ "$mode" == update || "$mode" == install ]] || die 'Mode must be update or install.'
    safe_path "$artifact" && safe_path "$binary" && safe_path "$config" && safe_service "$service" || die 'Unsafe path or service name.'
    [[ "$expected_sha" =~ ^[A-Fa-f0-9]{64}$ ]] && safe_version "$version" || die 'Invalid checksum or release.'
    [[ -f "$artifact" && ! -L "$artifact" ]] || die 'Prepared source-build artifact is missing.'
    [[ "$artifact" == "$root"/builds/build.*/* && $(canonical "$artifact") == "$artifact" ]] || die 'Artifact must come from the local source build workspace.'
    [[ $(sha256sum "$artifact" | awk '{print $1}') == "${expected_sha,,}" ]] || die 'Transferred artifact checksum mismatch.'
    # SCP/SFTP or streamed upload may have stripped execute bits; this is only
    # the private uploaded artifact, never the installed target executable.
    chmod 0755 -- "$artifact"
    [[ ! -L "$binary" && ! -L "$config" ]] || die 'Symlinked binary/config needs manual review.'
    variant=$(variant_of "$artifact") || die 'Artifact is not a Zabbix agent.'
    [[ "$variant" == classic ]] || die 'This local installer supports the classic C agent only; Agent2 will not be replaced.'
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
ZABBIX_LOCAL_EMBEDDED_WORKER_20261125
}
run_worker() { worker_payload | ZABBIX_LOCAL_WORK_ROOT="$WORK" bash -s -- "$@"; }
field() {
  local report=$1 key=$2 value
  value=$(printf '%s\n' "$report" | awk -F '\t' -v k="$key" '$1==k {print $2;exit}')
  [[ -z $value ]] || printf '%s' "$value" | base64 -d
}
option() {
  local key=$1
  [[ -f "$WORK/settings.tsv" ]] || return 0
  field "$(cat -- "$WORK/settings.tsv")" "$key"
}
put_option() {
  local key=$1 value=$2 temp
  [[ $key =~ ^[a-z][a-z0-9_]*$ ]] || return 1
  temp=$(mktemp "$WORK/tmp/setting.XXXXXXXX")
  if [[ -f "$WORK/settings.tsv" ]]; then awk -F '\t' -v k="$key" '$1!=k' "$WORK/settings.tsv" >"$temp"; fi
  printf '%s\t' "$key" >>"$temp"
  printf '%s' "$value" | base64 | tr -d '\n' >>"$temp"
  printf '\n' >>"$temp"
  chmod 600 "$temp"; mv -f -- "$temp" "$WORK/settings.tsv"
}
init_work() {
  [[ "$WORK" =~ ^/[A-Za-z0-9_./+:-]+$ ]] || { fail 'Для сборки нужен каталог запуска с латинскими буквами/цифрами, без пробелов: например /opt/zabbix-source.'; return 1; }
  [[ ! -L "$WORK" ]] || { fail 'Рабочий каталог не должен быть символической ссылкой.'; return 1; }
  if [[ -e "$WORK" ]]; then
    [[ -d "$WORK" && $(stat -c %u -- "$WORK") == "$EUID" ]] || { fail 'Рабочий каталог должен принадлежать текущему пользователю. Все команды выполняйте от одной учётной записи (для установки — root).'; return 1; }
    [[ $(stat -c %a -- "$WORK") == 700 ]] || { fail 'У существующего рабочего каталога должны быть права 0700.'; return 1; }
  else mkdir -m 0700 -- "$WORK"; fi
  local dir
  for dir in sources builds deps logs backups reports tmp; do
    [[ ! -L "$WORK/$dir" ]] || { fail "Символическая ссылка в рабочем каталоге: $dir"; return 1; }
    mkdir -p -- "$WORK/$dir"; chmod 700 "$WORK/$dir"
  done
  [[ ! -L "$PREFIX" ]] || { fail "Символическая ссылка вместо локального prefix."; return 1; }
  mkdir -p -- "$PREFIX"
  [[ $(stat -c %u -- "$PREFIX") == "$EUID" ]] || { fail "Локальный prefix принадлежит другому пользователю."; return 1; }
}
read_tty() {
  local name=$1 prompt=$2
  [[ -r /dev/tty && -w /dev/tty ]] || { fail 'Для подтверждения нужен интерактивный терминал.'; return 1; }
  printf '%s' "$prompt" >/dev/tty
  IFS= read -r "$name" </dev/tty
}
confirm() {
  local expected=$1 answer
  read_tty answer "Для продолжения введите $expected: "
  [[ "$answer" == "$expected" ]] || { fail 'Отменено.'; return 1; }
}
refresh_audit() {
  AUDIT=$(run_worker audit)
  [[ "$AUDIT" == ZA_AUDIT_V1$'\n'* ]] || { fail 'Не получен корректный анализ системы.'; return 1; }
}
display_audit() {
  local key value
  say "Каталог запуска: $LAUNCH_DIR"
  say "Исходники, зависимости, сборки, отчёты и backup: $WORK"
  say "Целевая версия: $TARGET_VERSION; установка пакетов запрещена."
  for key in hostname addresses os_name os_version astra_version astra_build architecture glibc kernel cpu_count mem_available_kb disk_work_free_kb initial_user astra variant version classic_binary classic_version agent2_binary agent2_version service service_state binary config config_exists orphan_configs ambiguous tools_missing build_ready pcre2_version openssl_version extra_features candidates; do
    value=$(field "$AUDIT" "$key")
    printf '%-19s %s\n' "$key:" "${value:--}"
  done
  say 'Анализ завершён. Служба, конфиги и системные файлы не изменялись.'
}
analyze() { refresh_audit; display_audit; }
guard_astra() {
  [[ $(field "$AUDIT" astra) == yes ]] || { fail 'Изменения разрешены только на фактически обнаруженной Astra Linux.'; return 1; }
}
guard_classic() {
  [[ $(field "$AUDIT" variant) != agent2 ]] || { fail 'Обнаружен Zabbix Agent 2. Этот локальный скрипт собирает только классический zabbix_agentd и не заменяет Agent 2.'; return 1; }
  if [[ -z $(field "$AUDIT" binary) && -n $(field "$AUDIT" agent2_binary) ]]; then
    fail 'Найден Agent 2 без однозначной службы; новая установка классического агента заблокирована.'; return 1
  fi
}
safe_extract() {
  local archive=$1 destination=$2
  tar -tzf "$archive" | awk '/^\// {bad=1} /(^|\/)\.\.($|\/)/ {bad=1} END{exit bad}' || { fail 'Архив содержит опасный путь.'; return 1; }
  if tar -tvzf "$archive" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END{exit !bad}'; then fail 'В исходном архиве есть ссылки или специальные файлы; они не разрешены.'; return 1; fi
  mkdir -m 0700 -- "$destination"
  tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$destination"
}
register_archive() {
  local name=$1 archive=$2 expected=$3 actual destination
  [[ "$name" == zabbix || "$name" == pcre2 || "$name" == openssl ]] || { fail 'Имя исходников: zabbix, pcre2 или openssl.'; return 1; }
  [[ -f "$archive" && ! -L "$archive" && "$expected" =~ ^[A-Fa-f0-9]{64}$ ]] || { fail 'Нужны локальный .tar.gz и доверенная SHA-256 (64 hex символа).'; return 1; }
  actual=$(sha256sum -- "$archive" | awk '{print $1}')
  [[ "$actual" == "${expected,,}" ]] || { fail 'SHA-256 исходников не совпадает.'; return 1; }
  init_work
  destination="$WORK/sources/$name-$actual.tar.gz"
  if [[ ! -f "$destination" ]]; then cp -- "$archive" "$destination"; chmod 400 "$destination"; fi
  put_option "${name}_archive" "$destination"
  put_option "${name}_sha" "$actual"
  say "Зарегистрирован архив $name: $destination"
}
fetch_archive() {
  local name=$1 url=$2 sha=$3 temp
  [[ "$name" == zabbix || "$name" == pcre2 || "$name" == openssl ]] || { fail 'fetch NAME URL SHA: NAME — zabbix/pcre2/openssl.'; return 1; }
  [[ "$url" == https://* && "$url" != *$'\n'* && "$url" != *$'\r'* && "$sha" =~ ^[A-Fa-f0-9]{64}$ ]] || { fail 'fetch требует HTTPS URL и заранее проверенную SHA-256.'; return 1; }
  init_work
  temp=$(mktemp "$WORK/sources/download.XXXXXXXX.tar.gz")
  if command -v curl >/dev/null; then
    if ! curl --disable --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 900 --retry 1 --output "$temp" -- "$url"; then rm -f -- "$temp"; offline_instructions; fail 'Скачивание не удалось.'; return 1; fi
  elif command -v wget >/dev/null; then
    if ! wget --https-only --timeout=15 --tries=2 --output-document="$temp" -- "$url"; then rm -f -- "$temp"; offline_instructions; fail 'Скачивание не удалось.'; return 1; fi
  else rm -f -- "$temp"; offline_instructions; fail 'Нет curl/wget. Их установка запрещена.'; return 1; fi
  register_archive "$name" "$temp" "$sha"
  rm -f -- "$temp"
}
offline_instructions() {
  printf '%s\n' 'Для работы без сети перенесите через RDP в текущий каталог запуска три официальных архива:' '  zabbix-7.0.32.tar.gz' '  pcre2-10.47.tar.gz' '  openssl-3.5.9.tar.gz' "Каталог: $LAUNCH_DIR" 'Затем повторите prepare или apply. Их SHA-256 будут проверены автоматически; пакеты не требуются.' >&2
}
download_metadata() {
  local url=$1 destination=$2
  if command -v curl >/dev/null; then
    if ! curl --disable --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 60 --retry 1 --max-filesize 1048576 --output "$destination" -- "$url"; then offline_instructions; fail 'Не удалось получить официальный SHA-256 файл.'; return 1; fi
  elif command -v wget >/dev/null; then
    if ! wget --https-only --timeout=15 --tries=2 --output-document="$destination" -- "$url"; then offline_instructions; fail 'Не удалось получить официальный SHA-256 файл.'; return 1; fi
  else offline_instructions; fail 'Нет curl/wget.'; return 1; fi
}
prepare() {
  init_work
  local name version url sha checksum_file actual current current_sha nearby only_missing=${1-no}
  local manifest="$WORK/sources/official-sources.tsv"
  cat >"$manifest" <<'SOURCES'
zabbix	7.0.32	https://cdn.zabbix.com/zabbix/sources/stable/7.0/zabbix-7.0.32.tar.gz	ead5b0723ad965eb0e79f98d5d2b89088e7c898ae194eeba767e5d1fb2d50a96
pcre2	10.47	https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz	c08ae2388ef333e8403e670ad70c0a11f1eed021fd88308d7e02f596fcd9dc16
openssl	3.5.9	https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz	603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
SOURCES
  say 'prepare скачивает только официальные исходники Zabbix, PCRE2 и OpenSSL в каталог запуска. Пакеты и готовые агенты не скачиваются.'
  while IFS=$'\t' read -r name version url sha; do
    current=$(option "${name}_archive"); current_sha=$(option "${name}_sha")
    if [[ -f "$current" && ! -L "$current" && "$current" == "$WORK/sources/"* && "$current_sha" =~ ^[a-f0-9]{64}$ && $(sha256sum -- "$current" | awk '{print $1}') == "$current_sha" ]]; then
      if [[ "$only_missing" == yes || "$current_sha" == "$sha" ]]; then say "$name: проверенные исходники уже есть."; continue; fi
    fi
    nearby="$LAUNCH_DIR/${url##*/}"
    if [[ -e "$nearby" ]]; then
      [[ -f "$nearby" && ! -L "$nearby" && $(sha256sum -- "$nearby" | awk '{print $1}') == "$sha" ]] || { fail "Найденный рядом архив $nearby не совпадает с доверенным SHA-256 или является ссылкой. Замените его официальным архивом."; return 1; }
      register_archive "$name" "$nearby" "$sha"
      printf '%s\n' "$sha" >"$WORK/sources/$name-$version.tar.gz.sha256"
      say "$name: использован локальный архив, сеть не требовалась."
      continue
    fi
    if [[ "$name" != pcre2 ]]; then
      checksum_file="$WORK/sources/$name-$version.tar.gz.sha256"
      download_metadata "$url.sha256" "$checksum_file"
      actual=$(grep -oE '[a-fA-F0-9]{64}' "$checksum_file" || true)
      [[ "$actual" == "$sha" ]] || { fail "Официальная SHA-256 $name отличается от закреплённого значения. Скачивание/сборка остановлены; проверьте release вручную."; return 1; }
    else
      printf '%s\n%s\n' "$sha" 'https://github.com/PCRE2Project/pcre2/attestations/12152412' >"$WORK/sources/pcre2-$version.attestation.txt"
    fi
    fetch_archive "$name" "$url" "$sha"
  done <"$manifest"
  say 'Исходники подготовлены. Для плана, сборки и установки выполните apply.'
}
archives_ready() {
  local name archive sha
  for name in zabbix pcre2 openssl; do
    archive=$(option "${name}_archive"); sha=$(option "${name}_sha")
    [[ -f "$archive" && ! -L "$archive" && "$archive" == "$WORK/sources/"* && "$sha" =~ ^[a-f0-9]{64}$ && $(sha256sum -- "$archive" | awk '{print $1}') == "$sha" ]] || return 1
  done
}
checked_archive() {
  local name=$1 archive sha
  archive=$(option "${name}_archive"); sha=$(option "${name}_sha")
  [[ -f "$archive" && "$archive" == "$WORK/sources/"* && "$sha" =~ ^[a-f0-9]{64}$ ]] || { fail "Нет исходников $name. Команда: $([[ "$name" == zabbix ]] && printf 'source FILE SHA256' || printf 'dependency %s FILE SHA256' "$name"). Архивы и SHA перенесите вручную либо используйте fetch."; return 1; }
  [[ $(sha256sum -- "$archive" | awk '{print $1}') == "$sha" ]] || { fail "Изменился SHA-256 зарегистрированного архива $name."; return 1; }
  printf '%s' "$archive"
}
check_toolchain() {
  local tool
  for tool in cc make tar sha256sum; do command -v "$tool" >/dev/null || { fail "Отсутствует $tool. Пакеты не устанавливаются; нужен уже имеющийся компилятор/инструмент."; return 1; }; done
}
dependency_ready() {
  local name=$1 sha
  sha=$(option "${name}_sha")
  [[ -n "$sha" && -f "$PREFIX/.${name}.sha256" && $(cat "$PREFIX/.${name}.sha256") == "$sha" ]] || return 1
  if [[ "$name" == pcre2 ]]; then [[ -s "$PREFIX/lib/libpcre2-8.a" && -r "$PREFIX/include/pcre2.h" ]]
  else [[ -s "$PREFIX/lib/libssl.a" && -s "$PREFIX/lib/libcrypto.a" && -r "$PREFIX/include/openssl/ssl.h" ]]; fi
}
build_dependency() {
  local name=$1 archive source stage log item
  archive=$(checked_archive "$name")
  if dependency_ready "$name"; then say "$name: локальная сборка уже подготовлена."; return; fi
  stage=$(mktemp -d "$WORK/builds/$name.XXXXXXXX")
  log="$stage/build.log"
  safe_extract "$archive" "$stage/src"
  local candidates=()
  if [[ "$name" == pcre2 ]]; then
    while IFS= read -r item; do candidates+=("$item"); done < <(find "$stage/src" -maxdepth 2 -type f -name configure -print)
  else
    while IFS= read -r item; do candidates+=("$item"); done < <(find "$stage/src" -maxdepth 2 -type f -name Configure -print)
  fi
  [[ ${#candidates[@]} -eq 1 ]] || { fail "Архив $name должен содержать один release. Каталог: $stage"; return 1; }
  source=$(dirname "${candidates[0]}")
  say "Сборка $name только в локальный prefix. Журнал: $log"
  if [[ "$name" == pcre2 ]]; then
    if ! (cd "$source" || exit; export TMPDIR="$WORK/tmp" CFLAGS='-O2'; ./configure --prefix="$PREFIX" --libdir="$PREFIX/lib" --disable-shared --enable-static --enable-unicode --disable-jit --disable-pcre2grep-libz --disable-pcre2grep-libbz2 --disable-pcre2test-libreadline --disable-pcre2test-libedit && make -j 2 && make install) >"$log" 2>&1; then fail "Сборка PCRE2 не удалась. Пакеты не устанавливались. Журнал: $log"; return 1; fi
  else
    command -v perl >/dev/null || { fail 'Для сборки OpenSSL нужен уже имеющийся Perl. Автоматическая установка запрещена.'; return 1; }
    [[ -f "$source/VERSION.dat" ]] && grep -qE '^MAJOR=3$' "$source/VERSION.dat" || { fail 'Используйте официальный source release OpenSSL 3.x с VERSION.dat (MAJOR=3).'; return 1; }
    if ! (cd "$source" || exit; export TMPDIR="$WORK/tmp" CFLAGS='-O2'; ./config --prefix="$PREFIX" --openssldir="$PREFIX/ssl" --libdir=lib no-shared no-module no-zlib no-autoload-config no-tests && make -j 2 && make install_sw) >"$log" 2>&1; then fail "Сборка OpenSSL не удалась. Пакеты не устанавливались. Журнал: $log"; return 1; fi
  fi
  printf '%s\n' "$(option "${name}_sha")" >"$PREFIX/.${name}.sha256"
  dependency_ready "$name" || { fail "Сборка $name не создала ожидаемые статические библиотеки."; return 1; }
  say "$name: готово."
}
build_deps() {
  refresh_audit; guard_astra; guard_classic
  check_toolchain
  # Validate both archives before creating or compiling anything.
  checked_archive pcre2 >/dev/null; checked_archive openssl >/dev/null
  init_work
  build_dependency pcre2
  build_dependency openssl
}
build_agent() {
  local archive sha dir result artifact digest
  refresh_audit; guard_astra; guard_classic
  archive=$(checked_archive zabbix); sha=$(option zabbix_sha)
  check_toolchain
  if ! dependency_ready pcre2 || ! dependency_ready openssl; then build_deps; fi
  init_work
  result=$(run_worker workspace)
  dir=$(field "$result" workspace)
  [[ "$dir" == "$WORK/builds/build."* && -d "$dir" && ! -L "$dir" ]] || { fail 'Некорректный каталог сборки worker.'; return 1; }
  cp -- "$archive" "$dir/source.tar.gz"
  say "Сборка Zabbix $TARGET_VERSION. Журнал: $dir/build.log"
  if ! result=$(run_worker build "$dir" "$sha" "$TARGET_VERSION" 2 classic "$PREFIX"); then
    printf '%s\n' "$result" >"$WORK/logs/build-failed.tsv"
    fail "Сборка остановлена. $(field "$result" error) Журнал: $dir/build.log"; return 1
  fi
  artifact=$(field "$result" artifact); digest=$(field "$result" sha256)
  [[ "$artifact" == "$dir/artifact/"* && -f "$artifact" && "$digest" =~ ^[a-f0-9]{64}$ ]] || { fail 'Не получен проверенный результат сборки.'; return 1; }
  [[ $(sha256sum -- "$artifact" | awk '{print $1}') == "$digest" ]] || { fail 'SHA-256 результата сборки не совпадает.'; return 1; }
  printf '%s\n' "$result" >"$WORK/logs/build.tsv"
  printf '%s\n' "$AUDIT" >"$WORK/logs/build-audit.tsv"
  put_option artifact "$artifact"; put_option artifact_sha "$digest"; put_option built_source_sha "$sha"
  put_option built_pcre2_sha "$(option pcre2_sha)"; put_option built_openssl_sha "$(option openssl_sha)"
  say "Собранный файл: $artifact. Служба ещё не изменена."
}
artifact_ready() {
  local artifact digest previous key actual
  artifact=$(option artifact); digest=$(option artifact_sha)
  [[ -f "$artifact" && "$artifact" == "$WORK/builds/"* && "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ $(sha256sum -- "$artifact" | awk '{print $1}') == "$digest" ]] || return 1
  [[ $(option built_source_sha) == "$(option zabbix_sha)" && -f "$WORK/logs/build-audit.tsv" ]] || return 1
  [[ -n $(option built_pcre2_sha) && $(option built_pcre2_sha) == "$(option pcre2_sha)" && -n $(option built_openssl_sha) && $(option built_openssl_sha) == "$(option openssl_sha)" ]] || return 1
  previous=$(cat -- "$WORK/logs/build-audit.tsv")
  for key in os_id os_version astra_version architecture glibc; do
    actual=$(field "$AUDIT" "$key")
    [[ -n "$actual" && "$actual" == "$(field "$previous" "$key")" ]] || return 1
  done
}
selected() { local value; value=$(option "$1"); [[ -n "$value" ]] || value=$(field "$AUDIT" "$1"); printf '%s' "$value"; }
new_config() {
  local destination=$1 server active hostname
  read_tty server 'Server (разрешённый сервер/proxy пассивных проверок; пусто для active-only): '
  read_tty active 'ServerActive (сервер/proxy активных проверок; пусто для passive-only): '
  hostname=$(hostname -s)
  local answer
  read_tty answer "Hostname в Zabbix [$hostname]: "
  hostname=${answer:-$hostname}
  [[ -n "$server" || -n "$active" ]] || { fail 'Нужен Server или ServerActive.'; return 1; }
  [[ "$server" =~ ^[A-Za-z0-9_.,:/-]*$ && "$active" =~ ^[A-Za-z0-9_.,:/-]*$ && "$hostname" =~ ^[A-Za-z0-9_.-]+$ ]] || { fail 'Некорректные значения нового конфига.'; return 1; }
  {
    printf 'LogFile=/var/log/zabbix/zabbix_agent_source.log\nPidFile=/run/zabbix-source/agent.pid\nHostname=%s\n' "$hostname"
    if [[ -n "$server" ]]; then printf 'Server=%s\n' "$server"; else printf 'StartAgents=0\n'; fi
    [[ -z "$active" ]] || printf 'ServerActive=%s\n' "$active"
  } >"$destination"
}
deploy() {
  local request=$1 binary config service mode orphan answer supplied='' result backup item
  [[ $EUID -eq 0 ]] || { fail 'Для установки/обновления запустите скрипт от root в этом же каталоге. Скрипт сам не меняет sudo и не устанавливает пакеты.'; return 1; }
  refresh_audit; guard_astra; guard_classic
  if [[ $(field "$AUDIT" ambiguous) == yes ]]; then
    for item in binary config service; do [[ -n $(option "$item") ]] || { fail 'Обнаружены неоднозначные агенты/службы. Задайте set binary/config/service перед изменениями.'; return 1; }; done
  fi
  binary=$(selected binary); config=$(selected config); service=$(selected service)
  if [[ -n "$binary" && "$binary" != none ]]; then mode=update; else mode=install; fi
  [[ "$request" == apply || "$request" == "$mode" ]] || { fail "По результату анализа нужна команда $mode."; return 1; }
  if [[ "$mode" == update && -n $(field "$AUDIT" extra_features) ]]; then
    fail "У старого агента обнаружены дополнительные библиотеки/модули: $(field "$AUDIT" extra_features). Нужна сборка с сохранением этих опций; минимальная сборка обновление не выполнит."; return 1
  fi
  if [[ "$mode" == install ]]; then
    binary=${binary:-/usr/local/sbin/zabbix_agentd}
    if [[ -z "$config" ]]; then
      orphan=$(field "$AUDIT" orphan_config)
      if [[ -n "$orphan" ]]; then config=$orphan
      elif [[ -n $(field "$AUDIT" orphan_configs) ]]; then fail 'Найдено несколько старых конфигов. Укажите нужный: set config /absolute/path'; return 1
      else config=/etc/zabbix/zabbix_agentd.conf; fi
    fi
    service=${service:-zabbix-agent-source.service}
  fi
  [[ -n "$binary" && -n "$config" && -n "$service" ]] || { fail 'Не определены binary/config/service. Задайте их командами set.'; return 1; }
  printf '\nПлан: %s Zabbix %s на %s\nБинарник: %s\nКонфиг: %s\nСлужба: %s\n' "$mode" "$TARGET_VERSION" "$(hostname)" "$binary" "$config" "$service"
  say "Зависимости будут собраны локально в $WORK/deps; системные пакеты не устанавливаются."
  if [[ -f "$config" ]]; then say 'Существующий конфиг будет сохранён и использован без перезаписи.'; fi
  confirm "$(hostname)"
  # After explicit approval perform the entire local source workflow.
  init_work
  if ! artifact_ready; then
    if ! archives_ready; then prepare yes; fi
    build_agent
  fi
  if [[ "$mode" == install && ! -f "$config" ]]; then
    supplied=$(mktemp "$WORK/tmp/new-config.XXXXXXXX")
    new_config "$supplied"
  fi
  result=''
  if result=$(run_worker deploy "$mode" "$(option artifact)" "$(option artifact_sha)" "$TARGET_VERSION" "$binary" "$config" "$service" "$supplied"); then
    printf '%s\n' "$result" >"$WORK/logs/deploy.tsv"
    backup=$(field "$result" backup)
    [[ -z "$backup" ]] || put_option backup "$backup"
    say "Статус: $(field "$result" status). Резервная копия: $(option backup)"
    say 'Проверьте agent.version и поступление данных на сервере Zabbix.'
  else
    printf '%s\n' "$result" >"$WORK/logs/deploy-failed.tsv"
    backup=$(field "$result" backup)
    [[ -z "$backup" ]] || put_option backup "$backup"
    [[ -z "$supplied" ]] || rm -f -- "$supplied"
    fail "$(field "$result" error) Смотрите журнал $WORK/logs/deploy-failed.tsv; backup: $(option backup)"; return 1
  fi
  [[ -z "$supplied" ]] || rm -f -- "$supplied"
}
status() {
  local service result
  refresh_audit; service=$(selected service)
  [[ -n "$service" ]] || { display_audit; return; }
  result=$(run_worker status "$service")
  say "Служба: $service; состояние: $(field "$result" service_state); версия: $(field "$result" version)"
}
rollback() {
  local backup result
  [[ $EUID -eq 0 ]] || { fail 'Для отката нужен root.'; return 1; }
  refresh_audit; guard_astra
  backup=$(option backup)
  [[ -n "$backup" && "$backup" == "$WORK/backups/transaction."* ]] || { fail 'В этом каталоге нет сохранённой резервной копии.'; return 1; }
  say "Откат из: $backup"
  confirm "$(hostname)"
  result=$(run_worker rollback "$backup")
  printf '%s\n' "$result" >"$WORK/logs/rollback.tsv"
  say "Статус: $(field "$result" status)"
}
help_text() {
  cat <<'HELP'
Локальный скрипт: запускается на самом COD, SSH/Ansible не использует.
Без аргументов: только анализ, затем меню (если есть терминал).
  analyze / --analyze / audit / plan   только анализ, без изменений и mkdir
  report                              сохранить анализ в локальную папку
  prepare                             взять исходники рядом или скачать официальные
  source FILE.tar.gz SHA256            зарегистрировать исходники Zabbix 7.0.32
  dependency pcre2 FILE.tar.gz SHA256   зарегистрировать исходники PCRE2
  dependency openssl FILE.tar.gz SHA256 зарегистрировать исходники OpenSSL 3.x
  fetch zabbix|pcre2|openssl HTTPS_URL SHA256
                                      явное скачивание только исходного архива
  build-deps                          собрать статические библиотеки локально
  build                               собрать классический zabbix_agentd
  install / update / apply             план, подтверждение, сборка и установка
                                      apply сам выбирает install/update
  set binary /absolute/path           явный путь существующего бинарника
  set config /absolute/path           явный старый конфиг
  set service NAME.service            явная существующая служба
  status                              состояние и версия
  rollback                            откат из последней резервной копии
  help / guide                        инструкция
  quit                                выход

Все материалы сохраняются в .zabbix-source-work ТЕКУЩЕГО КАТАЛОГА ЗАПУСКА.
Запускайте скрипт каждый раз из одной папки. Для установки нужен root.
Пакеты, компиляторы и Perl НЕ устанавливаются. cc/make/Perl и libc headers
должны уже существовать. PCRE2/OpenSSL собираются из исходников в local prefix;
локальный make install зависимостей не изменяет системные /usr/lib и /usr/include.
Исходные .tar.gz перенесите через RDP/носитель. SHA-256 возьмите из доверенного
источника, а не из непроверенного скачанного файла. Скачивание по prepare/fetch.
apply после подтверждения автоматически подготавливает исходники и собирает всё.
Для offline достаточно положить рядом zabbix-7.0.32.tar.gz, pcre2-10.47.tar.gz и
openssl-3.5.9.tar.gz: prepare/apply проверят закреплённые SHA-256 без сети.
Старый конфиг сохраняется; если его нет, параметры запрашиваются при установке.
Agent 2 этим скриптом не обновляется и классическим агентом не заменяется.
Агент с дополнительными curl/LDAP/Modbus библиотеками или LoadModule требует
сборки с соответствующими опциями; его минимальная сборка не подменяет.
Windows и другие ОС не изменяются. Политики/защита Astra не отключаются.
HELP
}
guide_text() {
  cat <<'ZABBIX_LOCAL_EMBEDDED_GUIDE_20261125'
# Локальное обслуживание Zabbix на COD с Astra Linux

Этот файл запускается непосредственно на COD из терминала в RDP. SSH, jump,
инвентарь и Ansible не нужны. Он обслуживает классический `zabbix_agentd`.
Версия сборки — 7.0.32. Пакеты, готовые агенты и компиляторы не устанавливаются.

## Первый запуск: только анализ

Перенесите полный `zabbix_local.sh` на COD через RDP. В терминале перейдите
в папку, где хотите хранить все материалы, например:

```bash
cd /home/rcodaib/tmp
bash ./zabbix_local.sh
```

Скрипт сначала покажет ОС и сборку Astra, архитектуру, glibc, установленные
агенты/версии, службу, конфиг и наличие инструментов. Затем появится меню.
До явной команды служба и файлы системы не меняются. Сам анализ не создаёт
рабочую папку и не обращается к сети. Для одного отчёта без меню:

```bash
bash ./zabbix_local.sh --analyze
```

Для установки/обновления нужны права root. Если вы ещё не root, перезапустите
скрипт через имеющийся sudo из той же папки. Рабочие материалы должны создаваться
одной учётной записью: для полного процесса используйте root.

## Команды меню

```text
help
report
prepare
apply
status
rollback
quit
```

`report` сохраняет читаемый анализ. `prepare` подготавливает только исходники,
без сборки и установки. `apply` после свежего анализа показывает план, просит
ввести точное имя текущего компьютера и выполняет подготовку исходников,
сборку зависимостей, сборку агента и установку/обновление. `install` и `update`
дополнительно требуют, чтобы агент соответственно отсутствовал или существовал.
`build-deps` и `build` позволяют выполнить сборку отдельно от установки.

## Где находятся материалы

Папка `.zabbix-source-work` создаётся внутри ТЕКУЩЕГО КАТАЛОГА ЗАПУСКА,
полученного через `pwd -P`. Она не выбирается по расположению скрипта.

| Подпапка | Содержимое |
| --- | --- |
| sources | Архивы исходников, контрольные суммы, manifest |
| deps/prefix | Локально собранные PCRE2 и OpenSSL |
| builds | Распакованные исходники, журналы сборки и новый бинарник |
| tmp | Временные файлы сборки |
| logs | Результаты операций |
| reports | Сохранённый анализ |
| backups | Резервные копии бинарника и прежней конфигурации |

Всегда запускайте скрипт из одной папки: там находятся сведения о сборке и откате.
Для сборки используйте путь без пробелов и кириллицы. Системные бинарник, служба,
рабочие журналы агента и конфигурация устанавливаются по своим штатным путям.
Все новые сборочные зависимости остаются в локальной рабочей папке.

## Исходники и работа без интернета

Закреплены официальные исходники Zabbix 7.0.32, PCRE2 10.47 и OpenSSL 3.5.9.
При `prepare`/`apply` используются имеющиеся curl либо wget, HTTPS и SHA-256.
Скачивание отсутствующих инструментов не выполняется. При ошибке сети система
не обновляется. Загруженные и проверенные архивы сохраняются для следующих запусков.

Если интернета на COD нет, перенесите через RDP следующие исходные `.tar.gz`
в текущую папку запуска, сохранив имена. `prepare` проверит их по закреплённым SHA:

```text
zabbix-7.0.32.tar.gz
pcre2-10.47.tar.gz
openssl-3.5.9.tar.gz
```

Официальные адреса:

- https://cdn.zabbix.com/zabbix/sources/stable/7.0/zabbix-7.0.32.tar.gz
- https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz
- https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz

Для других одобренных исходных архивов доступны явные команды:

```text
source /absolute/path/zabbix.tar.gz EXPECTED_SHA256
dependency pcre2 /absolute/path/pcre2.tar.gz EXPECTED_SHA256
dependency openssl /absolute/path/openssl.tar.gz EXPECTED_SHA256
fetch zabbix HTTPS_URL EXPECTED_SHA256
```

`EXPECTED_SHA256` замените доверенной SHA-256, состоящей из 64 hex символов.
В меню аргументы разделяются пробелами. Пути с пробелами передавайте отдельным
запуском с кавычками; для самой рабочей папки пробелы не поддерживаются.

## Сборка и сохранение настроек

Нужны уже имеющиеся C-компилятор, make/binutils, libc headers и Perl.
При их отсутствии скрипт остановится: сборка библиотек не заменяет исходный
компилятор и базовые системные заголовки. Установка пакетов не предусмотрена.

PCRE2/OpenSSL собираются из исходников в локальный prefix. Их библиотеки
подключаются к агенту статически; системные OpenSSL/PCRE2 не заменяются.
Системные libc и обычные библиотеки ОС могут оставаться динамическими.
Глобальный `make install` для Zabbix не выполняется: заменяется проверенный
бинарник. Локальные `make install`/`install_sw` библиотек направлены в private prefix.

При обновлении используются прежние конфиг, Include, Hostname, TLS и UserParameter.
Если агента нет, но остался один старый конфиг, используется он. Для неоднозначных
путей предусмотрены `set binary`, `set config`, `set service`. Если конфига нет,
скрипт спросит Server, ServerActive и Hostname.

До замены проверяются версия, SHA-256 и новый бинарник с прежним конфигом.
Создаётся резервная копия; затем бинарник заменяется атомарно, а служба проверяется
после перезапуска. Неудачный запуск вызывает автоматический откат. Повторная
операция с тем же бинарником не перезапускает уже работающую службу.

Agent 2, несколько невыбранных служб, нестандартные wrapper-службы и обнаруженные
дополнительные libcurl/libldap/libmodbus/LoadModule требуют отдельной подготовки;
этот вариант останавливается с объяснением и не заменяет их упрощённой сборкой.
Защиты Astra, подписи и политики целостности не отключаются. Если они не допускают
новую сборку, нужна штатная процедура допуска администратора.

`rollback` восстанавливает последнюю сохранённую версию. Новая установка создаёт
служебную учётную запись zabbix, только если её ещё нет; при откате общие каталоги
и эта учётная запись могут оставаться. Существующие конфиги не перезаписываются.

После успешной операции проверьте `agent.version` и поступление данных на сервере
Zabbix: локальная проверка запуска не доказывает связь агента с сервером.

Справочные первичные источники:
https://www.zabbix.com/documentation/7.0/en/manual/installation/install
https://www.zabbix.com/documentation/7.0/en/manual/installation/install/mac_agent
https://github.com/openssl/openssl/blob/openssl-3.5.9/INSTALL.md
https://github.com/PCRE2Project/pcre2/attestations/12152412
ZABBIX_LOCAL_EMBEDDED_GUIDE_20261125
}
dispatch() {
  local command=${1-help}; [[ $# -eq 0 ]] || shift
  case "$command" in
    analyze|--analyze|audit|plan) [[ $# -eq 0 ]] || return 1; analyze ;;
    help|--help|-h) help_text ;;
    guide) guide_text ;;
    source) [[ $# -eq 2 ]] || { fail 'source FILE SHA256'; return 1; }; register_archive zabbix "$@" ;;
    dependency) [[ $# -eq 3 ]] || { fail 'dependency pcre2|openssl FILE SHA256'; return 1; }; [[ "$1" == pcre2 || "$1" == openssl ]] || return 1; register_archive "$@" ;;
    fetch) [[ $# -eq 3 ]] || { fail 'fetch zabbix|pcre2|openssl HTTPS_URL SHA256'; return 1; }; fetch_archive "$@" ;;
    prepare) [[ $# -eq 0 ]] || return 1; prepare ;;
    build-deps) [[ $# -eq 0 ]] || return 1; build_deps ;;
    build) [[ $# -eq 0 ]] || return 1; build_agent ;;
    install|update|apply) [[ $# -eq 0 ]] || return 1; deploy "$command" ;;
    status) [[ $# -eq 0 ]] || return 1; status ;;
    rollback) [[ $# -eq 0 ]] || return 1; rollback ;;
    set)
      [[ $# -eq 2 && ( "$1" == binary || "$1" == config || "$1" == service ) ]] || { fail 'set binary|config|service VALUE'; return 1; }
      if [[ "$1" == service ]]; then [[ "$2" =~ ^[A-Za-z0-9_@.-]+\.service$ && "$2" != .* ]] || return 1
      else [[ "$2" =~ ^/[A-Za-z0-9_./+:-]+$ && "$2" != *'/../'* && "$2" != */.. ]] || return 1; fi
      init_work; put_option "$1" "$2"; say 'Параметр сохранён.' ;;
    report) [[ $# -eq 0 ]] || return 1; refresh_audit; init_work; printf '%s\n' "$AUDIT" >"$WORK/reports/audit.tsv"; display_audit >"$WORK/reports/audit.txt"; say "$WORK/reports/audit.txt" ;;
    quit|exit) return 99 ;;
    *) fail "Неизвестная команда: $command. help — инструкция." ;;
  esac
}
main() {
  if [[ $# -gt 0 ]]; then dispatch "$@"; return; fi
  analyze
  [[ -t 0 && -t 1 ]] || return 0
  say 'Изменения ещё не разрешены. help — команды; apply — план и подтверждение.'
  local line status
  local -a words
  while true; do
    read_tty line 'zabbix-local> ' || break
    [[ -n "$line" ]] || continue
    read -r -a words <<<"$line"
    set +e
    (set -Eeuo pipefail; dispatch "${words[@]}")
    status=$?
    set -e
    [[ "$status" != 99 ]] || break
    [[ "$status" == 0 ]] || say "Команда не выполнена (код $status)."
  done
}
main "$@"
