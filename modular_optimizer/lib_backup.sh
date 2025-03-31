#!/bin/bash
# lib_backup.sh - Backup functions (v1.2 - Simplified cron display)

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
source "$SCRIPT_DIR/lib_utils.sh" # For log, clear_cmd, validation helpers, format_cron_schedule_human
source "$SCRIPT_DIR/lib_config.sh" # For load_config, create_config

# --- Functions ---
check_backup_tools() {
    local protocol=$1 tool deps=() missing=() optional_missing=() found=()
    case $protocol in webdav) deps=("curl" "grep" "sed");; ftp) deps=("ftp" "lftp");; sftp) deps=("ssh" "sftp" "sshpass");; scp) deps=("ssh" "scp" "sshpass");; rsync) deps=("ssh" "rsync" "sshpass");; local) deps=();; *) log "错误:不支持备份协议 $protocol"; echo "协议错误"; return 1;; esac
    for tool in "${deps[@]}"; do if command -v "$tool" >/dev/null; then found+=("$tool"); else if [[ "$tool" == "lftp" && " ${found[*]} " =~ " ftp " ]]; then continue; elif [[ "$tool" == "ftp" && " ${found[*]} " =~ " lftp " ]]; then continue; elif [[ "$tool" == "sshpass" ]]; then optional_missing+=("$tool"); else missing+=("$tool"); fi; fi; done
    if [ ${#missing[@]} -gt 0 ]; then log "错误:备份协议 $protocol 缺少工具: ${missing[*]}"; echo "协议'$protocol'缺少工具: ${missing[*]}"; return 1; fi
    if [ ${#optional_missing[@]} -gt 0 ]; then if [[ "${optional_missing[*]}" == "sshpass" ]]; then echo "提示:未找到sshpass,密码操作可能失败。建议用密钥。"; fi; fi; return 0;
}

install_db_client() {
    local db_type=$1 pkg="" needed=false
    if [[ "$db_type" == "mysql" ]]; then pkg="mysql-client"; if ! command -v mysqldump >/dev/null; then needed=true; fi
    elif [[ "$db_type" == "postgres" ]]; then pkg="postgresql-client"; if ! command -v pg_dump >/dev/null || ! command -v psql >/dev/null; then needed=true; fi
    else log "错误:不支持DB类型 $db_type"; echo "DB类型错误"; return 1; fi
    if $needed; then echo "需要 $pkg"; read -p "是否安装?(y/N):" install_cli; if [[ "$install_cli" == "y" || "$install_cli" == "Y" ]]; then log "安装 $pkg"; apt-get update -qq && apt-get install -y "$pkg" || { log "错误:$pkg 安装失败"; echo "安装失败"; return 1; }; log "$pkg 安装成功"; echo "$pkg 安装成功"; else log "用户跳过安装 $pkg"; echo "未安装客户端"; return 1; fi; fi
    return 0
}

upload_backup() {
    local file="$1" target="$2" username="$3" password="$4"
    local filename=$(basename "$file") protocol url host path_part

    if [ -z "$file" ] || [ ! -f "$file" ]; then
        log "错误: upload_backup 无效源文件 $file"
        return 1
    fi
    if [ -z "$target" ]; then
        log "错误: upload_backup 无效目标路径"
        return 1
    fi

    if [[ "$target" =~ ^https?:// ]]; then protocol="webdav"; url="${target%/}/$filename"
    elif [[ "$target" =~ ^ftps?:// ]]; then protocol="ftp"; host=$(echo "$target" | sed -E 's|^ftps?://([^/]+).*|\1|'); path_part=$(echo "$target" | sed -E 's|^ftps?://[^/]+(/.*)?|\1|'); url="${target%/}/$filename"
    elif [[ "$target" =~ ^sftp:// ]]; then protocol="sftp"; host=$(echo "$target" | sed -E 's|^sftp://([^/]+).*|\1|'); path_part=$(echo "$target" | sed -E 's|^sftp://[^/]+(/.*)?|\1|'); url="${target%/}/$filename"; if [[ -z "$username" && "$host" =~ .*@.* ]]; then username=$(echo "$host" | cut -d@ -f1); host=$(echo "$host" | cut -d@ -f2); fi
    elif [[ "$target" =~ ^scp:// ]]; then protocol="scp"; host=$(echo "$target" | sed -E 's|^scp://([^/]+).*|\1|'); path_part=$(echo "$target" | sed -E 's|^scp://[^/]+(/.*)?|\1|'); url="${target%/}/$filename"; if [[ -z "$username" && "$host" =~ .*@.* ]]; then username=$(echo "$host" | cut -d@ -f1); host=$(echo "$host" | cut -d@ -f2); fi
    elif [[ "$target" =~ ^rsync:// ]]; then protocol="rsync"; host=$(echo "$target" | sed -E 's|^rsync://([^/]+).*|\1|'); path_part=$(echo "$target" | sed -E 's|^rsync://[^/]+(/.*)?|\1|'); url="${target%/}/$filename"; if [[ -z "$username" && "$host" =~ .*@.* ]]; then username=$(echo "$host" | cut -d@ -f1); host=$(echo "$host" | cut -d@ -f2); fi
    elif [[ "$target" =~ ^/ ]]; then protocol="local"; url="$target/$filename"
    else echo -e "\033[31m✗ 不支持的目标路径格式: $target\033[0m"; log "不支持的目标路径格式: $target"; return 1; fi
    log "准备上传 '$filename' 到 '$target' (协议: $protocol)"

    if [ "$protocol" != "local" ]; then check_backup_tools "$protocol" || return 1; fi

    local LOCAL_KEEP_N=${LOCAL_RETENTION_DAYS:-1}
    local REMOTE_KEEP_N=${REMOTE_RETENTION_DAYS:-1}
    [[ "$LOCAL_KEEP_N" -lt 0 ]] && LOCAL_KEEP_N=0
    [[ "$REMOTE_KEEP_N" -lt 0 ]] && REMOTE_KEEP_N=0
    log "保留配置: 本地保留 $LOCAL_KEEP_N 个, 远程保留 $REMOTE_KEEP_N 个"

    case $protocol in
        webdav)
            if [[ "$REMOTE_KEEP_N" -gt 0 ]]; then
                echo -e "\033[36m正在清理 WebDAV 旧备份 (保留最近 $REMOTE_KEEP_N 份)...\033[0m"
                curl -u "$username:$password" -X PROPFIND "${target%/}" -H "Depth: 1" >"$TEMP_LOG" 2>&1
                if [ $? -eq 0 ] && [ -s "$TEMP_LOG" ]; then
                    if command -v grep >/dev/null 2>&1 && grep -P "" /dev/null >/dev/null 2>&1; then
                        all_files=$(grep -oP '(?<=<D:href>).*?(?=</D:href>)' "$TEMP_LOG" | grep -E '\.(tar\.gz|sql\.gz)$')
                    else
                        all_files=$(grep '<D:href>' "$TEMP_LOG" | sed 's|.*<D:href>\(.*\)</D:href>.*|\1|' | grep -E '\.(tar\.gz|sql\.gz)$')
                    fi
                    log "WebDAV 提取的所有备份文件路径: $all_files"
                    sorted_files=$(echo "$all_files" | sed -n 's|.*/[^_]*_\([0-9]\{8\}_[0-9]\{6\}\)\..*|\1 &|p' | sort -k1,1r)
                    files_to_delete=$(echo "$sorted_files" | awk -v keep="$REMOTE_KEEP_N" 'NR > keep { $1=""; print $0 }' | sed 's|^ ||')
                    log "WebDAV 待删除旧备份文件: $files_to_delete"
                    if [ -n "$files_to_delete" ]; then
                        for old_file in $files_to_delete; do
                            delete_url="${target%/}/${old_file##*/}"
                            log "尝试删除 WebDAV 文件: $delete_url"
                            curl -u "$username:$password" -X DELETE "$delete_url" >"$TEMP_LOG" 2>&1
                            if [ $? -eq 0 ]; then echo -e "\033[32m✔ 删除旧文件: $delete_url\033[0m"; log "WebDAV 旧备份删除成功: $delete_url"; else echo -e "\033[31m✗ 删除旧文件失败: $delete_url\033[0m"; echo "服务器响应：$(cat "$TEMP_LOG")"; log "WebDAV 旧备份删除失败: $(cat "$TEMP_LOG")"; fi
                        done
                    else echo -e "\033[32m✔ 无旧备份需要清理\033[0m"; log "WebDAV 无旧备份需要清理"; fi
                else echo -e "\033[31m✗ 无法获取 WebDAV 文件列表\033[0m"; echo "服务器响应：$(cat "$TEMP_LOG")"; log "WebDAV 获取文件列表失败: $(cat "$TEMP_LOG")"; fi
            else echo -e "\033[33mℹ️  跳过 WebDAV 旧备份清理 (保留份数=0)\033[0m"; log "跳过 WebDAV 清理 (保留份数=0)"; fi
            rm -f "$TEMP_LOG"
            ;;
        sftp)
            if [[ "$REMOTE_KEEP_N" -gt 0 ]]; then
                echo -e "\033[36m正在清理 SFTP 旧备份 (保留最近 $REMOTE_KEEP_N 份)...\033[0m"
                if [[ -f "$password" ]]; then echo "ls -l" | sftp -i "$password" "$username@$host" >"$TEMP_LOG" 2>&1
                elif [[ -n "$password" ]] && command -v sshpass >/dev/null; then echo "ls -l" | sshpass -p "$password" sftp "$username@$host" >"$TEMP_LOG" 2>&1
                else echo "ls -l" | sftp "$username@$host" >"$TEMP_LOG" 2>&1; fi
                if [ $? -eq 0 ]; then
                    all_files=$(grep -E '\.(tar\.gz|sql\.gz)$' "$TEMP_LOG" | awk '{print $NF}')
                    sorted_files=$(echo "$all_files" | sed -n 's|.*_\([0-9]\{8\}_[0-9]\{6\}\)\..*|\1 &|p' | sort -k1,1r)
                    files_to_delete=$(echo "$sorted_files" | awk -v keep="$REMOTE_KEEP_N" 'NR > keep { $1=""; print $0 }' | sed 's|^ ||')
                    log "SFTP 待删除旧备份文件: $files_to_delete"
                    if [ -n "$files_to_delete" ]; then
                        for old_file in $files_to_delete; do
                            if [[ -f "$password" ]]; then echo "rm $path_part/$old_file" | sftp -i "$password" "$username@$host" >"$TEMP_LOG" 2>&1
                            elif [[ -n "$password" ]] && command -v sshpass >/dev/null; then echo "rm $path_part/$old_file" | sshpass -p "$password" sftp "$username@$host" >"$TEMP_LOG" 2>&1
                            else echo "rm $path_part/$old_file" | sftp "$username@$host" >"$TEMP_LOG" 2>&1; fi
                            if [ $? -eq 0 ]; then echo -e "\033[32m✔ 删除旧文件: $old_file\033[0m"; log "SFTP 旧备份删除成功: $old_file"; else echo -e "\033[33m⚠ 删除旧文件失败: $old_file\033[0m"; log "SFTP 旧备份删除失败: $(cat "$TEMP_LOG")"; fi
                        done
                    else echo -e "\033[32m✔ 无旧备份需要清理\033[0m"; log "SFTP 无旧备份需要清理"; fi
                else echo -e "\033[33m⚠ 无法获取 SFTP 文件列表，跳过清理\033[0m"; log "SFTP 获取文件列表失败: $(cat "$TEMP_LOG")"; fi
            else echo -e "\033[33mℹ️  跳过 SFTP 旧备份清理 (保留份数=0)\033[0m"; log "跳过 SFTP 清理 (保留份数=0)"; fi
            rm -f "$TEMP_LOG"
            ;;
        ftp)
            if [[ "$REMOTE_KEEP_N" -gt 0 ]]; then
                echo -e "\033[36m正在清理 FTP 旧备份 (保留最近 $REMOTE_KEEP_N 份)...\033[0m"
                if command -v lftp >/dev/null; then
                    lftp -u "$username,$password" "$host" -e "ls; bye" >"$TEMP_LOG" 2>&1
                    if [ $? -eq 0 ]; then
                        all_files=$(grep -E '\.(tar\.gz|sql\.gz)$' "$TEMP_LOG" | awk '{print $NF}')
                        sorted_files=$(echo "$all_files" | sed -n 's|.*_\([0-9]\{8\}_[0-9]\{6\}\)\..*|\1 &|p' | sort -k1,1r)
                        files_to_delete=$(echo "$sorted_files" | awk -v keep="$REMOTE_KEEP_N" 'NR > keep { $1=""; print $0 }' | sed 's|^ ||')
                        log "FTP 待删除旧备份文件: $files_to_delete"
                        if [ -n "$files_to_delete" ]; then
                            for old_file in $files_to_delete; do
                                lftp -u "$username,$password" "$host" -e "rm $path_part/$old_file; bye" >"$TEMP_LOG" 2>&1
                                if [ $? -eq 0 ]; then echo -e "\033[32m✔ 删除旧文件: $old_file\033[0m"; log "FTP 旧备份删除成功: $old_file"; else echo -e "\033[33m⚠ 删除旧文件失败: $old_file\033[0m"; log "FTP 旧备份删除失败: $(cat "$TEMP_LOG")"; fi
                            done
                        else echo -e "\033[32m✔ 无旧备份需要清理\033[0m"; log "FTP 无旧备份需要清理"; fi
                    else echo -e "\033[33m⚠ 无法获取 FTP 文件列表，跳过清理\033[0m"; log "FTP 获取文件列表失败: $(cat "$TEMP_LOG")"; fi
                else echo -e "\033[33m⚠ FTP 清理需要 lftp，跳过清理\033[0m"; log "FTP 清理需要 lftp，未安装"; fi
            else echo -e "\033[33mℹ️  跳过 FTP 旧备份清理 (保留份数=0)\033[0m"; log "跳过 FTP 清理 (保留份数=0)"; fi
            rm -f "$TEMP_LOG"
            ;;
        local)
            if [[ "$LOCAL_KEEP_N" -gt 0 ]]; then
                echo -e "\033[36m正在清理本地旧备份 (保留最近 $LOCAL_KEEP_N 份)...\033[0m"
                all_files=$(find "$target" -maxdepth 1 -type f \( -name "*.tar.gz" -o -name "*.sql.gz" \) -not -name "$filename" -printf '%T@ %p\n')
                if [ -n "$all_files" ]; then
                    files_to_delete=$(echo "$all_files" | sort -k1,1nr | awk -v keep="$LOCAL_KEEP_N" 'NR > keep { $1=""; print $0 }' | sed 's|^ ||')
                    log "本地待删除旧备份文件: $files_to_delete"
                    if [ -n "$files_to_delete" ]; then
                        for old_file in $files_to_delete; do
                            rm -f "$old_file"
                            if [ $? -eq 0 ]; then echo -e "\033[32m✔ 删除旧文件: $old_file\033[0m"; log "本地旧备份删除成功: $old_file"; else echo -e "\033[33m⚠ 删除旧文件失败: $old_file\033[0m"; log "本地旧备份删除失败: $old_file"; fi
                        done
                    else echo -e "\033[32m✔ 无旧备份需要清理\033[0m"; log "本地无旧备份需要清理"; fi
                else echo -e "\033[32m✔ 未找到旧备份文件\033[0m"; log "本地未找到旧备份文件"; fi
            else echo -e "\033[33mℹ️  跳过本地旧备份清理 (保留份数=0)\033[0m"; log "跳过本地清理 (保留份数=0)"; fi
            ;;
        scp|rsync)
            echo -e "\033[33m⚠ $protocol 暂不支持自动清理旧备份，请手动管理远端文件\033[0m"
            log "$protocol 不支持自动清理旧备份"
            ;;
    esac

    echo -e "\033[36m正在上传 '$filename' 到 '$url' (协议: $protocol)...\033[0m"
    case $protocol in
        webdav)
            curl -u "$username:$password" -T "$file" "$url" -v >"$TEMP_LOG" 2>&1
            curl_status=$?
            log "curl 上传返回码: $curl_status"
            if [ $curl_status -eq 0 ]; then
                curl -u "$username:$password" -I "$url" >"$TEMP_LOG" 2>&1
                if grep -q "HTTP/[0-9.]* 20[0-1]" "$TEMP_LOG"; then
                    echo -e "\033[32m✔ 上传成功: $url\033[0m"; log "备份上传成功: $url"; rm -f "$file"; rm -f "$TEMP_LOG"; return 0
                else echo -e "\033[31m✗ 上传失败：服务器未确认文件存在\033[0m"; echo "服务器响应：$(cat "$TEMP_LOG")"; log "备份上传失败: 服务器未确认文件存在"; rm -f "$TEMP_LOG"; return 1; fi
            else echo -e "\033[31m✗ 上传失败：\033[0m"; echo "服务器响应：$(cat "$TEMP_LOG")"; log "备份上传失败: $(cat "$TEMP_LOG")"; rm -f "$TEMP_LOG"; return 1; fi
            ;;
        ftp)
            if command -v lftp >/dev/null; then
                lftp -u "$username,$password" "$host" -e "cd $path_part; put '$file' -o '$filename'; bye" >"$TEMP_LOG" 2>&1
                if [ $? -eq 0 ]; then echo -e "\033[32m✔ 上传成功: $url\033[0m"; log "备份上传成功: $url"; rm -f "$file"; rm -f "$TEMP_LOG"; return 0
                else echo -e "\033[31m✗ 上传失败：\033[0m"; echo "服务器响应：$(cat "$TEMP_LOG")"; log "备份上传失败: $(cat "$TEMP_LOG")"; rm -f "$TEMP_LOG"; return 1; fi
            else echo -e "\033[31m✗ FTP 上传需要 lftp，未安装\033[0m"; log "FTP 上传失败: lftp 未安装"; return 1; fi
            ;;
        sftp)
            if [[ -f "$password" ]]; then echo "put '$file' '$path_part/$filename'" | sftp -i "$password" "$username@$host" >"$TEMP_LOG" 2>&1
            elif [[ -n "$password" ]] && command -v sshpass >/dev/null; then echo "put '$file' '$path_part/$filename'" | sshpass -p "$password" sftp "$username@$host" >"$TEMP_LOG" 2>&1
            else echo "put '$file' '$path_part/$filename'" | sftp "$username@$host" >"$TEMP_LOG" 2>&1; fi
            if [ $? -eq 0 ]; then echo -e "\033[32m✔ 上传成功: $url\033[0m"; log "备份上传成功: $url"; rm -f "$file"; rm -f "$TEMP_LOG"; return 0
            else echo -e "\033[31m✗ 上传失败：\033[0m"; echo "服务器响应：$(cat "$TEMP_LOG")"; log "备份上传失败: $(cat "$TEMP_LOG")"; rm -f "$TEMP_LOG"; return 1; fi
            ;;
        scp)
            if [[ -f "$password" ]]; then scp -i "$password" "$file" "$username@$host:$path_part/$filename" >"$TEMP_LOG" 2>&1
            elif [[ -n "$password" ]] && command -v sshpass >/dev/null; then sshpass -p "$password" scp "$file" "$username@$host:$path_part/$filename" >"$TEMP_LOG" 2>&1
            else scp "$file" "$username@$host:$path_part/$filename" >"$TEMP_LOG" 2>&1; fi
            if [ $? -eq 0 ]; then echo -e "\033[32m✔ 上传成功: $url\033[0m"; log "备份上传成功: $url"; rm -f "$file"; rm -f "$TEMP_LOG"; return 0
            else echo -e "\033[31m✗ 上传失败：\033[0m"; echo "服务器响应：$(cat "$TEMP_LOG")"; log "备份上传失败: $(cat "$TEMP_LOG")"; rm -f "$TEMP_LOG"; return 1; fi
            ;;
        rsync)
            if [[ -f "$password" ]]; then rsync -az -e "ssh -i '$password'" "$file" "$username@$host:$path_part/$filename" >"$TEMP_LOG" 2>&1
            elif [[ -n "$password" ]] && command -v sshpass >/dev/null; then rsync -az -e "sshpass -p '$password' ssh" "$file" "$username@$host:$path_part/$filename" >"$TEMP_LOG" 2>&1
            else rsync -az "$file" "$username@$host:$path_part/$filename" >"$TEMP_LOG" 2>&1; fi
            if [ $? -eq 0 ]; then echo -e "\033[32m✔ 上传成功: $url\033[0m"; log "备份上传成功: $url"; rm -f "$file"; rm -f "$TEMP_LOG"; return 0
            else echo -e "\033[31m✗ 上传失败：\033[0m"; echo "服务器响应：$(cat "$TEMP_LOG")"; log "备份上传失败: $(cat "$TEMP_LOG")"; rm -f "$TEMP_LOG"; return 1; fi
            ;;
        local)
            mkdir -p "$target"
            mv "$file" "$url"
            if [ $? -eq 0 ]; then echo -e "\033[32m✔ 本地备份成功: $url\033[0m"; log "本地备份成功: $url"; return 0
            else echo -e "\033[31m✗ 本地备份失败\033[0m"; log "本地备份失败"; return 1; fi
            ;;
    esac
}

add_cron_job() {
    local temp_backup_file="$1" target_path="$2" username="$3" password="$4" cron_cmd_base="$5"
    local backup_filename protocol host path_part target_clean url minute hour cron_day final_cron_cmd
    backup_filename=$(basename "$temp_backup_file")
    if [[ -n "$password" ]]; then echo -e "\033[31m警告：密码/密钥将明文写入Cron文件($BACKUP_CRON)，存在安全风险！\033[0m"; read -p "确认继续?(y/N): " confirm_pass; if [[ "$confirm_pass" != "y" && "$confirm_pass" != "Y" ]]; then echo "取消"; return 1; fi; fi
    target_clean="${target_path%/}"; protocol="local"; url="$target_clean/$backup_filename"; upload_cmd="mkdir -p '$target_clean' && mv '$temp_backup_file' '$url'"
    if [[ "$target_path" =~ ^https?:// ]]; then protocol="webdav"; url="$target_clean/$backup_filename"; upload_cmd="curl -sSf -u '$username:$password' -T '$temp_backup_file' '$url'";
    elif [[ "$target_path" =~ ^ftps?:// ]]; then protocol="ftp"; host=$(echo "$target_path" | sed -E 's|^ftps?://([^/]+).*|\1|'); path_part=$(echo "$target_path" | sed -E 's|^ftps?://[^/]+(/.*)?|\1|'); if command -v lftp > /dev/null; then upload_cmd="lftp -c \"set ftp:ssl-allow no; open -u '$username','$password' '$host'; cd '$path_part'; put '$temp_backup_file' -o '$backup_filename'; bye\""; else upload_cmd="echo -e 'user $username $password\\nbinary\\ncd $path_part\\nput $temp_backup_file $backup_filename\\nquit' | ftp -n '$host'"; fi;
    elif [[ "$target_path" =~ ^sftp:// ]]; then protocol="sftp"; host=$(echo "$target_path" | sed -E 's|^sftp://([^/]+).*|\1|'); path_part=$(echo "$target_path" | sed -E 's|^sftp://[^/]+(/.*)?|\1|'); st="$username@$host"; pc="put '$temp_backup_file' '$path_part/$backup_filename'"; qc="quit"; if [[ -f "$password" ]]; then upload_cmd="echo -e '$pc\\n$qc' | sftp -i '$password' '$st'"; elif [[ -n "$password" ]] && command -v sshpass > /dev/null; then upload_cmd="echo -e '$pc\\n$qc' | sshpass -p '$password' sftp '$st'"; elif [[ -n "$password" ]]; then echo "sshpass needed"; return 1; else upload_cmd="echo -e '$pc\\n$qc' | sftp '$st'"; fi;
    elif [[ "$target_path" =~ ^scp:// ]]; then protocol="scp"; uph=$(echo "$target_path" | sed 's|^scp://||'); host=$(echo "$uph" | cut -d: -f1); path_part=$(echo "$uph" | cut -d: -f2); [ -z "$path_part" ] && path_part="."; st="$username@$host:'$path_part/$backup_filename'"; if [[ -f "$password" ]]; then upload_cmd="scp -i '$password' '$temp_backup_file' '$st'"; elif [[ -n "$password" ]] && command -v sshpass > /dev/null; then upload_cmd="sshpass -p '$password' scp '$temp_backup_file' '$st'"; elif [[ -n "$password" ]]; then echo "sshpass needed"; return 1; else upload_cmd="scp '$temp_backup_file' '$st'"; fi;
    elif [[ "$target_path" =~ ^rsync:// ]]; then protocol="rsync"; uph=$(echo "$target_path" | sed 's|^rsync://||'); host=$(echo "$uph" | cut -d: -f1); path_part=$(echo "$uph" | cut -d: -f2); [ -z "$path_part" ] && path_part="."; rt="$username@$host:'$path_part/$backup_filename'"; ro="-az"; sshc="ssh"; if [[ -f "$password" ]]; then sshc="ssh -i \'$password\'"; elif [[ -n "$password" ]] && command -v sshpass > /dev/null; then sshc="sshpass -p \'$password\' ssh"; elif [[ -n "$password" ]]; then echo "sshpass needed"; return 1; fi; upload_cmd="rsync $ro -e \"$sshc\" '$temp_backup_file' '$rt'";
    elif [[ ! "$target_path" =~ ^/ ]]; then echo "Cron不支持相对路径"; return 1; fi;
    echo "设置频率:"; echo " *每天, */2隔天, 0-6周几(0=日), 1,3,5周一三五"; read -p "Cron星期字段(*或1或1,5): " cron_day; read -p "运行小时(0-23): " hour; read -p "运行分钟(0-59)[0]: " minute; minute=${minute:-0};
    validate_numeric "$hour" "小时" || return 1; validate_numeric "$minute" "分钟" || return 1;
    if [[ "$cron_day" != "*" && "$cron_day" != "*/2" && ! "$cron_day" =~ ^([0-6](,[0-6])*)$ ]]; then echo "星期无效"; return 1; fi;
    local rm_cmd="rm -f '$temp_backup_file'";
    final_cron_cmd="bash -c \"{ ( $cron_cmd_base $upload_cmd && $rm_cmd && echo \\\$(date '+%Y-%m-%d %H:%M:%S') - Cron SUCCESS: $backup_filename >> $LOG_FILE ) || echo \\\$(date '+%Y-%m-%d %H:%M:%S') - Cron FAILED: $backup_filename >> $LOG_FILE ; } 2>&1 | tee -a $LOG_FILE\"";
    touch "$BACKUP_CRON" && chmod 644 "$BACKUP_CRON"
    echo "$minute $hour * * $cron_day root $final_cron_cmd" >> "$BACKUP_CRON";
    if [ $? -ne 0 ]; then echo "写入 $BACKUP_CRON 失败"; return 1; fi;
    echo "✅ 任务已添加到 $BACKUP_CRON"; log "备份任务已计划: $minute $hour * * $cron_day ($protocol)"
}