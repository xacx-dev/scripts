#!/usr/bin/env bash
# Local Zabbix Agent 2 source build with APT prerequisites and a ready Go compiler.
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C
LAUNCH_DIR=$(pwd -P)
WORK="$LAUNCH_DIR/.zabbix-agent2-work"
TARGET_VERSION=7.0.32
AUDIT=''
APT_PREPARED=no

say() { printf '%s\n' "$*"; }
fail() { printf 'ОШИБКА: %s\n' "$*" >&2; return 1; }
worker_payload() {
  cat <<'ZABBIX_AGENT2_READY_WORKER_20261125'
#!/usr/bin/env bash
set +x
# Local Zabbix source build/deployment; the controller manages system prerequisites.
set -euo pipefail
umask 077
export LC_ALL=C
export GOPROXY=off GOTOOLCHAIN=local GOSUMDB=off
LOCAL_WORK_ROOT=${ZABBIX_LOCAL_WORK_ROOT:-"$PWD/.zabbix-agent2-work"}
export GOENV=off GOTELEMETRY=off GO111MODULE=on
export GOCACHE="$LOCAL_WORK_ROOT/go/cache" GOMODCACHE="$LOCAL_WORK_ROOT/go/mod" GOPATH="$LOCAL_WORK_ROOT/go/path" GOTMPDIR="$LOCAL_WORK_ROOT/tmp"

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
    emit package_installation prerequisites_via_controller
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
    local dir=${1-} source_sha=${2-} version=${3-} jobs=${4-2} variant=${5-agent2} deps=${6-} root
    require_astra
    root=$(work_root)
    safe_path "$dir" && [[ "$dir" == "$root"/builds/build.* && -d "$dir" && ! -L "$dir" && $(canonical "$dir") == "$dir" ]] || die 'Invalid private local workspace.'
    [[ $(stat -c %u -- "$dir") == "$EUID" ]] || die 'Build workspace is owned by another user.'
    [[ "$source_sha" =~ ^[A-Fa-f0-9]{64}$ ]] || die 'Invalid source SHA-256.'
    safe_version "$version" || die 'Only stable Zabbix 7.0.x is supported.'
    [[ "$jobs" =~ ^[1-9][0-9]?$ ]] || die 'Build jobs must be an integer from 1 to 99.'
    [[ "$variant" == agent2 ]] || die 'This local installer builds Zabbix Agent2 only.'
    [[ -f "$dir/source.tar.gz" && ! -L "$dir/source.tar.gz" ]] || die 'Upload source.tar.gz into the workspace first.'
    [[ $(sha256sum "$dir/source.tar.gz" | awk '{print $1}') == "${source_sha,,}" ]] || die 'Source checksum mismatch.'
    for tool in cc make tar; do command -v "$tool" >/dev/null || die "Missing build prerequisite: $tool. Run prepare to install the build prerequisites.";done
    local go_banner go_version go_dir
    command -v go >/dev/null || die 'Agent2 needs Go >= 1.25.12. Run prepare to download the local Go runtime.'
    go_banner=$(go version 2>/dev/null || true)
    [[ "$go_banner" =~ go([0-9]+\.[0-9]+\.[0-9]+) ]] || die 'The command named go is not a supported Go compiler. Run prepare to download Go.'
    go_version=${BASH_REMATCH[1]}
    [[ $(printf '%s\n' 1.25.12 "$go_version" | sort -V | head -n 1) == 1.25.12 ]] || die 'Go >= 1.25.12 is required; automatic binary-toolchain downloads are disabled.'
    for go_dir in "$root/go" "$GOCACHE" "$GOMODCACHE" "$GOPATH" "$GOTMPDIR";do
        [[ ! -L "$go_dir" ]] || die 'Go cache directories must not be symlinks.'
        mkdir -p -- "$go_dir"
    done
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
    [[ -f "$source/src/go/go.mod" && -f "$source/src/go/vendor/modules.txt" ]] || die 'Agent2 source archive must include its vendored Go source dependencies.'
    [[ -z "$deps" ]] || die 'This version builds only Zabbix and uses system OpenSSL/PCRE2; private source-built prefixes are not accepted.'
    local configure_flags=(--prefix=/usr/local --sysconfdir=/etc/zabbix --enable-ipv6 --with-libpcre2 --with-openssl --enable-agent2)
    name=zabbix_agent2
    local log="$dir/build.log"
    # No make install. Go is offline and may use only existing local modules/toolchain.
    if ! (cd "$source"; export TMPDIR="$root/tmp" GOPROXY=off GOTOOLCHAIN=local GOSUMDB=off GOFLAGS="-mod=vendor -p=$jobs -buildvcs=false" GOMAXPROCS="$jobs" GOAMD64=v1 CGO_ENABLED=1 CFLAGS='-O2' CXXFLAGS='-O2'; unset GOARCH GOOS LD_LIBRARY_PATH LIBRARY_PATH CPATH C_INCLUDE_PATH CPLUS_INCLUDE_PATH GOROOT GOROOT_BOOTSTRAP CPPFLAGS LDFLAGS LIBS PKG_CONFIG_PATH PKG_CONFIG_LIBDIR CGO_CFLAGS CGO_CPPFLAGS CGO_LDFLAGS; ./configure "${configure_flags[@]}" && make -j "$jobs") >"$log" 2>&1; then
        begin;emit build_log "$log";die 'Zabbix source compilation failed. Inspect build.log and the prerequisite installation log.'
    fi
    output="$source/src/go/bin/zabbix_agent2"
    [[ -x "$output" ]] || die 'Build completed without the expected agent binary.'
    local dynamic
    command -v ldd >/dev/null || die 'Cannot verify runtime library dependencies: ldd is required.'
    dynamic=$(ldd "$output" 2>&1 || true)
    [[ "$dynamic" != *'not found'* && "$dynamic" != *"$root"* ]] || die 'Agent has a missing runtime library or still depends on the private work directory. Inspect build.log.'
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
    emit package_installation prerequisites_via_controller
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
    local original=$1 staged=$2 attrs='' copied='' expected='' actual=''
    command -v getfattr >/dev/null && command -v setfattr >/dev/null || die 'The attr package is required to preserve binary metadata. Run prepare.'
    attrs=$(getfattr -d -m - -e base64 --absolute-names -- "$original" 2>/dev/null) || die 'Cannot inspect the existing binary extended attributes.'
    if printf '%s\n' "$attrs" | grep -Eiq '^[^#=]*(ima|evm|digsig|bsign|capability)[^=]*=';then
        die 'Existing binary carries a signature or capability attribute. Use the approved signing/capability workflow before replacement.'
    fi
    chown --reference="$original" "$staged"
    chmod --reference="$original" "$staged"
    if [[ -n "$attrs" ]];then
        printf '%s\n' "$attrs" | awk -v path="$staged" '/^# file:/ {print "# file: " path; next} {print}' | setfattr --restore=-
    fi
    copied=$(getfattr -d -m - -e base64 --absolute-names -- "$staged" 2>/dev/null) || die 'Cannot verify the staged binary extended attributes.'
    expected=$(printf '%s\n' "$attrs" | awk 'NF && $0 !~ /^#/' | sort)
    actual=$(printf '%s\n' "$copied" | awk 'NF && $0 !~ /^#/' | sort)
    [[ "$expected" == "$actual" ]] || die 'Extended attribute verification failed; the original binary remains unchanged.'
}
deployment_exit() {
    local rc=$1 rollback_rc=0
    trap - EXIT
    set +e
    if [[ -n "${TX_STAGED-}" ]];then rm -f -- "$TX_STAGED";fi
    if [[ $rc -ne 0 && -n "${TX_BACKUP-}" ]];then
        if [[ "${TX_MODE-}" == install || "${TX_MODE-}" == migrate || "${TX_BINARY_REPLACED-}" == yes ]];then
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
    if [[ "$mode" == migrate ]];then
        migrate_rollback "$backup"
    elif [[ "$mode" == update ]];then
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
    [[ "$variant" == agent2 ]] || die 'This local installer deploys Zabbix Agent2 only.'
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
RuntimeDirectory=zabbix-agent2-source
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

# Functions embedded into the Agent 2 worker; no action runs on definition.
migration_config_walk() {
    local file=$1 depth=$2 real line key value include match probe
    ((depth <= 32)) || die 'Configuration Include nesting exceeds 32 levels.'
    safe_path "$file" && [[ -f "$file" && -r "$file" && ! -L "$file" ]] || die 'An Include/config path is unreadable, unsafe, or a symlink.'
    real=$(canonical "$file")
    [[ -z ${MIG_CONFIG_STACK[$real]-} ]] || die 'A recursive configuration Include was found.'
    MIG_CONFIG_STACK[$real]=1
    printf '# Imported from %s\n' "$file" >>"$MIG_CONFIG_RAW"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=${line%$'\r'}
        if [[ "$line" =~ ^[[:space:]]*($|#) ]]; then printf '%s\n' "$line" >>"$MIG_CONFIG_RAW"; continue; fi
        [[ "$line" == *=* ]] || die 'A configuration line is not a KEY=VALUE assignment.'
        key=${line%%=*}; value=${line#*=}
        key=$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        value=$(printf '%s' "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        case "$key" in
            Include)
                probe=${value//\*/}; probe=${probe//\?/}; probe=${probe//\[/}; probe=${probe//\]/}
                safe_path "$probe" || die 'An Include pattern contains unsupported characters.'
                include=$value
                [[ ! -d "$include" ]] || include="${include%/}/*"
                while IFS= read -r match; do
                    [[ -n "$match" ]] || continue
                    migration_config_walk "$match" "$((depth+1))"
                done < <(compgen -G "$include" | sort || true)
                ;;
            StartAgents)
                [[ "$value" =~ ^[0-9]+$ ]] || die 'Invalid classic StartAgents value.'
                [[ "$value" != 0 ]] || MIG_ACTIVE_ONLY=yes
                printf '# Classic StartAgents is replaced by Agent 2 listener configuration.\n' >>"$MIG_CONFIG_RAW"
                ;;
            AllowRoot)
                [[ "$value" == 0 ]] || die 'The classic agent permits root execution. Approve an equivalent Agent 2 service identity before migration.'
                printf '# Classic AllowRoot is replaced by systemd User=zabbix.\n' >>"$MIG_CONFIG_RAW"
                ;;
            User)
                [[ "$value" == zabbix ]] || die 'The classic agent uses a custom account. Prepare an equivalent Agent 2 service identity before migration.'
                printf '# Classic User=zabbix is represented by the new systemd service.\n' >>"$MIG_CONFIG_RAW"
                ;;
            LoadModule)
                [[ -z "$value" ]] || die 'Classic LoadModule cannot be transferred to Agent 2. Rebuild or replace that module first.'
                ;;
            LoadModulePath|StartAgentsRoot|ListenBacklog)
                printf '# Classic-only %s omitted for Agent 2.\n' "$key" >>"$MIG_CONFIG_RAW"
                ;;
            PidFile|ControlSocket|PluginSocket)
                printf '# %s moved into the new Agent 2 runtime directory.\n' "$key" >>"$MIG_CONFIG_RAW"
                ;;
            MaxLinesPerSecond)
                printf 'Plugins.Log.MaxLinesPerSecond=%s\n' "$value" >>"$MIG_CONFIG_RAW"
                ;;
            LogRemoteCommands)
                printf 'Plugins.SystemRun.LogRemoteCommands=%s\n' "$value" >>"$MIG_CONFIG_RAW"
                ;;
            EnableRemoteCommands)
                [[ "$value" == 0 || "$value" == 1 ]] || die 'Invalid deprecated EnableRemoteCommands value.'
                if [[ "$value" == 1 ]];then printf 'AllowKey=system.run[*]\n' >>"$MIG_CONFIG_RAW";else printf 'DenyKey=system.run[*]\n' >>"$MIG_CONFIG_RAW";fi
                ;;
            LogType|LogFile|LogFileSize|DebugLevel|ServerActive|RefreshActiveChecks|Timeout|Hostname|HostnameItem|HostMetadata|HostMetadataItem|HostInterface|HostInterfaceItem|BufferSend|BufferSize|EnablePersistentBuffer|PersistentBufferPeriod|PersistentBufferFile|ListenIP|ListenPort|StatusPort|SourceIP|Server|UserParameter|UnsafeUserParameters|UserParameterDir|Alias|EnableProfiler|ProfilerDir|ProfilerMaxFilesPerProfile|ProfilerInterval|TLSConnect|TLSAccept|TLSPSKIdentity|TLSPSKFile|TLSCAFile|TLSCRLFile|TLSCertFile|TLSKeyFile|TLSServerCertIssuer|TLSServerCertSubject|TLSCipherCert|TLSCipherCert13|TLSCipherPSK|TLSCipherPSK13|TLSCipherAll|TLSCipherAll13|PluginTimeout|ForceActiveChecksOnStart|HeartbeatFrequency|AllowKey|DenyKey|Plugins.*)
                printf '%s\n' "$line" >>"$MIG_CONFIG_RAW"
                ;;
            *) die "Unsupported classic configuration key: $key. Prepare a compatible Agent 2 configuration before migration." ;;
        esac
    done <"$file"
    unset 'MIG_CONFIG_STACK[$real]'
}
convert_config() {
    local source=${1-} destination=${2-} root raw
    root=$(work_root)
    safe_path "$destination" && [[ "$destination" == "$root"/tmp/* && ! -L "$destination" ]] || die 'Converted configuration must be inside the private local tmp directory.'
    [[ -d "$root/tmp" && ! -L "$root/tmp" ]] || die 'Private tmp directory is missing.'
    raw=$(mktemp "$root/tmp/conversion.XXXXXXXX")
    MIG_CONFIG_RAW=$raw; MIG_ACTIVE_ONLY=no
    declare -gA MIG_CONFIG_STACK=()
    migration_config_walk "$source" 0
    if [[ "$MIG_ACTIVE_ONLY" == yes ]];then
        awk '!/^[[:space:]]*Server[[:space:]]*=/' "$raw" >"$destination"
    else cp -- "$raw" "$destination";fi
    printf '\nPidFile=/run/zabbix-agent2-source/agent.pid\nControlSocket=/run/zabbix-agent2-source/agent.sock\nPluginSocket=/run/zabbix-agent2-source/plugin.sock\n' >>"$destination"
    chmod 0600 "$destination"
    rm -f -- "$raw"
    unset MIG_CONFIG_RAW MIG_ACTIVE_ONLY MIG_CONFIG_STACK
    begin;emit converted_config "$destination"
}
migrate_rollback() {
    local backup=$1 binary config service old_binary old_service old_active old_state old_stopped unit
    binary=$(metadata_get "$backup/binary");config=$(metadata_get "$backup/config");service=$(metadata_get "$backup/service")
    old_binary=$(metadata_get "$backup/old_binary");old_service=$(metadata_get "$backup/old_service")
    old_active=$(metadata_get "$backup/old_active");old_state=$(metadata_get "$backup/old_enabled_state");old_stopped=$(metadata_get "$backup/old_stopped")
    safe_path "$binary" && safe_path "$config" && safe_path "$old_binary" && safe_service "$service" && safe_service "$old_service" || die 'Unsafe migration backup metadata.'
    [[ "$service" != "$old_service" && "$binary" != "$old_binary" ]] || die 'Migration metadata mixes old/new targets.'
    unit="/etc/systemd/system/$service"
    [[ ! -L "$unit" && ! -L "$binary" && ! -L "$config" ]] || die 'A migration target was replaced with a symlink; manual recovery is required.'
    if [[ $(metadata_get "$backup/new_unit") == yes ]];then
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        rm -f -- "$unit"
    fi
    if [[ $(metadata_get "$backup/new_binary") == yes ]];then rm -f -- "$binary";fi
    if [[ $(metadata_get "$backup/new_config") == yes ]];then rm -f -- "$config";fi
    systemctl daemon-reload
    if [[ "$old_stopped" == yes ]];then
        case "$old_state" in enabled) systemctl enable "$old_service" >/dev/null;;enabled-runtime) systemctl enable --runtime "$old_service" >/dev/null;;disabled) systemctl disable "$old_service" >/dev/null;;esac
        if [[ "$old_active" == yes ]];then
            systemctl restart "$old_service"
            verify_running "$old_service" "$old_binary" "$(metadata_get "$backup/version_before")" || die 'Classic agent rollback did not verify.'
        else systemctl stop "$old_service" || true;fi
    fi
}
migrate_agent() {
    local artifact=${1-} expected_sha=${2-} version=${3-} old_binary=${4-} old_config=${5-} old_service=${6-} binary=${7-} config=${8-} service=${9-} supplied=${10-}
    local root backup staged old_active=no old_state service_user unit runtime_dir candidate old_version old_sha old_config_sha process_comm process_name
    require_astra;require_root;root=$(work_root)
    for candidate in "$artifact" "$old_binary" "$old_config" "$binary" "$config";do safe_path "$candidate" || die 'Unsafe migration path.';done
    safe_service "$old_service" && safe_service "$service" || die 'Unsafe migration service name.'
    [[ "$old_binary" != "$binary" && "$old_config" != "$config" && "$old_service" != "$service" ]] || die 'Classic and Agent 2 paths/services must be separate.'
    [[ "$expected_sha" =~ ^[a-fA-F0-9]{64}$ ]] && safe_version "$version" || die 'Invalid source-build release/checksum.'
    [[ "$artifact" == "$root"/builds/build.*/* && -f "$artifact" && ! -L "$artifact" && $(canonical "$artifact") == "$artifact" ]] || die 'Migration artifact must be a private local source build.'
    [[ $(sha256sum -- "$artifact" | awk '{print $1}') == "${expected_sha,,}" ]] || die 'Migration artifact checksum mismatch.'
    chmod 0755 "$artifact"
    [[ $(variant_of "$artifact") == agent2 && $(version_of "$artifact") == "$version" ]] || die 'Migration artifact is not the requested Agent 2 release.'
    [[ -f "$old_binary" && ! -L "$old_binary" && -f "$old_config" && ! -L "$old_config" && $(variant_of "$old_binary") == classic ]] || die 'Migration requires an existing classic binary and configuration.'
    check_exec_config "$old_service" "$old_binary" "$old_config"
    service_user=$(unit_prop "$old_service" User)
    [[ -z "$service_user" || "$service_user" == root || "$service_user" == zabbix ]] || die 'The classic service uses a custom account. Prepare matching Agent 2 permissions before migration.'
    [[ ! -e "$binary" && ! -L "$binary" && ! -L "$config" ]] || die 'The Agent 2 destination already contains a binary or symlink.'
    [[ $(unit_prop "$service" LoadState) == not-found || -z $(unit_prop "$service" LoadState) ]] || die 'The Agent 2 target service already exists.'
    unit="/etc/systemd/system/$service"
    [[ ! -e "$unit" && ! -L "$unit" ]] || die 'The new Agent 2 unit path already exists.'
    for candidate in /usr/sbin/zabbix_agent2 /usr/local/sbin/zabbix_agent2 /usr/bin/zabbix_agent2 /usr/local/bin/zabbix_agent2;do [[ ! -x "$candidate" ]] || die 'An Agent 2 binary already exists. Audit its service instead of migrating another agent.';done
    for process_comm in /proc/[0-9]*/comm;do
        [[ -r "$process_comm" ]] || continue
        IFS= read -r process_name <"$process_comm" || true
        [[ "$process_name" != zabbix_agent2 ]] || die 'An Agent 2 process already runs. Audit it before migrating another agent.'
    done
    old_state=$(unit_prop "$old_service" UnitFileState)
    [[ -n "$old_state" ]] || old_state=$(systemctl is-enabled "$old_service" 2>/dev/null || true)
    case "$old_state" in enabled|enabled-runtime|disabled|static|indirect|generated) :;;*) die 'Cannot safely preserve the classic service enablement state.';;esac
    systemctl is-active --quiet "$old_service" && old_active=yes || true
    old_version=$(version_of "$old_binary")
    [[ $(printf '%s\n' "$old_version" "$version" | sort -V | tail -n 1) == "$version" ]] || die 'Migration to an older Zabbix release is not supported.'
    old_sha=$(sha256sum -- "$old_binary" | awk '{print $1}');old_config_sha=$(sha256sum -- "$old_config" | awk '{print $1}')
    backup=$(backup_root)
    metadata_set "$backup/mode" migrate;metadata_set "$backup/binary" "$binary";metadata_set "$backup/config" "$config";metadata_set "$backup/service" "$service"
    metadata_set "$backup/old_binary" "$old_binary";metadata_set "$backup/old_config" "$old_config";metadata_set "$backup/old_service" "$old_service"
    metadata_set "$backup/old_active" "$old_active";metadata_set "$backup/old_enabled_state" "$old_state";metadata_set "$backup/old_stopped" no;metadata_set "$backup/version_before" "$old_version"
    metadata_set "$backup/new_binary" no;metadata_set "$backup/new_config" no;metadata_set "$backup/new_unit" no
    snapshot_configs "$backup" "$old_config"
    [[ ! -f "$config" ]] || cp -a -- "$config" "$backup/config.target.previous"
    TX_MODE=migrate;TX_BACKUP=$backup;TX_BINARY_REPLACED=no;TX_STAGED=''
    trap 'deployment_exit "$?"' EXIT
    begin;emit backup "$backup"
    if [[ ! -f "$config" ]];then
        if [[ -z "$supplied" ]];then
            supplied=$(mktemp "$root/tmp/agent2-converted.XXXXXXXX")
            convert_config "$old_config" "$supplied" >/dev/null
        else safe_path "$supplied" && [[ "$supplied" == "$root"/tmp/* && -f "$supplied" && ! -L "$supplied" ]] || die 'Invalid prepared Agent 2 configuration.';fi
    fi
    getent group zabbix >/dev/null || groupadd --system zabbix
    if ! getent passwd zabbix >/dev/null;then
        local nologin=/usr/sbin/nologin
        [[ -x "$nologin" ]] || nologin=/sbin/nologin
        useradd --system --gid zabbix --home-dir /var/lib/zabbix --no-create-home --shell "$nologin" zabbix
    fi
    mkdir -p -- "$(dirname "$binary")" "$(dirname "$config")"
    if [[ ! -f "$config" ]];then metadata_set "$backup/new_config" yes;install -m 0640 -o root -g zabbix -- "$supplied" "$config";fi
    for runtime_dir in /var/log/zabbix /var/lib/zabbix;do
        [[ ! -L "$runtime_dir" ]] || die 'A log/state directory is a symlink.'
        [[ -d "$runtime_dir" ]] || install -d -m 0750 -o zabbix -g zabbix "$runtime_dir"
    done
    staged=$(mktemp "$(dirname "$binary")/.zabbix-agent2-new.XXXXXXXX");TX_STAGED=$staged
    cp -- "$artifact" "$staged";chmod 0755 "$staged"
    [[ $(sha256sum -- "$staged" | awk '{print $1}') == "${expected_sha,,}" ]] || die 'Staged Agent 2 checksum mismatch.'
    check_staged "$staged" "$config" "$version" agent2 "$backup/validation.log"
    [[ $(sha256sum -- "$old_binary" | awk '{print $1}') == "$old_sha" && $(sha256sum -- "$old_config" | awk '{print $1}') == "$old_config_sha" ]] || die 'Classic binary/config changed during validation.'
    metadata_set "$backup/new_binary" yes
    mv -fT -- "$staged" "$binary";TX_STAGED='';TX_BINARY_REPLACED=yes
    metadata_set "$backup/new_unit" yes
    cat >"$unit" <<UNIT
[Unit]
Description=Zabbix Agent 2 built from approved source
After=network.target

[Service]
Type=simple
User=zabbix
Group=zabbix
RuntimeDirectory=zabbix-agent2-source
RuntimeDirectoryMode=0755
ExecStart=$binary -c $config
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    chmod 0644 "$unit"
    systemctl daemon-reload
    metadata_set "$backup/old_stopped" yes
    systemctl stop "$old_service"
    systemctl disable "$old_service" >/dev/null
    systemctl enable "$service" >/dev/null
    systemctl start "$service"
    verify_running "$service" "$binary" "$version" || die 'New Agent 2 did not become healthy.'
    check_staged "$binary" "$config" "$version" agent2 "$backup/validation.log"
    trap - EXIT
    metadata_set "$backup/completed" yes
    begin;emit status migrated;emit backup "$backup";emit version "$version";emit variant agent2;emit binary "$binary";emit config "$config";emit service "$service"
}

action=${1-audit}
if [[ $# -gt 0 ]];then shift;fi
case "$action" in
    audit) audit ;;
    workspace) workspace ;;
    build) build_agent "$@" ;;
    deploy) deploy_agent "$@" ;;
    migrate) migrate_agent "$@" ;;
    convert-config) convert_config "$@" ;;
    rollback) do_rollback "$@" ;;
    status) status_agent "$@" ;;
    *) begin;die 'Unknown remote action.' ;;
esac
ZABBIX_AGENT2_READY_WORKER_20261125
}
run_worker() { worker_payload | ZABBIX_LOCAL_WORK_ROOT="$WORK" bash -s -- "$@"; }
go_builder_payload() {
  cat <<'ZABBIX_AGENT2_READY_GO_20261125'
#!/usr/bin/env bash
# Obtain the official ready-made Go toolchain inside the local work tree.
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C
WORK=${ZABBIX_LOCAL_WORK_ROOT-}
MIN_GO=1.25.12

emit() { printf '%s\t' "$1"; printf '%s' "${2-}" | base64 | tr -d '\n'; printf '\n'; }
begin() { printf 'ZA_AUDIT_V1\n'; }
die() { begin; emit error "$*"; printf 'Go: %s\n' "$*" >&2; exit 1; }
progress() { printf 'Go: %s\n' "$*" >&2; }
safe_path() { [[ $1 =~ ^/[A-Za-z0-9_./+:-]+$ && $1 != / && $1 != *'/../'* && $1 != */.. ]]; }
version_ge() { [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n 1) == "$2" ]]; }
go_version() {
  local line
  line=$("$1" version 2>/dev/null) || return 1
  [[ $line =~ ^go[[:space:]]version[[:space:]]go([0-9]+\.[0-9]+(\.[0-9]+)?)([[:space:]-]|$) ]] || return 1
  printf '%s' "${BASH_REMATCH[1]}"
}
validate_work() {
  safe_path "$WORK" && [[ -d $WORK && ! -L $WORK ]] || die 'Некорректный локальный рабочий каталог.'
  [[ $(readlink -f -- "$WORK") == "$WORK" && $(stat -c %u -- "$WORK") == "$EUID" && $(stat -c %a -- "$WORK") == 700 ]] || die 'Рабочий каталог должен принадлежать текущей учётной записи и иметь права 0700.'
  local sub
  for sub in downloads toolchains logs tmp go go/cache go/mod go/path;do
    [[ ! -L $WORK/$sub ]] || die "Символическая ссылка вместо рабочего каталога $sub."
    mkdir -p -- "$WORK/$sub"; chmod 700 "$WORK/$sub"
    [[ $(stat -c %u -- "$WORK/$sub") == "$EUID" ]] || die "Каталог $sub принадлежит другому пользователю."
  done
  export GOENV=off GOTOOLCHAIN=local GOTELEMETRY=off GOPROXY=off GOSUMDB=off
  export GOCACHE="$WORK/go/cache" GOMODCACHE="$WORK/go/mod" GOPATH="$WORK/go/path" GOTMPDIR="$WORK/tmp" TMPDIR="$WORK/tmp"
  unset GOROOT GOROOT_BOOTSTRAP GOBIN GOOS GOARCH GOFLAGS GOEXPERIMENT GO_GCFLAGS GO_LDFLAGS
}
select_archive() {
  [[ $(uname -s) == Linux ]] || die 'Готовый Go в этом скрипте рассчитан на Linux.'
  case $(uname -m) in
    x86_64|amd64) GO_ARCH=amd64; GO_SHA=234828b7a89e0e303d2556310ee549fbcf253d28de937bac3da13d6294262ac1;;
    aarch64|arm64) GO_ARCH=arm64; GO_SHA=8b5884aef89600aef5b0b051fb971f11f49bb996521e911f30f02a66884f7bd2;;
    i?86) GO_ARCH=386; GO_SHA=b71e88ae779850dc2afcd0f2e2208798652311dfda72fdef5d05721d601b8fd3;;
    *) die 'Для этой архитектуры нет закреплённого готового Go. Требуется совместимый существующий Go >= 1.25.12.';;
  esac
  GO_FILENAME="go$MIN_GO.linux-$GO_ARCH.tar.gz"
}
find_existing() {
  local path version best='' best_version=''
  while IFS= read -r path;do
    [[ $path == /* && -x $path && -f $path ]] || continue
    version=$(go_version "$path") || continue
    version_ge "$version" "$MIN_GO" || continue
    if [[ -z $best || $(printf '%s\n%s\n' "$best_version" "$version" | sort -V | tail -n 1) == "$version" ]];then best=$path;best_version=$version;fi
  done < <(type -a -P go 2>/dev/null | awk '!seen[$0]++' || true)
  [[ -z $best ]] || printf '%s' "$best"
}
download_archive() {
  local archive="$WORK/downloads/$GO_FILENAME" nearby="$(dirname -- "$WORK")/$GO_FILENAME" temp
  if [[ -e $archive || -L $archive ]];then
    [[ -f $archive && ! -L $archive && $(sha256sum -- "$archive" | awk '{print $1}') == "$GO_SHA" ]] || die "Повреждён локальный архив $GO_FILENAME."
    printf '%s' "$archive";return
  fi
  if [[ -e $nearby || -L $nearby ]];then
    [[ -f $nearby && ! -L $nearby && $(sha256sum -- "$nearby" | awk '{print $1}') == "$GO_SHA" ]] || die "SHA-256 перенесённого архива $GO_FILENAME не совпадает."
    cp -- "$nearby" "$archive";chmod 400 "$archive"
    printf '%s' "$archive";return
  fi
  temp=$(mktemp "$WORK/downloads/go-download.XXXXXXXX")
  progress "Скачивание готового Go $MIN_GO ($GO_ARCH) в $WORK/downloads"
  if command -v curl >/dev/null;then
    if ! curl --disable --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 900 --retry 1 --output "$temp" -- "https://dl.google.com/go/$GO_FILENAME";then
      rm -f -- "$temp";die "Не удалось скачать $GO_FILENAME. Можно перенести этот официальный архив через RDP в каталог запуска."
    fi
  elif command -v wget >/dev/null;then
    if ! wget --https-only --timeout=15 --tries=2 --output-document="$temp" -- "https://dl.google.com/go/$GO_FILENAME";then rm -f -- "$temp";die "Не удалось скачать $GO_FILENAME.";fi
  else rm -f -- "$temp";die "Нет curl/wget. Выполните подготовку пакетов либо перенесите $GO_FILENAME через RDP.";fi
  [[ $(sha256sum -- "$temp" | awk '{print $1}') == "$GO_SHA" ]] || { rm -f -- "$temp";die "SHA-256 $GO_FILENAME не совпадает."; }
  chmod 400 "$temp";mv -- "$temp" "$archive"
  printf '%s' "$archive"
}
proof_text() {
  local dir=$1
  printf '%s\n' "$GO_FILENAME" "$GO_SHA" "$(uname -s)" "$(uname -m)" "$dir" "$(sha256sum -- "$dir/go/bin/go" | awk '{print $1}')"
}
cached_binary() {
  local dir=$1 reported
  [[ -d $dir && ! -L $dir && $(readlink -f -- "$dir") == "$dir" && -r $dir/.prebuilt-proof && ! -L $dir/.prebuilt-proof && -x $dir/go/bin/go && ! -L $dir/go/bin/go ]] || return 1
  [[ $(readlink -f -- "$dir/go/bin/go") == "$dir/go/bin/go" && -x $dir/go/pkg/tool/linux_$GO_ARCH/compile && -x $dir/go/pkg/tool/linux_$GO_ARCH/link ]] || return 1
  [[ $(cat -- "$dir/.prebuilt-proof") == "$(proof_text "$dir")" ]] || return 1
  reported=$(go_version "$dir/go/bin/go") || return 1
  [[ $reported == "$MIN_GO" ]] || return 1
  printf '%s' "$dir/go/bin/go"
}
unpack_archive() {
  local archive=$1 dir=$2 temp previous reported
  tar -tzf "$archive" | awk '/^\// {bad=1} /(^|\/)\.\.($|\/)/ {bad=1} END {exit bad}' || die 'Опасный путь в архиве готового Go.'
  if tar -tvzf "$archive" | awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {bad=1} END{exit !bad}';then die 'Ссылки и специальные файлы в архиве Go не разрешены.';fi
  [[ ! -L $dir ]] || die 'Каталог готового Go не должен быть символической ссылкой.'
  temp=$(mktemp -d "$WORK/toolchains/go-unpack.XXXXXXXX")
  tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$temp"
  [[ -x $temp/go/bin/go && -f $temp/go/bin/go && ! -L $temp/go/bin/go ]] || die 'Архив Go не содержит исполняемый go/bin/go.'
  reported=$(go_version "$temp/go/bin/go") || die 'Готовый Go не запускается: проверьте архитектуру и разрешение выполнения в каталоге.'
  [[ $reported == "$MIN_GO" ]] || die "В архиве Go $reported вместо $MIN_GO."
  if [[ -e $dir ]];then
    previous=$(mktemp -d "$WORK/toolchains/previous-go.XXXXXXXX")
    mv -- "$dir" "$previous/toolchain"
  fi
  mv -- "$temp" "$dir"
  proof_text "$dir" >"$dir/.prebuilt-proof"
  chmod 600 "$dir/.prebuilt-proof"
  printf '%s' "$dir/go/bin/go"
}
run() {
  local action=${1-} candidate archive dir
  [[ $action == prepare || $action == ensure ]] || die 'Внутренние команды готового Go: prepare либо ensure. Без команды установка не запускается.'
  validate_work
  candidate=$(find_existing)
  if [[ -n $candidate ]];then begin;emit go_binary "$candidate";emit go_version "$(go_version "$candidate")";emit go_origin existing;return;fi
  select_archive
  dir="$WORK/toolchains/prebuilt-go$MIN_GO-$GO_ARCH"
  candidate=$(cached_binary "$dir") || candidate=''
  if [[ -n $candidate ]];then begin;emit go_binary "$candidate";emit go_version "$MIN_GO";emit go_origin official-prebuilt;return;fi
  archive=$(set -Eeuo pipefail;download_archive)
  if [[ $action == prepare ]];then begin;emit status prepared;emit go_archive "$archive";emit go_target "$MIN_GO";return;fi
  progress "Распаковка готового Go $MIN_GO; компиляция Go не выполняется."
  candidate=$(set -Eeuo pipefail;unpack_archive "$archive" "$dir")
  begin;emit go_binary "$candidate";emit go_version "$MIN_GO";emit go_origin official-prebuilt
}
run "$@"
ZABBIX_AGENT2_READY_GO_20261125
}
run_go_builder() { go_builder_payload | ZABBIX_LOCAL_WORK_ROOT="$WORK" bash -s -- "$@"; }
configure_go_environment() {
  export GOCACHE="$WORK/go/build-cache" GOMODCACHE="$WORK/go/module-cache" GOPATH="$WORK/go/path" GOTMPDIR="$WORK/tmp"
  export GOTOOLCHAIN=local GOENV=off GOTELEMETRY=off CGO_ENABLED=1 GOPROXY=off GOSUMDB=off
  mkdir -p -- "$GOCACHE" "$GOMODCACHE" "$GOPATH"
}
ensure_go() {
  local result go_binary
  init_work
  configure_go_environment
  result=$(run_go_builder ensure)
  [[ "$result" == ZA_AUDIT_V1$'\n'* ]] || { fail 'Не получен корректный результат подготовки готового Go.'; return 1; }
  go_binary=$(field "$result" go_binary)
  [[ "$go_binary" == /* && -x "$go_binary" && "$go_binary" != *$'\n'* ]] || { fail 'Не найден готовый или подходящий существующий Go.'; return 1; }
  export PATH="$(dirname -- "$go_binary"):$PATH"
  printf '%s\n' "$result" >"$WORK/logs/go-toolchain.tsv"
  say "Go для сборки Agent 2: $go_binary"
}
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
  for dir in sources builds deps logs backups reports tmp go toolchains; do
    [[ ! -L "$WORK/$dir" ]] || { fail "Символическая ссылка в рабочем каталоге: $dir"; return 1; }
    mkdir -p -- "$WORK/$dir"; chmod 700 "$WORK/$dir"
  done
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
  say "Целевая версия: $TARGET_VERSION; APT-пакеты и готовый Go устанавливаются только по командам prepare/build/apply."
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
guard_agent2() {
  local variant
  variant=$(field "$AUDIT" variant)
  [[ -z "$variant" || "$variant" == agent2 || "$variant" == classic ]] || { fail 'Неизвестный тип установленного агента. Изменения заблокированы.'; return 1; }
}

register_archive() {
  local name=$1 archive=$2 expected=$3 actual destination
  [[ "$name" == zabbix ]] || { fail 'Из исходников собирается только Zabbix.'; return 1; }
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
  [[ "$name" == zabbix ]] || { fail 'fetch zabbix HTTPS_URL SHA256.'; return 1; }
  [[ "$url" == https://* && "$url" != *$'\n'* && "$url" != *$'\r'* && "$sha" =~ ^[A-Fa-f0-9]{64}$ ]] || { fail 'fetch требует HTTPS URL и заранее проверенную SHA-256.'; return 1; }
  init_work
  temp=$(mktemp "$WORK/sources/download.XXXXXXXX.tar.gz")
  if command -v curl >/dev/null; then
    if ! curl --disable --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 15 --max-time 900 --retry 1 --output "$temp" -- "$url"; then rm -f -- "$temp"; offline_instructions; fail 'Скачивание не удалось.'; return 1; fi
  elif command -v wget >/dev/null; then
    if ! wget --https-only --timeout=15 --tries=2 --output-document="$temp" -- "$url"; then rm -f -- "$temp"; offline_instructions; fail 'Скачивание не удалось.'; return 1; fi
  else rm -f -- "$temp"; offline_instructions; fail 'Нет curl/wget. Выполните prepare для установки инструментов.'; return 1; fi
  register_archive "$name" "$temp" "$sha"
  rm -f -- "$temp"
}
offline_instructions() {
  printf '%s\n' 'Если сеть недоступна, перенесите через RDP официальный zabbix-7.0.32.tar.gz и архив готового Go в текущий каталог запуска.' "Каталог: $LAUNCH_DIR" 'Для первоначальной подготовки нужны штатные APT-репозитории Astra либо уже установленные пакеты.' >&2
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
  prepare_packages
  local name=zabbix version=7.0.32 url=https://cdn.zabbix.com/zabbix/sources/stable/7.0/zabbix-7.0.32.tar.gz
  local sha=ead5b0723ad965eb0e79f98d5d2b89088e7c898ae194eeba767e5d1fb2d50a96
  local checksum_file actual current current_sha nearby only_missing=${1-no}
  printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$url" "$sha" >"$WORK/sources/official-sources.tsv"
  current=$(option zabbix_archive); current_sha=$(option zabbix_sha)
  if [[ -f "$current" && ! -L "$current" && "$current" == "$WORK/sources/"* && "$current_sha" =~ ^[a-f0-9]{64}$ && $(sha256sum -- "$current" | awk '{print $1}') == "$current_sha" && ( "$only_missing" == yes || "$current_sha" == "$sha" ) ]];then
    say 'Zabbix: проверенные исходники уже есть.'
  else
    nearby="$LAUNCH_DIR/${url##*/}"
    if [[ -e "$nearby" ]];then
      [[ -f "$nearby" && ! -L "$nearby" && $(sha256sum -- "$nearby" | awk '{print $1}') == "$sha" ]] || { fail "Архив $nearby не совпадает с доверенной SHA-256 или является ссылкой."; return 1; }
      register_archive zabbix "$nearby" "$sha"
      printf '%s\n' "$sha" >"$WORK/sources/zabbix-$version.tar.gz.sha256"
      say 'Zabbix: использован локальный архив.'
    else
      checksum_file="$WORK/sources/zabbix-$version.tar.gz.sha256"
      download_metadata "$url.sha256" "$checksum_file"
      actual=$(grep -oE '[a-fA-F0-9]{64}' "$checksum_file" || true)
      [[ "$actual" == "$sha" ]] || { fail 'Официальная SHA-256 Zabbix отличается от закреплённой; проверьте выпуск вручную.'; return 1; }
      fetch_archive zabbix "$url" "$sha"
    fi
  fi
  local go_result
  go_result=$(run_go_builder prepare)
  [[ "$go_result" == ZA_AUDIT_V1$'\n'* ]] || { fail 'Не получен результат загрузки готового Go.'; return 1; }
  printf '%s\n' "$go_result" >"$WORK/logs/go-prepare.tsv"
  say 'APT-зависимости, исходники Zabbix и готовый Go подготовлены. build — сборка; apply — установка/обновление.'
}
archives_ready() {
  local archive sha
  archive=$(option zabbix_archive);sha=$(option zabbix_sha)
  [[ -f "$archive" && ! -L "$archive" && "$archive" == "$WORK/sources/"* && "$sha" =~ ^[a-f0-9]{64}$ && $(sha256sum -- "$archive" | awk '{print $1}') == "$sha" ]]
}
checked_archive() {
  local name=$1 archive sha
  [[ "$name" == zabbix ]] || { fail 'Поддерживаются только исходники Zabbix.';return 1; }
  archive=$(option zabbix_archive);sha=$(option zabbix_sha)
  [[ -f "$archive" && ! -L "$archive" && "$archive" == "$WORK/sources/"* && "$sha" =~ ^[a-f0-9]{64}$ ]] || { fail 'Нет исходников Zabbix. Выполните prepare либо source FILE SHA256.';return 1; }
  [[ $(sha256sum -- "$archive" | awk '{print $1}') == "$sha" ]] || { fail 'Изменилась SHA-256 зарегистрированного архива Zabbix.';return 1; }
  printf '%s' "$archive"
}
check_toolchain() {
  local tool module probe_dir probe_log
  for tool in cc make tar sha256sum ar ranlib ld perl pkg-config ldd getfattr setfattr;do
    command -v "$tool" >/dev/null || { fail "После подготовки не найден $tool. Проверьте установку пакетов и PATH.";return 1; }
  done
  for module in openssl libpcre2-8 zlib;do
    pkg-config --exists "$module" || { fail "Не найден модуль $module для сборки. Проверьте libssl-dev, libpcre2-dev и zlib1g-dev.";return 1; }
  done
  probe_dir=$(mktemp -d "$WORK/tmp/link-check.XXXXXXXX") || return 1
  probe_log="$WORK/logs/link-prerequisites.log"
  cat >"$probe_dir/check.c" <<'LINK_PREREQUISITES_C'
#define PCRE2_CODE_UNIT_WIDTH 8
#include <openssl/ssl.h>
#include <pcre2.h>
#include <zlib.h>
int main(void) {
    unsigned char version[128];
    SSL_CTX *ctx = SSL_CTX_new(SSLv23_method());
    int rc = pcre2_config(PCRE2_CONFIG_VERSION, version);
    const char *zv = zlibVersion();
    SSL_CTX_free(ctx);
    return rc < 0 || zv == 0;
}
LINK_PREREQUISITES_C
  if ! TMPDIR="$probe_dir" cc "$probe_dir/check.c" -o "$probe_dir/check" -lssl -lcrypto -lpcre2-8 -lz >"$probe_log" 2>&1;then
    rm -rf -- "$probe_dir"
    fail "Проверка компилятора/линковщика не пройдена: нужны libc6-dev, libssl-dev, libpcre2-dev и zlib1g-dev. Журнал: $probe_log";return 1
  fi
  rm -rf -- "$probe_dir"
}
prepare_packages() {
  [[ "$APT_PREPARED" != yes ]] || return 0
  [[ $EUID -eq 0 ]] || { fail 'Для подготовки APT-зависимостей запустите скрипт от root в этом же каталоге.';return 1; }
  refresh_audit;guard_astra;guard_agent2
  command -v apt-get >/dev/null || { fail 'На этой Astra не найден apt-get.';return 1; }
  init_work
  local packages=(gcc make libc6-dev binutils perl pkg-config curl ca-certificates libssl-dev libpcre2-dev zlib1g-dev attr)
  [[ ! -L "$WORK/apt" && ! -L "$WORK/apt/archives" && ! -L "$WORK/apt/archives/partial" ]] || { fail 'Символическая ссылка в локальном APT-кеше.';return 1; }
  mkdir -p -- "$WORK/apt/archives/partial"
  chmod 700 "$WORK/apt" "$WORK/apt/archives" "$WORK/apt/archives/partial"
  say 'Предустановка инструментов и системных библиотек из уже настроенных репозиториев Astra:'
  printf '  %s\n' "${packages[*]}"
  say 'libssl-dev/libpcre2-dev/zlib1g-dev нужны для линковки Agent2; attr сохраняет атрибуты прежнего бинарника. Дополнительные программы не устанавливаются из исходников.'
  if ! apt-get update 2>&1 | tee "$WORK/logs/apt-update.log";then
    fail "APT update завершился ошибкой. Служба Zabbix не изменялась. Журнал: $WORK/logs/apt-update.log";return 1
  fi
  if ! DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-remove --no-install-recommends -o "Dir::Cache::archives=$WORK/apt/archives" -o APT::Keep-Downloaded-Packages=true -o APT::Sandbox::User=root "${packages[@]}" 2>&1 | tee "$WORK/logs/apt-install.log";then
    fail "Предустановка пакетов завершилась ошибкой. Сборка/замена агента не выполнялась. Журнал: $WORK/logs/apt-install.log";return 1
  fi
  check_toolchain
  APT_PREPARED=yes
  refresh_audit
}
build_agent() {
  local archive sha dir result artifact digest
  refresh_audit;guard_astra;guard_agent2
  prepare_packages
  if ! archives_ready;then prepare yes;fi
  archive=$(checked_archive zabbix);sha=$(option zabbix_sha)
  ensure_go
  result=$(run_worker workspace)
  dir=$(field "$result" workspace)
  [[ "$dir" == "$WORK/builds/build."* && -d "$dir" && ! -L "$dir" ]] || { fail 'Некорректный каталог сборки worker.';return 1; }
  cp -- "$archive" "$dir/source.tar.gz"
  say "Сборка только Zabbix Agent2 $TARGET_VERSION. Журнал: $dir/build.log"
  if ! result=$(run_worker build "$dir" "$sha" "$TARGET_VERSION" 2 agent2 '');then
    printf '%s\n' "$result" >"$WORK/logs/build-failed.tsv"
    fail "Сборка остановлена. $(field "$result" error) Журнал: $dir/build.log";return 1
  fi
  artifact=$(field "$result" artifact);digest=$(field "$result" sha256)
  [[ "$artifact" == "$dir/artifact/"* && -f "$artifact" && "$digest" =~ ^[a-f0-9]{64}$ ]] || { fail 'Не получен проверенный результат сборки.';return 1; }
  [[ $(sha256sum -- "$artifact" | awk '{print $1}') == "$digest" ]] || { fail 'SHA-256 результата сборки не совпадает.';return 1; }
  printf '%s\n' "$result" >"$WORK/logs/build.tsv"
  printf '%s\n' "$AUDIT" >"$WORK/logs/build-audit.tsv"
  put_option artifact "$artifact";put_option artifact_sha "$digest";put_option built_source_sha "$sha"
  put_option built_mode system-libs-v1
  say "Собранный Agent2: $artifact. Установка/замена агента ещё не выполнялась."
}
artifact_ready() {
  local artifact digest previous key actual
  [[ $(option built_mode) == system-libs-v1 ]] || return 1
  artifact=$(option artifact);digest=$(option artifact_sha)
  [[ -f "$artifact" && ! -L "$artifact" && "$artifact" == "$WORK/builds/"* && "$digest" =~ ^[a-f0-9]{64}$ ]] || return 1
  [[ $(sha256sum -- "$artifact" | awk '{print $1}') == "$digest" ]] || return 1
  [[ $(option built_source_sha) == "$(option zabbix_sha)" && -f "$WORK/logs/build-audit.tsv" ]] || return 1
  previous=$(cat -- "$WORK/logs/build-audit.tsv")
  for key in os_id os_version astra_version architecture glibc library_fingerprint;do
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
    printf 'LogFile=/var/log/zabbix/zabbix_agent2_source.log\nPidFile=/run/zabbix-agent2-source/agent.pid\nControlSocket=/run/zabbix-agent2-source/agent.sock\nPluginSocket=/run/zabbix-agent2-source/agent.plugin.sock\nHostname=%s\n' "$hostname"
    if [[ -n "$server" ]]; then printf 'Server=%s\n' "$server"; fi
    [[ -z "$active" ]] || printf 'ServerActive=%s\n' "$active"
  } >"$destination"
}
deploy() {
  local request=$1 binary config service mode orphan answer supplied='' result backup item variant old_binary='' old_config='' old_service='' orphan_classic=''
  [[ $EUID -eq 0 ]] || { fail 'Для установки/обновления запустите скрипт от root в этом же каталоге.'; return 1; }
  refresh_audit; guard_astra; guard_agent2
  if [[ $(field "$AUDIT" ambiguous) == yes ]]; then
    for item in binary config service; do [[ -n $(option "$item") ]] || { fail 'Обнаружены неоднозначные агенты/службы. Задайте set binary/config/service перед изменениями.'; return 1; }; done
  fi
  binary=$(selected binary); config=$(selected config); service=$(selected service)
  variant=$(field "$AUDIT" variant)
  if [[ -n "$binary" && "$binary" != none && "$variant" != classic && "$variant" != agent2 ]]; then
    local version_text
    [[ -x "$binary" ]] || { fail 'Выбранный бинарник агента не найден.'; return 1; }
    version_text=$("$binary" -V 2>/dev/null) || { fail 'Не удалось определить тип выбранного агента.'; return 1; }
    version_text=${version_text,,}
    if [[ "$version_text" == *zabbix_agent2* || "$version_text" == *'agent 2'* ]]; then variant=agent2
    elif [[ "$version_text" == *zabbix_agentd* || "$version_text" == *'agent (daemon)'* ]]; then variant=classic
    else fail 'Неизвестный тип выбранного бинарника; установка заблокирована.'; return 1; fi
  fi
  if [[ -n "$binary" && "$binary" != none ]]; then
    if [[ "$variant" == classic ]]; then mode=migrate; else mode=update; fi
  else mode=install; fi
  [[ "$request" == apply || "$request" == "$mode" || ( "$request" == update && "$mode" == migrate ) ]] || { fail "По результату анализа нужна команда $([[ "$mode" == migrate ]] && printf 'update (миграция Agent 2)' || printf '%s' "$mode")."; return 1; }
  if [[ "$mode" == migrate && $(field "$AUDIT" extra_features) == *LoadModule* ]]; then
    fail 'В конфиге классического агента найден LoadModule. Agent 2 не загружает классические .so-модули; перед миграцией требуется настроить эквивалентный Agent 2 plugin.'; return 1
  fi
  if [[ "$mode" == migrate ]]; then
    [[ -n "$binary" && -n "$config" && -n "$service" ]] || { fail 'Для миграции classic→Agent 2 нужны однозначные старые binary/config/service.'; return 1; }
    old_binary=$binary; old_config=$config; old_service=$service
    binary=/usr/local/sbin/zabbix_agent2; config=/etc/zabbix/zabbix_agent2.conf; service=zabbix-agent2-source.service
    printf '\nМиграция классического агента: %s, %s, %s\n' "$old_binary" "$old_config" "$old_service"
  fi
  if [[ "$mode" == install ]]; then
    binary=${binary:-/usr/local/sbin/zabbix_agent2}
    if [[ -z "$config" ]]; then
      orphan=$(field "$AUDIT" orphan_config)
      if [[ -n "$orphan" ]]; then config=$orphan
      elif [[ -n $(field "$AUDIT" orphan_configs) ]]; then fail 'Найдено несколько старых конфигов. Укажите нужный: set config /absolute/path'; return 1
      else config=/etc/zabbix/zabbix_agent2.conf; fi
    fi
    service=${service:-zabbix-agent2-source.service}
    if [[ "$config" == */zabbix_agentd.conf && -f "$config" ]]; then
      orphan_classic=$config
      config=/etc/zabbix/zabbix_agent2.conf
      [[ ! -e "$config" ]] || { fail 'Уже есть Agent 2 config. Выберите его явно: set config /etc/zabbix/zabbix_agent2.conf'; return 1; }
    fi
  fi
  [[ -n "$binary" && -n "$config" && -n "$service" ]] || { fail 'Не определены binary/config/service. Задайте их командами set.'; return 1; }
  printf '\nПлан: %s Zabbix Agent 2 %s на %s\nБинарник: %s\nКонфиг: %s\nСлужба: %s\n' "$mode" "$TARGET_VERSION" "$(hostname)" "$binary" "$config" "$service"
  say "Перед сборкой будут установлены APT-зависимости; готовый Go и исходники останутся в $WORK."
  if [[ -f "$config" ]]; then say 'Существующий конфиг будет сохранён и использован без перезаписи.'; fi
  confirm "$(hostname)"
  # The user command and hostname confirmation authorize APT prerequisites and deployment.
  prepare_packages
  if ! artifact_ready; then
    if ! archives_ready; then prepare yes; fi
    build_agent
  fi
  if [[ "$mode" == install && ! -f "$config" ]]; then
    supplied=$(mktemp "$WORK/tmp/new-config.XXXXXXXX")
    if [[ -n "$orphan_classic" ]]; then
      run_worker convert-config "$orphan_classic" "$supplied" >"$WORK/logs/config-conversion.tsv"
    else new_config "$supplied"; fi
  fi
  result=''
  local action=(deploy "$mode" "$(option artifact)" "$(option artifact_sha)" "$TARGET_VERSION" "$binary" "$config" "$service" "$supplied")
  if [[ "$mode" == migrate ]]; then action=(migrate "$(option artifact)" "$(option artifact_sha)" "$TARGET_VERSION" "$old_binary" "$old_config" "$old_service" "$binary" "$config" "$service" "$supplied"); fi
  if result=$(run_worker "${action[@]}"); then
    printf '%s\n' "$result" >"$WORK/logs/deploy.tsv"
    backup=$(field "$result" backup)
    [[ -z "$backup" ]] || put_option backup "$backup"
    if [[ "$mode" == migrate ]];then
      put_option binary "$binary";put_option config "$config";put_option service "$service"
    fi
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
  if [[ -r "$backup/mode" && $(base64 -d "$backup/mode") == migrate ]];then
    put_option binary "$(base64 -d "$backup/old_binary")"
    put_option config "$(base64 -d "$backup/old_config")"
    put_option service "$(base64 -d "$backup/old_service")"
  fi
  say "Статус: $(field "$result" status)"
}
help_text() {
  cat <<'HELP'
Локальный Agent2: запуск на самом COD через RDP, без SSH/Ansible.
Без аргументов: только анализ, затем меню. Анализ не ставит пакеты и не меняет службу.
  analyze / --analyze / audit / plan   только анализ
  report                              сохранить анализ
  prepare                             APT-зависимости, исходники Zabbix и готовый Go
  build                               подготовить окружение и собрать только Agent2
  install / update / apply             план, подтверждение, подготовка и установка
                                      apply сам выбирает install/update/миграцию
  source FILE.tar.gz SHA256            зарегистрировать исходный архив Zabbix
  fetch zabbix HTTPS_URL SHA256        скачать исходный архив Zabbix с проверкой
  set binary /absolute/path           явный путь существующего бинарника
  set config /absolute/path           явный старый конфиг
  set service NAME.service            явная существующая служба
  status                              состояние и версия
  rollback                            откат последней операции с агентом
  help / guide                        инструкция
  quit                                выход

prepare/build/apply выполняются от root. Устанавливаются gcc make libc6-dev
binutils perl pkg-config curl ca-certificates, а также libssl-dev/libpcre2-dev/zlib1g-dev
и attr для сохранения атрибутов прежнего бинарника.
APT использует уже настроенные репозитории Astra: sources.list не изменяется,
обновление всей ОС и удаление пакетов не выполняются. Журналы APT сохраняются,
скачанные .deb направлены в .zabbix-agent2-work/apt/archives.
Go скачивается готовым официальным архивом и проверяется по SHA-256; при наличии
подходящего Go используется он. Go, OpenSSL и PCRE2 из исходников не собираются.
Из исходников собирается только Zabbix Agent2 7.0.32, Go-модули берутся из vendor.
Материалы находятся в .zabbix-agent2-work текущего каталога запуска. Старая
цепочка компиляторов в этой папке не используется и автоматически не удаляется.
После build работающая служба не заменяется; установка выполняется по apply.
Старый конфиг Agent2 сохраняется. Классический агент мигрируется с backup/откатом;
LoadModule требует отдельной подготовки. Политики и защиты Astra не отключаются.
Откат восстанавливает агент и службу; установленные APT-зависимости остаются.
HELP
}
guide_text() {
  cat <<'ZABBIX_AGENT2_READY_GUIDE_20261125'
# Zabbix Agent2 на COD: готовый Go и сборка только Zabbix

Скрипт запускается прямо на COD с Astra Linux из терминала в RDP. SSH/Ansible
не нужны. Он собирает Zabbix Agent2 7.0.32 из исходников, использует готовый Go
и системные библиотеки OpenSSL/PCRE2. Цепочки сборки Go и сборки библиотек нет.

## Запуск

Остановите прежний запущенный скрипт через Ctrl+C, замените файл целиком и
перезапустите из той же рабочей папки под root:

```bash
cd /home/rcodaib/tmp
bash ./zabbix_agent2_local.sh
```

Первый запуск выполняет только анализ и открывает меню. Анализ не устанавливает
пакеты, не скачивает Go, не создаёт рабочую папку и не перезапускает службу.
Отдельный анализ без меню: `bash zabbix_agent2_local.sh --analyze`.

## Основные команды

```text
prepare
build
apply
status
rollback
quit
```

- `prepare`: установить необходимые пакеты, подготовить готовый Go и исходники
  Zabbix. Компиляция агента и изменение службы не выполняются.
- `build`: выполнить недостающую подготовку и собрать только `zabbix_agent2`.
  Работающая служба не изменяется. Путь к бинарнику и журналу выводится на экран.
- `apply`: показать план, запросить точное имя компьютера для подтверждения,
  подготовить/собрать агент и выполнить установку либо обновление.
- `status`: показать состояние и версию.
- `rollback`: восстановить последнюю версию агента/состояние службы.

`install` дополнительно требует отсутствия агента; `update` требует его наличия.
APT и сборка выполняются только после явной команды подготовки/сборки/установки.

## Какие пакеты устанавливаются

Используется `apt-get install --no-install-recommends` с набором:

```text
gcc make libc6-dev binutils perl pkg-config curl ca-certificates
libssl-dev libpcre2-dev zlib1g-dev attr
```

Первые восемь пакетов — запрошенное сборочное окружение. `libssl-dev` и
`libpcre2-dev` нужны для сборки Agent2 с системными библиотеками, без компиляции
OpenSSL и PCRE2. `zlib1g-dev` предоставляет zlib для линковки (`-lz`). До основной
сборки выполняется проверка компиляции и линковки OpenSSL, PCRE2 и zlib.
Пакет `attr` сохраняет и проверяет расширенные атрибуты бинарника
без компиляции вспомогательных программ. Используются настроенные репозитории этой версии Astra;
скрипт не меняет sources.list и не выполняет общий upgrade системы. APT может
подготовить необходимые зависимости запрошенных пакетов штатным способом.
Если установка пакетов завершилась ошибкой, замена агента не начинается.

Пакет Zabbix Agent2 из репозитория не устанавливается: сам агент собирается
из проверенного архива исходников Zabbix 7.0.32.

## Готовый Go

Если подходящий Go >= 1.25.12 уже доступен, он используется. Иначе скрипт
скачивает официальный готовый Go 1.25.12 для архитектуры машины, проверяет
закреплённую SHA-256 и распаковывает в локальный `toolchains`. Поддержаны Linux
amd64, arm64 и 386. Системный `/usr/local/go` не заменяется.

Go не компилируется. Автоматическое скачивание другого toolchain выключено
через `GOTOOLCHAIN=local`. Go-модули берутся из `vendor` официального архива
Zabbix; GOPROXY/GOSUMDB выключены. Кеши и временные файлы находятся в рабочей папке.
Повторный запуск использует проверенный готовый Go из кеша.

## Где лежат файлы

Рабочая папка — `.zabbix-agent2-work` внутри текущего каталога запуска (`pwd -P`).
Каждый раз запускайте скрипт из одной папки и от одной учётной записи root.
Для сборки используйте путь без пробелов и кириллицы.

| Подпапка | Содержимое |
| --- | --- |
| sources | Проверенный исходный архив Zabbix |
| downloads | Архив готового Go |
| apt/archives | Загруженные APT-пакеты |
| toolchains | Распакованный готовый Go |
| go, caches | Локальные кеши Go |
| builds | Исходники, журналы и собранный Agent2 |
| tmp | Временные файлы |
| logs, reports | Журналы операций и сохранённый анализ |
| backups | Резервные копии и сведения для отката |

Системные пакеты APT устанавливаются в штатные пути ОС. Установленные агент,
конфиг и служба также находятся по штатным системным путям. Старые результаты
сборки Go/библиотек из предыдущей версии не удаляются и этой версией не собираются.

## Конфигурация, миграция и откат

У существующего Agent2 сохраняются прежние конфиг, Include, Hostname, TLS,
UserParameter и параметры службы. Перед заменой проверяются SHA-256, версия,
тип агента, конфиг через `-T` и локальный `agent.ping`. Делается резервная копия,
бинарник заменяется атомарно, после запуска проверяется фактический процесс.
При ошибке выполняется откат. Повтор с тем же работающим бинарником не
перезапускает службу.

Если сейчас работает классический `zabbix_agentd`, план будет явно обозначен
как миграция. Создаются отдельные бинарник, конфиг и служба Agent2. Совместимые
настройки переносятся, Include разворачиваются в новый конфиг как снимок,
старые файлы не перезаписываются. Runtime PID/socket получают отдельную папку
`/run/zabbix-agent2-source`. Старый агент останавливается только после проверки
новой сборки и нового конфига. Ошибка запуска Agent2 восстанавливает старую службу.

LoadModule, нестандартный пользователь, AllowRoot=1, неизвестные параметры
и неоднозначные службы требуют отдельной подготовки; скрипт сообщает причину.
Если конфига нет, запрашиваются Server, ServerActive и Hostname. Для active-only
параметр Server не записывается, StartAgents в конфиг Agent2 не добавляется.

Для уточнения путей доступны `set binary /absolute/path`, `set config /absolute/path`
и `set service NAME.service`. `report` сохраняет читаемый анализ.

Откат относится к агенту и службе. Предварительно установленные пакеты сборки
автоматически не удаляются. Защиты/подписи/политики Astra не отключаются.
После обновления проверьте `agent.version` и поступление данных на сервере Zabbix.

Полная инструкция: `bash zabbix_agent2_local.sh guide`.
ZABBIX_AGENT2_READY_GUIDE_20261125
}
dispatch() {
  local command=${1-help}; [[ $# -eq 0 ]] || shift
  case "$command" in
    analyze|--analyze|audit|plan) [[ $# -eq 0 ]] || return 1; analyze ;;
    help|--help|-h) help_text ;;
    guide) guide_text ;;
    source) [[ $# -eq 2 ]] || { fail 'source FILE SHA256'; return 1; }; register_archive zabbix "$@" ;;
    dependency|build-deps) fail 'Библиотеки теперь устанавливаются через APT. Используйте prepare или build.' ;;
    fetch) [[ $# -eq 3 ]] || { fail 'fetch zabbix HTTPS_URL SHA256'; return 1; }; fetch_archive "$@" ;;
    prepare) [[ $# -eq 0 ]] || return 1; prepare ;;
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
