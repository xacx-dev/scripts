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
