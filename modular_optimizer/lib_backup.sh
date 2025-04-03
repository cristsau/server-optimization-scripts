#!/bin/bash
# lib_backup.sh - Backup functions (v1.3 - Enhanced remote cleanup)

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
CONFIG_FILE="/etc/backup.conf"
BACKUP_CRON="/etc/cron.d/backup_tasks"
TEMP_LOG="/tmp/backup_temp.log"
LOG_FILE="/root/log/backup.log"
# shellcheck source=./lib_utils.sh
source "$SCRIPT_DIR/lib_utils.sh" # For log, clear_cmd, validation helpers
# shellcheck source=./lib_config.sh
source "$SCRIPT_DIR/lib_config.sh" # For load_config, create_config

# --- Functions ---
check_backup_tools() { local protocol=$1 tool deps=() missing=() optional_missing=() found=(); case $protocol in webdav) deps=("curl" "grep" "sed");; ftp) deps=("ftp" "lftp");; sftp) deps=("ssh" "sftp" "sshpass");; scp) deps=("ssh" "scp" "sshpass");; rsync) deps=("ssh" "rsync" "sshpass");; local) deps=();; *) log "错误:不支持协议 $protocol"; echo "协议错误"; return 1;; esac; for tool in "${deps[@]}"; do if command -v "$tool" >/dev/null; then found+=("$tool"); else if [[ "$tool" == "lftp" && " ${found[*]} " =~ " ftp " ]]; then continue; elif [[ "$tool" == "ftp" && " ${found[*]} " =~ " lftp " ]]; then continue; elif [[ "$tool" == "sshpass" ]]; then optional_missing+=("$tool"); else missing+=("$tool"); fi; fi; done; if [ ${#missing[@]} -gt 0 ]; then log "错误:协议 $protocol 缺少: ${missing[*]}"; echo "协议'$protocol'缺少: ${missing[*]}"; return 1; fi; if [ ${#optional_missing[@]} -gt 0 ]; then if [[ "${optional_missing[*]}" == "sshpass" ]]; then echo "提示:未找到sshpass,密码操作可能失败"; fi; fi; return 0; }

install_db_client() { local db_type=$1 pkg="" needed=false; if [[ "$db_type" == "mysql" ]]; then pkg="mysql-client"; if ! command -v mysqldump >/dev/null; then needed=true; fi; elif [[ "$db_type" == "postgres" ]]; then pkg="postgresql-client"; if ! command -v pg_dump >/dev/null || ! command -v psql >/dev/null; then needed=true; fi; else log "错误:不支持DB类型 $db_type"; echo "DB类型错误"; return 1; fi; if $needed; then echo "需要 $pkg"; read -p "安装?(y/N):" install_cli; if [[ "$install_cli" == "y" || "$install_cli" == "Y" ]]; then log "安装 $pkg"; apt-get update -qq && apt-get install -y "$pkg" || { log "错误:$pkg 安装失败"; echo "安装失败"; return 1; }; log "$pkg 安装成功"; echo "$pkg 安装成功"; else log "跳过安装 $pkg"; echo "未安装客户端"; return 1; fi; fi; return 0; }

upload_backup() {
    local file="$1"
    local target="$2"
    local username="$3"
    local password="$4"
    local filename=$(basename "$file")

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        log "错误: upload_backup 无效源文件 $file"
        return 1
    fi
    if [ -z "$target" ]; then
        log "错误: upload_backup 无效目标路径"
        return 1
    fi

    local protocol url
    if [[ "$target" =~ ^http ]]; then
        protocol="webdav"
        url="${target%/}/$filename"
    elif [[ "$target" =~ ^ftp ]]; then
        protocol="ftp"
        url="${target%/}/$filename"
    elif [[ "$target" =~ ^sftp ]]; then
        protocol="sftp"
        url="${target%/}/$filename"
    elif [[ "$target" =~ ^scp ]]; then
        protocol="scp"
        url="${target%/}/$filename"
    elif [[ "$target" =~ ^rsync ]]; then
        protocol="rsync"
        url="${target%/}/$filename"
    else
        protocol="local"
        url="${target%/}/$filename"
    fi

    if [ "$protocol" != "local" ]; then
        check_backup_tools "$protocol" || return 1
    fi

    # 在上传前清理远端旧备份文件
    case $protocol in
        webdav)
            echo -e "\033[36m正在清理 WebDAV 旧备份...\033[0m"
            curl -u "$username:$password" -X PROPFIND "${target%/}" -H "Depth: 1" >"$TEMP_LOG" 2>&1
            if [ $? -eq 0 ]; then
                if command -v grep >/dev/null 2>&1 && grep -P "" /dev/null >/dev/null 2>&1; then
                    all_files=$(grep -oP '(?<=<D:href>).*?(?=</D:href>)' "$TEMP_LOG" | grep -E '\.(tar\.gz|sql\.gz)$')
                else
                    all_files=$(grep '<D:href>' "$TEMP_LOG" | sed 's|.*<D:href>\(.*\)</D:href>.*|\1|' | grep -E '\.(tar\.gz|sql\.gz)$')
                fi
                log "WebDAV 提取的所有备份文件路径: $all_files"
                old_files=$(echo "$all_files" | sed 's|.*/||' | grep -v "^${filename}$")
                log "WebDAV 旧备份文件列表: $old_files"
                if [ -n "$old_files" ]; then
                    for old_file in $old_files; do
                        delete_url="${target%/}/${old_file}"
                        curl -u "$username:$password" -X DELETE "$delete_url" >"$TEMP_LOG" 2>&1
                        if [ $? -eq 0 ]; then
                            echo -e "\033[32m✔ 删除旧文件: $delete_url\033[0m"
                            log "WebDAV 旧备份删除成功: $delete_url"
                        else
                            echo -e "\033[31m✗ 删除旧文件失败: $delete_url\033[0m"
                            log "WebDAV 旧备份删除失败: $(cat "$TEMP_LOG")"
                        fi
                    done
                else
                    echo -e "\033[32m✔ 无旧备份需要清理\033[0m"
                    log "WebDAV 无旧备份需要清理"
                fi
            else
                echo -e "\033[31m✗ 无法获取 WebDAV 文件列表\033[0m"
                log "WebDAV 获取文件列表失败: $(cat "$TEMP_LOG")"
            fi
            rm -f "$TEMP_LOG"
            ;;
        sftp)
            echo -e "\033[36m正在清理 SFTP 旧备份...\033[0m"
            echo "ls" | sftp -b - "$username@${target#sftp://}" >"$TEMP_LOG" 2>&1
            if [ $? -eq 0 ]; then
                old_files=$(grep -v "$filename" "$TEMP_LOG" | grep -E '\.(tar\.gz|sql\.gz)$')
                for old_file in $old_files; do
                    echo "rm $old_file" | sftp -b - "$username@${target#sftp://}" >/dev/null 2>&1
                    if [ $? -eq 0 ]; then
                        echo -e "\033[32m✔ 删除旧文件: $old_file\033[0m"
                        log "SFTP 旧备份删除成功: $old_file"
                    else
                        echo -e "\033[33m⚠ 删除旧文件失败: $old_file\033[0m"
                        log "SFTP 旧备份删除失败: $old_file"
                    fi
                done
            else
                echo -e "\033[33m⚠ 无法获取 SFTP 文件列表，跳过清理\033[0m"
                log "SFTP 获取文件列表失败: $(cat "$TEMP_LOG")"
            fi
            rm -f "$TEMP_LOG"
            ;;
        ftp|rsync|scp)
            echo -e "\033[33m⚠ $protocol 暂不支持自动清理旧备份，请手动管理远端文件\033[0m"
            log "$protocol 不支持自动清理旧备份"
            ;;
        local)
            echo -e "\033[36m正在清理本地旧备份...\033[0m"
            find "$target" -type f \( -name "*.tar.gz" -o -name "*.sql.gz" \) -not -name "$filename" -exec rm -f {} \;
            if [ $? -eq 0 ]; then
                echo -e "\033[32m✔ 本地旧备份清理成功\033[0m"
                log "本地旧备份清理成功"
            else
                echo -e "\033[33m⚠ 本地旧备份清理失败\033[0m"
                log "本地旧备份清理失败"
            fi
            ;;
    esac

    # 上传新备份
    local curl_status
    case $protocol in
        webdav)
            echo -e "\033[36m正在上传到 WebDAV: $url...\033[0m"
            curl -u "$username:$password" -T "$file" "$url" -v >"$TEMP_LOG" 2>&1
            curl_status=$?
            log "curl 上传返回码: $curl_status"
            if [ $curl_status -eq 0 ]; then
                curl -u "$username:$password" -I "$url" >"$TEMP_LOG" 2>&1
                if grep -q "HTTP/[0-9.]* 200" "$TEMP_LOG" || grep -q "HTTP/[0-9.]* 201" "$TEMP_LOG"; then
                    echo -e "\033[32m✔ 上传成功: $url\033[0m"
                    log "备份上传成功: $url"
                    rm -f "$file"
                    rm -f "$TEMP_LOG"
                    return 0
                else
                    echo -e "\033[31m✗ 上传失败：服务器未确认文件存在\033[0m"
                    log "备份上传失败: 服务器未确认文件存在"
                    rm -f "$TEMP_LOG"
                    return 1
                fi
            else
                echo -e "\033[31m✗ 上传失败：\033[0m"
                log "备份上传失败: $(cat "$TEMP_LOG")"
                rm -f "$TEMP_LOG"
                return 1
            fi
            ;;
        ftp)
            echo -e "\033[36m正在上传到 FTP: $url...\033[0m"
            if command -v lftp > /dev/null; then
                lftp -c "set ftp:ssl-allow no; open -u '$username','$password' '${target#ftp://}'; put '$file' -o '$filename'; bye"
            else
                echo -e "user $username $password\nbinary\nput '$file' '$filename'\nquit" | ftp -n "${target#ftp://}" >"$TEMP_LOG" 2>&1
                grep -qE "Transfer complete|Bytes sent" "$TEMP_LOG" && return 0 || return 1
            fi
            ;;
        sftp)
            echo -e "\033[36m正在上传到 SFTP: $url...\033[0m"
            if [[ -f "$password" ]]; then
                echo "put '$file' '$filename'" | sftp -b - -i "$password" "$username@${target#sftp://}" >/dev/null 2>&1
            elif command -v sshpass > /dev/null && [ -n "$password" ]; then
                echo "put '$file' '$filename'" | sshpass -p "$password" sftp -b - "$username@${target#sftp://}" >/dev/null 2>&1
            else
                echo "put '$file' '$filename'" | sftp -b - "$username@${target#sftp://}" >/dev/null 2>&1
            fi
            ;;
        scp)
            echo -e "\033[36m正在上传到 SCP: $url...\033[0m"
            if [[ -f "$password" ]]; then
                scp -i "$password" "$file" "$username@${target#scp://}:$filename" >/dev/null 2>&1
            elif command -v sshpass > /dev/null && [ -n "$password" ]; then
                sshpass -p "$password" scp "$file" "$username@${target#scp://}:$filename" >/dev/null 2>&1
            else
                scp "$file" "$username@${target#scp://}:$filename" >/dev/null 2>&1
            fi
            ;;
        rsync)
            echo -e "\033[36m正在同步到 rsync: $url...\033[0m"
            if [[ -f "$password" ]]; then
                rsync -az -e "ssh -i '$password'" "$file" "$username@${target#rsync://}:$filename" >/dev/null 2>&1
            elif command -v sshpass > /dev/null && [ -n "$password" ]; then
                rsync -az -e "sshpass -p '$password' ssh" "$file" "$username@${target#rsync://}:$filename" >/dev/null 2>&1
            else
                rsync -az "$file" "$username@${target#rsync://}:$filename" >/dev/null 2>&1
            fi
            ;;
        local)
            echo -e "\033[36m正在移动到本地: $url...\033[0m"
            mkdir -p "$target"
            mv "$file" "$url"
            if [ $? -eq 0 ]; then
                echo -e "\033[32m✔ 本地备份成功: $url\033[0m"
                log "本地备份成功: $url"
                return 0
            else
                echo -e "\033[31m✗ 本地备份失败\033[0m"
                log "本地备份失败"
                return 1
            fi
            ;;
    esac

    if [ $? -eq 0 ]; then
        echo -e "\033[32m✔ 上传成功: $url\033[0m"
        log "备份上传成功: $url"
        rm -f "$file"
        return 0
    else
        echo -e "\033[31m✗ 上传失败，请检查配置\033[0m"
        log "备份上传失败: $url"
        return 1
    fi
}

add_cron_job() {
    local temp_backup_file="$1" target_path="$2" username="$3" password="$4" cron_cmd_base="$5"
    local backup_filename protocol host path_part target_clean url minute hour cron_day final_cron_cmd rm_cmd escaped_log_file
    backup_filename=$(basename "$temp_backup_file")
    if [[ -n "$password" ]]; then echo -e "\033[31m警告：密码/密钥将明文写入Cron文件($BACKUP_CRON)，存在安全风险！\033[0m"; read -p "确认继续?(y/N): " confirm_pass; if [[ "$confirm_pass" != "y" && "$confirm_pass" != "Y" ]]; then echo "取消"; return 1; fi; fi
    target_clean="${target_path%/}"; protocol="local"; url="$target_clean/$backup_filename"; upload_cmd="mkdir -p '$target_clean' && mv '$temp_backup_file' '$url'"
    if [[ "$target_path" =~ ^https?:// ]]; then protocol="webdav"; url="$target_clean/$backup_filename"; upload_cmd="curl -sSf -u '$username:$password' -T '$temp_backup_file' '$url'"; elif [[ "$target_path" =~ ^ftps?:// ]]; then protocol="ftp"; host=$(echo "$target_path" | sed -E 's|^ftps?://([^/]+).*|\1|'); path_part=$(echo "$target_path" | sed -E 's|^ftps?://[^/]+(/.*)?|\1|'); if command -v lftp > /dev/null; then upload_cmd="lftp -c \"set ftp:ssl-allow no; open -u '$username','$password' '$host'; cd '$path_part'; put '$temp_backup_file' -o '$backup_filename'; bye\""; else upload_cmd="echo -e 'user $username $password\\nbinary\\ncd $path_part\\nput $temp_backup_file $backup_filename\\nquit' | ftp -n '$host'"; fi; elif [[ "$target_path" =~ ^sftp:// ]]; then protocol="sftp"; host=$(echo "$target_path" | sed -E 's|^sftp://([^/]+).*|\1|'); path_part=$(echo "$target_path" | sed -E 's|^sftp://[^/]+(/.*)?|\1|'); st="$username@$host"; pc="put '$temp_backup_file' '$path_part/$backup_filename'"; qc="quit"; if [[ -f "$password" ]]; then upload_cmd="echo -e '$pc\\n$qc' | sftp -i '$password' '$st'"; elif [[ -n "$password" ]] && command -v sshpass > /dev/null; then upload_cmd="echo -e '$pc\\n$qc' | sshpass -p '$password' sftp '$st'"; elif [[ -n "$password" ]]; then echo "sshpass needed"; return 1; else upload_cmd="echo -e '$pc\\n$qc' | sftp '$st'"; fi; elif [[ "$target_path" =~ ^scp:// ]]; then protocol="scp"; uph=$(echo "$target_path" | sed 's|^scp://||'); host=$(echo "$uph" | cut -d: -f1); path_part=$(echo "$uph" | cut -d: -f2); [ -z "$path_part" ] && path_part="."; st="$username@$host:'$path_part/$backup_filename'"; if [[ -f "$password" ]]; then upload_cmd="scp -i '$password' '$temp_backup_file' '$st'"; elif [[ -n "$password" ]] && command -v sshpass > /dev/null; then upload_cmd="sshpass -p '$password' scp '$temp_backup_file' '$st'"; elif [[ -n "$password" ]]; then echo "sshpass needed"; return 1; else upload_cmd="scp '$temp_backup_file' '$st'"; fi; elif [[ "$target_path" =~ ^rsync:// ]]; then protocol="rsync"; uph=$(echo "$target_path" | sed 's|^rsync://||'); host=$(echo "$uph" | cut -d: -f1); path_part=$(echo "$uph" | cut -d: -f2); [ -z "$path_part" ] && path_part="."; rt="$username@$host:'$path_part/$backup_filename'"; ro="-az"; sshc="ssh"; if [[ -f "$password" ]]; then sshc="ssh -i \'$password\'"; elif [[ -n "$password" ]] && command -v sshpass > /dev/null; then sshc="sshpass -p \'$password\' ssh"; elif [[ -n "$password" ]]; then echo "sshpass needed"; return 1; fi; upload_cmd="rsync $ro -e \"$sshc\" '$temp_backup_file' '$rt'"; elif [[ ! "$target_path" =~ ^/ ]]; then echo "Cron不支持相对路径"; return 1; fi;
    echo "设置频率:"; echo " *每天, */2隔天, 0-6周几(0=日), 1,3,5周一三五"; read -p "Cron星期字段(*或1或1,5): " cron_day; read -p "运行小时(0-23): " hour; read -p "运行分钟(0-59)[0]: " minute; minute=${minute:-0}; validate_numeric "$hour" "小时" || return 1; validate_numeric "$minute" "分钟" || return 1; if [[ "$cron_day" != "*" && "$cron_day" != "*/2" && ! "$cron_day" =~ ^([0-6](,[0-6])*)$ ]]; then echo "星期无效"; return 1; fi;
    rm_cmd="rm -f '$temp_backup_file'"; [[ "$protocol" == "rsync" ]] && rm_cmd=""; escaped_log_file=$(echo "$LOG_FILE" | sed 's/[\/&]/\\&/g'); final_cron_cmd="bash -c \"{ ( $cron_cmd_base $upload_cmd && $rm_cmd && echo \\\$(date '+%Y-%m-%d %H:%M:%S') - Cron SUCCESS: $backup_filename >> $escaped_log_file ) || echo \\\$(date '+%Y-%m-%d %H:%M:%S') - Cron FAILED: $backup_filename >> $escaped_log_file ; } 2>&1 | tee -a $escaped_log_file\"";
    touch "$BACKUP_CRON" && chmod 644 "$BACKUP_CRON" || { log "错误:无法写入/设置 $BACKUP_CRON 权限"; return 1; }
    if grep -Fq "$final_cron_cmd" "$BACKUP_CRON"; then echo "ℹ️  任务已存在"; log "任务已存在"; return 0; fi
    echo "$minute $hour * * $cron_day root $final_cron_cmd" >> "$BACKUP_CRON"; if [ $? -ne 0 ]; then echo "写入 $BACKUP_CRON 失败"; return 1; fi;
    echo "✅ 任务已添加到 $BACKUP_CRON"; log "添加备份Cron: $minute $hour * * $cron_day - $backup_filename"; return 0;
}

ManualBackupData() { echo -e "\033[36m▶ 手动备份程序数据...\033[0m"; log "手动备份数据开始..."; read -p "源路径: " source_path; read -e -p "目标路径: " target_path; read -p "目标用户(可选): " username; local password=""; if [ -n "$username" ]; then read -s -p "密码/密钥路径(可选): " password; echo; fi; validate_path_exists "$source_path" "e" || return 1; local timestamp source_basename backup_file tar_status; timestamp=$(date '+%Y%m%d_%H%M%S'); source_basename=$(basename "$source_path"); backup_file="/tmp/backup_${source_basename}_$timestamp.tar.gz"; echo "压缩 '$source_path' -> '$backup_file' ..."; tar -czf "$backup_file" -C "$(dirname "$source_path")" "$source_basename" 2>"$TEMP_LOG"; tar_status=$?; if [ $tar_status -eq 0 ] && [ -s "$backup_file" ]; then echo "压缩成功"; upload_backup "$backup_file" "$target_path" "$username" "$password"; if [ $? -eq 0 ]; then echo "✅ 备份上传成功"; log "手动数据备份成功: $source_path -> $target_path"; return 0; else echo "❌ 上传失败"; log "手动数据备份失败(上传)"; rm -f "$backup_file" 2>/dev/null; return 1; fi; else echo "❌ 压缩失败(码:$tar_status)"; cat "$TEMP_LOG" >&2; log "手动数据备份失败(压缩): $source_path Error: $(cat "$TEMP_LOG")"; rm -f "$backup_file" 2>/dev/null; return 1; fi; rm -f "$TEMP_LOG" 2>/dev/null; }

ManualBackupDB() { echo -e "\033[36m▶ 手动备份数据库...\033[0m"; log "手动备份数据库开始..."; local db_type db_host db_port db_user db_pass target_path username password backup_failed=false default_port; if ! load_config; then echo "未加载配置,手动输入"; read -p "类型(mysql/postgres): " db_type; case "$db_type" in mysql) default_port=3306;; postgres) default_port=5432;; *) echo "类型错误"; return 1;; esac; read -p "主机(127.0.0.1): " db_host; db_host=${db_host:-127.0.0.1}; read -p "端口[$default_port]: " db_port; db_port=${db_port:-$default_port}; validate_numeric "$db_port" "端口" || return 1; read -p "用户: " db_user; read -s -p "密码: " db_pass; echo; read -e -p "目标路径: " target_path; read -p "目标用户(可选): " username; if [ -n "$username" ]; then read -s -p "目标密码/密钥(可选): " password; echo; fi; else echo "✅ 已加载配置"; db_type=$DB_TYPE; db_host=$DB_HOST; db_port=$DB_PORT; db_user=$DB_USER; db_pass=$DB_PASS; target_path=$TARGET_PATH; username=$TARGET_USER; password=$TARGET_PASS; fi; if [[ "$db_type" != "mysql" && "$db_type" != "postgres" ]]; then echo "类型错误"; return 1; fi; install_db_client "$db_type" || return 1; if [[ -z "$db_host" || -z "$db_port" || -z "$db_user" || -z "$target_path" ]]; then echo "信息不全"; return 1; fi; echo "测试连接..."; local connection_ok=false; if [ "$db_type" = "mysql" ]; then echo "SHOW DATABASES;" | mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" --connect-timeout=5 >"$TEMP_LOG" 2>&1; [ $? -eq 0 ] && connection_ok=true || cat "$TEMP_LOG" >&2; elif [ "$db_type" = "postgres" ]; then export PGPASSWORD="$db_pass"; echo "SELECT 1;" | psql -h "$db_host" -p "$db_port" -U "$db_user" -d "postgres" -t --command="SELECT 1" >"$TEMP_LOG" 2>&1; [ $? -eq 0 ] && grep -q "1" "$TEMP_LOG" && connection_ok=true || cat "$TEMP_LOG" >&2; unset PGPASSWORD; fi; if ! $connection_ok; then echo "❌ 连接失败"; log "DB连接失败"; rm -f "$TEMP_LOG" 2>/dev/null; return 1; fi; echo "✅ 连接成功"; rm -f "$TEMP_LOG" 2>/dev/null; read -p "备份所有数据库?(y/n/a)[y]: " backup_scope; backup_scope=${backup_scope:-y}; local db_list=""; if [[ "$backup_scope" == "y" || "$backup_scope" == "Y" ]]; then db_list="all"; elif [[ "$backup_scope" == "n" || "$backup_scope" == "N" ]]; then read -p "输入DB名(空格分隔): " db_names; if [ -z "$db_names" ]; then echo "未输入"; return 1; fi; db_list="$db_names"; else return 0; fi; local timestamp; timestamp=$(date '+%Y%m%d_%H%M%S'); if [ "$db_list" = "all" ]; then local backup_file="/tmp/all_dbs_${db_type}_$timestamp.sql.gz"; echo "备份所有..."; local dump_cmd dump_status; if [ "$db_type" = "mysql" ]; then dump_cmd="mysqldump -h \"$db_host\" -P \"$db_port\" -u \"$db_user\" -p\"$db_pass\" --all-databases --routines --triggers --single-transaction"; elif [ "$db_type" = "postgres" ]; then export PGPASSWORD="$db_pass"; dump_cmd="pg_dumpall -h \"$db_host\" -p \"$db_port\" -U \"$db_user\""; fi; eval "$dump_cmd" 2>"$TEMP_LOG" | gzip > "$backup_file"; dump_status=${PIPESTATUS[0]}; if [ "$db_type" = "postgres" ]; then unset PGPASSWORD; fi; if [ $dump_status -eq 0 ] && [ -s "$backup_file" ]; then echo "备份成功"; upload_backup "$backup_file" "$target_path" "$username" "$password" || backup_failed=true; else echo "❌ 备份失败(码:$dump_status)"; cat "$TEMP_LOG" >&2; log "备份所有DB失败: $(cat "$TEMP_LOG")"; backup_failed=true; rm -f "$backup_file" 2>/dev/null; fi; else for db_name in $db_list; do local backup_file="/tmp/${db_name}_${db_type}_$timestamp.sql.gz"; echo "备份 $db_name..."; local dump_cmd dump_status; if [ "$db_type" = "mysql" ]; then dump_cmd="mysqldump -h \"$db_host\" -P \"$db_port\" -u \"$db_user\" -p\"$db_pass\" --routines --triggers --single-transaction \"$db_name\""; elif [ "$db_type" = "postgres" ]; then export PGPASSWORD="$db_pass"; dump_cmd="pg_dump -h \"$db_host\" -p \"$db_port\" -U \"$db_user\" \"$db_name\""; fi; eval "$dump_cmd" 2>"$TEMP_LOG" | gzip > "$backup_file"; dump_status=${PIPESTATUS[0]}; if [ "$db_type" = "postgres" ]; then unset PGPASSWORD; fi; if [ $dump_status -eq 0 ] && [ -s "$backup_file" ]; then echo "$db_name 备份成功"; upload_backup "$backup_file" "$target_path" "$username" "$password" || backup_failed=true; else echo "❌ $db_name 备份失败(码:$dump_status)"; cat "$TEMP_LOG" >&2; log "备份DB $db_name 失败: $(cat "$TEMP_LOG")"; backup_failed=true; rm -f "$backup_file" 2>/dev/null; fi; done; fi; rm -f "$TEMP_LOG" 2>/dev/null; if ! $backup_failed; then echo "✅ 所有请求的备份完成"; log "手动DB备份完成"; return 0; else echo "❌ 部分备份失败"; return 1; fi; }

ManageBackupConfig() { log "运行备份配置管理"; echo "管理配置..."; if [ -f "$CONFIG_FILE" ]; then echo "当前配置:"; cat "$CONFIG_FILE"; read -p "操作(e:编辑/c:重建/n:返回)[n]: " cfg_act; cfg_act=${cfg_act:-n}; if [ "$cfg_act" == "e" ]; then ${EDITOR:-nano} "$CONFIG_FILE"; elif [ "$cfg_act" == "c" ]; then create_config; fi; else read -p "未找到配置,是否创建(y/N):" create_cfg; if [[ "$create_cfg" == "y" || "$create_cfg" == "Y" ]]; then create_config; fi; fi; return 0; }

ManageBackupCron() {
    log "运行备份 Cron 管理"; echo "管理计划...";
    echo "当前任务 (来自 $BACKUP_CRON):"; local task_found_in_file=0;
    if [ -f "$BACKUP_CRON" ]; then
        while IFS= read -r line; do
            if [[ -n "$line" && ! "$line" =~ ^\s*# && "$line" =~ ^[0-9*] ]]; then
                task_found_in_file=1
                local m h dom mon dow user command schedule_str short_cmd dbn srcn
                read -r m h dom mon dow user command <<< "$line"
                schedule_str=$(format_cron_schedule_human "$m" "$h" "$dom" "$mon" "$dow")
                if [[ "$command" == *"pg_dumpall"* ]]; then short_cmd="PostgreSQL 全部数据库备份"; elif [[ "$command" == *"mysqldump --all-databases"* ]]; then short_cmd="MySQL 全部数据库备份"; elif [[ "$command" == *"pg_dump"* ]]; then dbn=$(echo "$command" | grep -oP "(pg_dump.* '|pg_dump.* )\\K[^' |]+"); [ -n "$dbn" ] && short_cmd="PostgreSQL 备份 '$dbn'" || short_cmd="PostgreSQL 特定DB备份"; elif [[ "$command" == *"mysqldump"* ]]; then dbn=$(echo "$command" | grep -oP "(mysqldump.* '|mysqldump.* )\\K[^' |]+"); [ -n "$dbn" ] && short_cmd="MySQL 备份 '$dbn'" || short_cmd="MySQL 特定DB备份"; elif [[ "$command" == *"tar -czf /tmp/backup_data"* ]]; then srcn=$(echo "$command" | grep -oP "backup_data_\\K[^_]+"); [ -n "$srcn" ] && short_cmd="程序数据备份 ($srcn)" || short_cmd="程序数据备份 (tar)"; else short_cmd="备份任务 (命令较长)"; fi
                printf "  %-28s User:%-8s %s\n" "$schedule_str" "$user" "$short_cmd"
            fi
        done < "$BACKUP_CRON"
        if [ $task_found_in_file -eq 0 ]; then echo "  (文件为空或只包含注释)"; fi
    else
        echo "  (文件不存在)";
    fi
    echo ""; read -p "操作(a:添加/d:删除/e:编辑/n:返回)[n]: " cron_action; cron_action=${cron_action:-n}
    if [[ "$cron_action" == "a" ]]; then echo "添加任务..."; local backup_type backup_failed=false; read -p "类型(1:数据/2:数据库): " backup_type; validate_numeric "$backup_type" "类型" || return 1; if [ "$backup_type" = "1" ]; then read -p "源路径: " source_path; read -e -p "目标路径: " target_path; read -p "目标用户(可选): " username; local password=""; if [ -n "$username" ]; then read -s -p "密码/密钥路径(可选): " password; echo; fi; validate_path_exists "$source_path" "e" || return 1; local source_basename timestamp_format backup_filename temp_backup_file tar_cmd cron_cmd_base; source_basename=$(basename "$source_path"); timestamp_format='$(date +\%Y\%m\%d_\%H\%M\%S)'; backup_filename="backup_${source_basename}_${timestamp_format}.tar.gz"; temp_backup_file="/tmp/$backup_filename"; tar_cmd="tar -czf '$temp_backup_file' -C '$(dirname "$source_path")' '$source_basename'"; cron_cmd_base="$tar_cmd && "; add_cron_job "$temp_backup_file" "$target_path" "$username" "$password" "$cron_cmd_base" || backup_failed=true; elif [ "$backup_type" = "2" ]; then if ! load_config; then echo "需先创建配置"; return 1; fi; local db_type db_host db_port db_user db_pass target_path username password; db_type=$DB_TYPE; db_host=$DB_HOST; db_port=$DB_PORT; db_user=$DB_USER; db_pass=$DB_PASS; target_path=$TARGET_PATH; username=$TARGET_USER; password=$TARGET_PASS; install_db_client "$db_type" || return 1; read -p "备份所有?(y/n)[y]: " backup_scope_cron; backup_scope_cron=${backup_scope_cron:-y}; local db_list_cron=""; if [[ "$backup_scope_cron" == "y" ]]; then db_list_cron="all"; elif [[ "$backup_scope_cron" == "n" ]]; then read -p "输入DB名: " db_names_cron; if [ -z "$db_names_cron" ]; then echo "未输入"; return 1; fi; db_list_cron="$db_names_cron"; else echo "无效选择"; return 1; fi; local timestamp_format='$(date +\%Y\%m\%d_\%H\%M\%S)'; if [ "$db_list_cron" = "all" ]; then local backup_filename temp_backup_file dump_cmd cron_cmd_base; backup_filename="all_dbs_${db_type}_${timestamp_format}.sql.gz"; temp_backup_file="/tmp/$backup_filename"; dump_cmd=""; if [ "$db_type" = "mysql" ]; then dump_cmd="mysqldump -h '$db_host' -P '$db_port' -u '$db_user' -p'$db_pass' --all-databases --routines --triggers --single-transaction"; elif [ "$db_type" = "postgres" ]; then dump_cmd="PGPASSWORD='$db_pass' pg_dumpall -h '$db_host' -p '$db_port' -U '$db_user'"; fi; cron_cmd_base="$dump_cmd | gzip > '$temp_backup_file' && "; add_cron_job "$temp_backup_file" "$target_path" "$username" "$password" "$cron_cmd_base" || backup_failed=true; else for db_name in $db_list_cron; do local backup_filename temp_backup_file dump_cmd cron_cmd_partial; backup_filename="${db_name}_${db_type}_${timestamp_format}.sql.gz"; temp_backup_file="/tmp/$backup_filename"; dump_cmd=""; if [ "$db_type" = "mysql" ]; then dump_cmd="mysqldump -h '$db_host' -P '$db_port' -u '$db_user' -p'$db_pass' --routines --triggers --single-transaction '$db_name'"; elif [ "$db_type" = "postgres" ]; then dump_cmd="PGPASSWORD='$db_pass' pg_dump -h '$db_host' -p '$db_port' -U '$db_user' '$db_name'"; fi; cron_cmd_partial="$dump_cmd | gzip > '$temp_backup_file' && "; add_cron_job "$temp_backup_file" "$target_path" "$username" "$password" "$cron_cmd_partial" || backup_failed=true; done; fi; else echo "类型错误"; return 1; fi; if ! $backup_failed; then echo "✅ Cron任务添加/更新完成"; else echo "❌ 部分Cron任务添加失败"; fi;
    elif [[ "$cron_action" == "d" ]]; then read -p "确定删除 $BACKUP_CRON 文件中的所有任务?(y/N): " confirm_delete; if [[ "$confirm_delete" == "y" || "$confirm_delete" == "Y" ]]; then if [ -f "$BACKUP_CRON" ]; then rm -v "$BACKUP_CRON" && echo "文件已删除" || echo "删除失败"; log "备份任务文件 $BACKUP_CRON 已被用户删除"; else echo "文件不存在。"; fi; else echo "取消删除。"; fi
    elif [[ "$cron_action" == "e" ]]; then [ ! -f "$BACKUP_CRON" ] && touch "$BACKUP_CRON"; ${EDITOR:-nano} "$BACKUP_CRON"; chmod 644 "$BACKUP_CRON"; fi
    return 0
}

backup_menu() {
    while true; do clear_cmd; echo -e "\033[34m💾 备份工具 ▍\033[0m"; echo -e "\033[36m"; echo " 1) 手动备份程序数据"; echo " 2) 手动备份数据库"; echo " 3) 创建/管理备份配置文件 ($CONFIG_FILE)"; echo " 4) 设置/查看备份计划任务 ($BACKUP_CRON)"; echo " 5) 返回主菜单"; echo -e "\033[0m"; read -p "请输入选项 (1-5): " choice; case $choice in 1) ManualBackupData;; 2) ManualBackupDB;; 3) ManageBackupConfig;; 4) ManageBackupCron;; 5) return 0;; *) echo "无效选项";; esac; read -p "按回车继续..."; done
}