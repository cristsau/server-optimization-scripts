#!/bin/bash
# lib_backup.sh - Backup functions

# --- Robustness Settings ---
set -uo pipefail

# --- Variables & Source ---
# Assume global vars: CONFIG_FILE, BACKUP_CRON, TEMP_LOG, LOG_FILE, SCRIPT_DIR are accessible
# shellcheck source=./lib_utils.sh
source "$SCRIPT_DIR/lib_utils.sh" # For log, clear_cmd, validation helpers etc.
# shellcheck source=./lib_config.sh
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

# Enhanced Upload Backup with "Keep N" Cleanup
upload_backup() {
    local file="$1" target="$2" username="$3" password="$4"
    local filename=$(basename "$file") protocol url host path_part

    # 参数校验
    if [ -z "$file" ] || [ ! -f "$file" ]; then
        log "错误: upload_backup 无效源文件 $file"
        return 1
    fi
    if [ -z "$target" ]; then
        log "错误: upload_backup 无效目标路径"
        return 1
    fi

    # 协议解析
    if [[ "$target" =~ ^https?:// ]]; then
        protocol="webdav"
        url="${target%/}/$filename"
    elif [[ "$target" =~ ^ftps?:// ]]; then
        protocol="ftp"
        host=$(echo "$target" | sed -E 's|^ftps?://([^/]+).*|\1|')
        path_part=$(echo "$target" | sed -E 's|^ftps?://[^/]+(/.*)?|\1|')
        url="${target%/}/$filename"
    elif [[ "$target" =~ ^sftp:// ]]; then
        protocol="sftp"
        host=$(echo "$target" | sed -E 's|^sftp://([^/]+).*|\1|')
        path_part=$(echo "$target" | sed -E 's|^sftp://[^/]+(/.*)?|\1|')
        url="${target%/}/$filename"
        if [[ -z "$username" && "$host" =~ .*@.* ]]; then
            username=$(echo "$host" | cut -d@ -f1)
            host=$(echo "$host" | cut -d@ -f2)
        fi
    elif [[ "$target" =~ ^scp:// ]]; then
        protocol="scp"
        host=$(echo "$target" | sed -E 's|^scp://([^/]+).*|\1|')
        path_part=$(echo "$target" | sed -E 's|^scp://[^/]+(/.*)?|\1|')
        url="${target%/}/$filename"
        if [[ -z "$username" && "$host" =~ .*@.* ]]; then
            username=$(echo "$host" | cut -d@ -f1)
            host=$(echo "$host" | cut -d@ -f2)
        fi
    elif [[ "$target" =~ ^rsync:// ]]; then
        protocol="rsync"
        host=$(echo "$target" | sed -E 's|^rsync://([^/]+).*|\1|')
        path_part=$(echo "$target" | sed -E 's|^rsync://[^/]+(/.*)?|\1|')
        url="${target%/}/$filename"
        if [[ -z "$username" && "$host" =~ .*@.* ]]; then
            username=$(echo "$host" | cut -d@ -f1)
            host=$(echo "$host" | cut -d@ -f2)
        fi
    elif [[ "$target" =~ ^/ ]]; then
        protocol="local"
        url="$target/$filename"
    else
        echo -e "\033[31m✗ 不支持的目标路径格式: $target\033[0m"
        log "不支持的目标路径格式: $target"
        return 1
    fi
    log "准备上传 '$filename' 到 '$target' (协议: $protocol)"

    # 检查备份工具
    if [ "$protocol" != "local" ]; then
        check_backup_tools "$protocol" || return 1
    fi

    # 加载保留天数配置（与原始脚本一致）
    local LOCAL_KEEP_N=${LOCAL_RETENTION_DAYS:-1}  # 默认保留 1 个本地文件
    local REMOTE_KEEP_N=${REMOTE_RETENTION_DAYS:-1}  # 默认保留 1 个远程文件
    [[ "$LOCAL_KEEP_N" -lt 0 ]] && LOCAL_KEEP_N=0
    [[ "$REMOTE_KEEP_N" -lt 0 ]] && REMOTE_KEEP_N=0
    log "保留配置: 本地保留 $LOCAL_KEEP_N 个, 远程保留 $REMOTE_KEEP_N 个"

    # 清理旧备份
    case $protocol in
        webdav)
            if [[ "$REMOTE_KEEP_N" -gt 0 ]]; then
                echo -e "\033[36m正在清理 WebDAV 旧备份 (保留最近 $REMOTE_KEEP_N 份)...\033[0m"
                curl -u "$username:$password" -X PROPFIND "${target%/}" -H "Depth: 1" >"$TEMP_LOG" 2>&1
                if [ $? -eq 0 ] && [ -s "$TEMP_LOG" ]; then
                    # 提取文件列表
                    if command -v grep >/dev/null 2>&1 && grep -P "" /dev/null >/dev/null 2>&1; then
                        all_files=$(grep -oP '(?<=<D:href>).*?(?=</D:href>)' "$TEMP_LOG" | grep -E '\.(tar\.gz|sql\.gz)$')
                    else
                        all_files=$(grep '<D:href>' "$TEMP_LOG" | sed 's|.*<D:href>\(.*\)</D:href>.*|\1|' | grep -E '\.(tar\.gz|sql\.gz)$')
                    fi
                    log "WebDAV 提取的所有备份文件路径: $all_files"

                    # 按时间戳排序并筛选旧文件
                    sorted_files=$(echo "$all_files" | sed -n 's|.*/[^_]*_\([0-9]\{8\}_[0-9]\{6\}\)\..*|\1 &|p' | sort -k1,1r)
                    files_to_delete=$(echo "$sorted_files" | awk -v keep="$REMOTE_KEEP_N" 'NR > keep { $1=""; print $0 }' | sed 's|^ ||')
                    log "WebDAV 待删除旧备份文件: $files_to_delete"

                    if [ -n "$files_to_delete" ]; then
                        for old_file in $files_to_delete; do
                            delete_url="${target%/}/${old_file##*/}"
                            log "尝试删除 WebDAV 文件: $delete_url"
                            curl -u "$username:$password" -X DELETE "$delete_url" >"$TEMP_LOG" 2>&1
                            if [ $? -eq 0 ]; then
                                echo -e "\033[32m✔ 删除旧文件: $delete_url\033[0m"
                                log "WebDAV 旧备份删除成功: $delete_url"
                            else
                                echo -e "\033[31m✗ 删除旧文件失败: $delete_url\033[0m"
                                echo "服务器响应：$(cat "$TEMP_LOG")"
                                log "WebDAV 旧备份删除失败: $(cat "$TEMP_LOG")"
                            fi
                        done
                    else
                        echo -e "\033[32m✔ 无旧备份需要清理\033[0m"
                        log "WebDAV 无旧备份需要清理"
                    fi
                else
                    echo -e "\033[31m✗ 无法获取 WebDAV 文件列表\033[0m"
                    echo "服务器响应：$(cat "$TEMP_LOG")"
                    log "WebDAV 获取文件列表失败: $(cat "$TEMP_LOG")"
                fi
            else
                echo -e "\033[33mℹ️  跳过 WebDAV 旧备份清理 (保留份数=0)\033[0m"
                log "跳过 WebDAV 清理 (保留份数=0)"
            fi
            rm -f "$TEMP_LOG"
            ;;
        sftp)
            if [[ "$REMOTE_KEEP_N" -gt 0 ]]; then
                echo -e "\033[36m正在清理 SFTP 旧备份 (保留最近 $REMOTE_KEEP_N 份)...\033[0m"
                if [[ -f "$password" ]]; then
                    echo "ls -l" | sftp -i "$password" "$username@$host" >"$TEMP_LOG" 2>&1
                elif [[ -n "$password" ]] && command -v sshpass >/dev/null; then
                    echo "ls -l" | sshpass -p "$password" sftp "$username@$host" >"$TEMP_LOG" 2>&1
                else
                    echo "ls -l" | sftp "$username@$host" >"$TEMP_LOG" 2>&1
                fi
                if [ $? -eq 0 ]; then
                    all_files=$(grep -E '\.(tar\.gz|sql\.gz)$' "$TEMP_LOG" | awk '{print $NF}')
                    sorted_files=$(echo "$all_files" | sed -n 's|.*_\([0-9]\{8\}_[0-9]\{6\}\)\..*|\1 &|p' | sort -k1,1r)
                    files_to_delete=$(echo "$sorted_files" | awk -v keep="$REMOTE_KEEP_N" 'NR > keep { $1=""; print $0 }' | sed 's|^ ||')
                    log "SFTP 待删除旧备份文件: $files_to_delete"
                    if [ -n "$files_to_delete" ]; then
                        for old_file in $files_to_delete; do
                            if [[ -f "$password" ]]; then
                                echo "rm $path_part/$old_file" | sftp -i "$password" "$username@$host" >"$TEMP_LOG" 2>&1
                            elif [[ -n "$password" ]] && command -v sshpass >/dev/null; then
                                echo "rm $path_part/$old_file" | sshpass -p "$password" sftp "$username@$host" >"$TEMP_LOG" 2>&1
                            else
                                echo "rm $path_part/$old_file" | sftp "$username@$host" >"$TEMP_LOG" 2>&1
                            fi
                            if [ $? -eq 0 ]; then
                                echo -e "\033[32m✔ 删除旧文件: $old_file\033[0m"
                                log "SFTP 旧备份删除成功: $old_file"
                            else
                                echo -e "\033[33m⚠ 删除旧文件失败: $old_file\033[0m"
                                log "SFTP 旧备份删除失败: $(cat "$TEMP_LOG")"
                            fi
                        done
                    else
                        echo -e "\033[32m✔ 无旧备份需要清理\033[0m"
                        log "SFTP 无旧备份需要清理"
                    fi
                else
                    echo -e "\033[33m⚠ 无法获取 SFTP 文件列表，跳过清理\033[0m"
                    log "SFTP 获取文件列表失败: $(cat "$TEMP_LOG")"
                fi
            else
                echo -e "\033[33mℹ️  跳过 SFTP 旧备份清理 (保留份数=0)\033[0m"
                log "跳过 SFTP 清理 (保留份数=0)"
            fi
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
                                if [ $? -eq 0 ]; then
                                    echo -e "\033[32m✔ 删除旧文件: $old_file\033[0m"
                                    log "FTP 旧备份删除成功: $old_file"
                                else
                                    echo -e "\033[33m⚠ 删除旧文件失败: $old_file\033[0m"
                                    log "FTP 旧备份删除失败: $(cat "$TEMP_LOG")"
                                fi
                            done
                        else
                            echo -e "\033[32m✔ 无旧备份需要清理\033[0m"
                            log "FTP 无旧备份需要清理"
                        fi
                    else
                        echo -e "\033[33m⚠ 无法获取 FTP 文件列表，跳过清理\033[0m"
                        log "FTP 获取文件列表失败: $(cat "$TEMP_LOG")"
                    fi
                else
                    echo -e "\033[33m⚠ FTP 清理需要 lftp，跳过清理\033[0m"
                    log "FTP 清理需要 lftp，未安装"
                fi
            else
                echo -e "\033[33mℹ️  跳过 FTP 旧备份清理 (保留份数=0)\033[0m"
                log "跳过 FTP 清理 (保留份数=0)"
            fi
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
                            if [ $? -eq 0 ]; then
                                echo -e "\033[32m✔ 删除旧文件: $old_file\033[0m"
                                log "本地旧备份删除成功: $old_file"
                            else
                                echo -e "\033[33m⚠ 删除旧文件失败: $old_file\033[0m"
                                log "本地旧备份删除失败: $old_file"
                            fi
                        done
                    else
                        echo -e "\033[32m✔ 无旧备份需要清理\033[0m"
                        log "本地无旧备份需要清理"
                    fi
                else
                    echo -e "\033[32m✔ 未找到旧备份文件\033[0m"
                    log "本地未找到旧备份文件"
                fi
            else
                echo -e "\033[33mℹ️  跳过本地旧备份清理 (保留份数=0)\033[0m"
                log "跳过本地清理 (保留份数=0)"
            fi
            ;;
        scp|rsync)
            echo -e "\033[33m⚠ $protocol 暂不支持自动清理旧备份，请手动管理远端文件\033[0m"
            log "$protocol 不支持自动清理旧备份"
            ;;
    esac

    # 上传新备份
    echo -e "\033[36m正在上传 '$filename' 到 '$url' (协议: $protocol)...\033[0m"
    case $protocol in
        webdav)
            curl -u "$username:$password" -T "$file" "$url" -v >"$TEMP_LOG" 2>&1
            curl_status=$?
            log "curl 上传返回码: $curl_status"
            if [ $curl_status -eq 0 ]; then
                curl -u "$username:$password" -I "$url" >"$TEMP_LOG" 2>&1
                if grep -q "HTTP/[0-9.]* 20[0-1]" "$TEMP_LOG"; then
                    echo -e "\033[32m✔ 上传成功: $url\033[0m"
                    log "备份上传成功: $url"
                    rm -f "$file"
                    rm -f "$TEMP_LOG"
                    return 0
                else
                    echo -e "\033[31m✗ 上传失败：服务器未确认文件存在\033[0m"
                    echo "服务器响应：$(cat "$TEMP_LOG")"
                    log "备份上传失败: 服务器未确认文件存在"
                    rm -f "$TEMP_LOG"
                    return 1
                fi
            else
                echo -e "\033[31m✗ 上传失败：\033[0m"
                echo "服务器响应：$(cat "$TEMP_LOG")"
                log "备份上传失败: $(cat "$TEMP_LOG")"
                rm -f "$TEMP_LOG"
                return 1
            fi
            ;;
        ftp)
            if command -v lftp >/dev/null; then
                lftp -u "$username,$password" "$host" -e "cd $path_part; put '$file' -o '$filename'; bye" >"$TEMP_LOG" 2>&1
                if [ $? -eq 0 ]; then
                    echo -e "\033[32m✔ 上传成功: $url\033[0m"
                    log "备份上传成功: $url"
                    rm -f "$file"
                    rm -f "$TEMP_LOG"
                    return 0
                else
                    echo -e "\033[31m✗ 上传失败：\033[0m"
                    echo "服务器响应：$(cat "$TEMP_LOG")"
                    log "备份上传失败: $(cat "$TEMP_LOG")"
                    rm -f "$TEMP_LOG"
                    return 1
                fi
            else
                echo -e "\033[31m✗ FTP 上传需要 lftp，未安装\033[0m"
                log "FTP 上传失败: lftp 未安装"
                return 1
            fi
            ;;
        sftp)
            if [[ -f "$password" ]]; then
                echo "put '$file' '$path_part/$filename'" | sftp -i "$password" "$username@$host" >"$TEMP_LOG" 2>&1
            elif [[ -n "$password" ]] && command -v sshpass >/dev/null; then
                echo "put '$file' '$path_part/$filename'" | sshpass -p "$password" sftp "$username@$host" >"$TEMP_LOG" 2>&1
            else
                echo "put '$file' '$path_part/$filename'" | sftp "$username@$host" >"$TEMP_LOG" 2>&1
            fi
            if [ $? -eq 0 ]; then
                echo -e "\033[32m✔ 上传成功: $url\033[0m"
                log "备份上传成功: $url"
                rm -f "$file"
                rm -f "$TEMP_LOG"
                return 0
            else
                echo -e "\033[31m✗ 上传失败：\033[0m"
                echo "服务器响应：$(cat "$TEMP_LOG")"
                log "备份上传失败: $(cat "$TEMP_LOG")"
                rm -f "$TEMP_LOG"
                return 1
            fi
            ;;
        scp)
            if [[ -f "$password" ]]; then
                scp -i "$password" "$file" "$username@$host:$path_part/$filename" >"$TEMP_LOG" 2>&1
            elif [[ -n "$password" ]] && command -v sshpass >/dev/null; then
                sshpass -p "$password" scp "$file" "$username@$host:$path_part/$filename" >"$TEMP_LOG" 2>&1
            else
                scp "$file" "$username@$host:$path_part/$filename" >"$TEMP_LOG" 2>&1
            fi
            if [ $? -eq 0 ]; then
                echo -e "\033[32m✔ 上传成功: $url\033[0m"
                log "备份上传成功: $url"
                rm -f "$file"
                rm -f "$TEMP_LOG"
                return 0
            else
                echo -e "\033[31m✗ 上传失败：\033[0m"
                echo "服务器响应：$(cat "$TEMP_LOG")"
                log "备份上传失败: $(cat "$TEMP_LOG")"
                rm -f "$TEMP_LOG"
                return 1
            fi
            ;;
        rsync)
            if [[ -f "$password" ]]; then
                rsync -az -e "ssh -i '$password'" "$file" "$username@$host:$path_part/$filename" >"$TEMP_LOG" 2>&1
            elif [[ -n "$password" ]] && command -v sshpass >/dev/null; then
                rsync -az -e "sshpass -p '$password' ssh" "$file" "$username@$host:$path_part/$filename" >"$TEMP_LOG" 2>&1
            else
                rsync -az "$file" "$username@$host:$path_part/$filename" >"$TEMP_LOG" 2>&1
            fi
            if [ $? -eq 0 ]; then
                echo -e "\033[32m✔ 上传成功: $url\033[0m"
                log "备份上传成功: $url"
                rm -f "$file"
                rm -f "$TEMP_LOG"
                return 0
            else
                echo -e "\033[31m✗ 上传失败：\033[0m"
                echo "服务器响应：$(cat "$TEMP_LOG")"
                log "备份上传失败: $(cat "$TEMP_LOG")"
                rm -f "$TEMP_LOG"
                return 1
            fi
            ;;
        local)
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
}


# 添加 Cron 任务
add_cron_job() {
   local temp_backup_file="$1" target_path="$2" username="$3" password="$4" cron_cmd_base="$5"
   local backup_filename protocol host path_part target_clean url minute hour cron_day final_cron_cmd
   backup_filename=$(basename "$temp_backup_file")
   if [[ -n "$password" ]]; then echo -e "\033[31m警告：密码/密钥将明文写入Cron文件($BACKUP_CRON)，存在安全风险！\033[0m"; read -p "确认继续?(y/N): " confirm_pass; if [[ "$confirm_pass" != "y" && "$confirm_pass" != "Y" ]]; then echo "取消"; return 1; fi; fi
   # Build upload_cmd logic
   target_clean="${target_path%/}"; protocol="local"; url="$target_clean/$backup_filename"; upload_cmd="mkdir -p '$target_clean' && mv '$temp_backup_file' '$url'"
   if [[ "$target_path" =~ ^https?:// ]]; then protocol="webdav"; url="$target_clean/$backup_filename"; upload_cmd="curl -sSf -u '$username:$password' -T '$temp_backup_file' '$url'";
   elif [[ "$target_path" =~ ^ftps?:// ]]; then protocol="ftp"; host=$(echo "$target_path" | sed -E 's|^ftps?://([^/]+).*|\1|'); path_part=$(echo "$target_path" | sed -E 's|^ftps?://[^/]+(/.*)?|\1|'); if command -v lftp > /dev/null; then upload_cmd="lftp -c \"set ftp:ssl-allow no; open -u '$username','$password' '$host'; cd '$path_part'; put '$temp_backup_file' -o '$backup_filename'; bye\""; else upload_cmd="echo -e 'user $username $password\\nbinary\\ncd $path_part\\nput $temp_backup_file $backup_filename\\nquit' | ftp -n '$host'"; fi;
   elif [[ "$target_path" =~ ^sftp:// ]]; then protocol="sftp"; host=$(echo "$target_path" | sed -E 's|^sftp://([^/]+).*|\1|'); path_part=$(echo "$target_path" | sed -E 's|^sftp://[^/]+(/.*)?|\1|'); st="$username@$host"; pc="put '$temp_backup_file' '$path_part/$backup_filename'"; qc="quit"; if [[ -f "$password" ]]; then upload_cmd="echo -e '$pc\\n$qc' | sftp -i '$password' '$st'"; elif [[ -n "$password" ]] && command -v sshpass > /dev/null; then upload_cmd="echo -e '$pc\\n$qc' | sshpass -p '$password' sftp '$st'"; elif [[ -n "$password" ]]; then echo "sshpass needed"; return 1; else upload_cmd="echo -e '$pc\\n$qc' | sftp '$st'"; fi;
   elif [[ "$target_path" =~ ^scp:// ]]; then protocol="scp"; uph=$(echo "$target_path" | sed 's|^scp://||'); host=$(echo "$uph" | cut -d: -f1); path_part=$(echo "$uph" | cut -d: -f2); [ -z "$path_part" ] && path_part="."; st="$username@$host:'$path_part/$backup_filename'"; if [[ -f "$password" ]]; then upload_cmd="scp -i '$password' '$temp_backup_file' '$st'"; elif [[ -n "$password" ]] && command -v sshpass > /dev/null; then upload_cmd="sshpass -p '$password' scp '$temp_backup_file' '$st'"; elif [[ -n "$password" ]]; then echo "sshpass needed"; return 1; else upload_cmd="scp '$temp_backup_file' '$st'"; fi;
   elif [[ "$target_path" =~ ^rsync:// ]]; then protocol="rsync"; uph=$(echo "$target_path" | sed 's|^rsync://||'); host=$(echo "$uph" | cut -d: -f1); path_part=$(echo "$uph" | cut -d: -f2); [ -z "$path_part" ] && path_part="."; rt="$username@$host:'$path_part/$backup_filename'"; ro="-az"; sshc="ssh"; if [[ -f "$password" ]]; then sshc="ssh -i \'$password\'"; elif [[ -n "$password" ]] && command -v sshpass > /dev/null; then sshc="sshpass -p \'$password\' ssh"; elif [[ -n "$password" ]]; then echo "sshpass needed"; return 1; fi; upload_cmd="rsync $ro -e \"$sshc\" '$temp_backup_file' '$rt'";
   elif [[ ! "$target_path" =~ ^/ ]]; then echo "Cron不支持相对路径"; return 1; fi;
   # Get Cron Time
   echo "设置频率:"; echo " *每天, */2隔天, 0-6周几(0=日), 1,3,5周一三五"; read -p "Cron星期字段(*或1或1,5): " cron_day; read -p "运行小时(0-23): " hour; read -p "运行分钟(0-59)[0]: " minute; minute=${minute:-0};
   validate_numeric "$hour" "小时" || return 1; validate_numeric "$minute" "分钟" || return 1;
   if [[ "$cron_day" != "*" && "$cron_day" != "*/2" && ! "$cron_day" =~ ^([0-6](,[0-6])*)$ ]]; then echo "星期无效"; return 1; fi;
   # Combine and Add Cron Job
   local rm_cmd="rm -f '$temp_backup_file'"; # Always remove temp file after attempt in cron
   final_cron_cmd="bash -c \"{ ( $cron_cmd_base $upload_cmd && $rm_cmd && echo \\\$(date '+%Y-%m-%d %H:%M:%S') - Cron SUCCESS: $backup_filename >> $LOG_FILE ) || echo \\\$(date '+%Y-%m-%d %H:%M:%S') - Cron FAILED: $backup_filename >> $LOG_FILE ; } 2>&1 | tee -a $LOG_FILE\"";
   touch "$BACKUP_CRON" && chmod 644 "$BACKUP_CRON"
   echo "$minute $hour * * $cron_day root $final_cron_cmd" >> "$BACKUP_CRON";
   if [ $? -ne 0 ]; then echo "写入 $BACKUP_CRON 失败"; return 1; fi;
   echo "✅ 任务已添加到 $BACKUP_CRON"; log "添加备份Cron: $minute $hour * * $cron_day - $backup_filename"; return 0;
}

# --- Full Backup Menu Helper Functions ---
ManualBackupData() {
  echo -e "\033[36m▶ 手动备份程序数据...\033[0m"; log "手动备份数据开始..."
  read -p "源路径: " source_path
  read -e -p "目标路径: " target_path
  read -p "目标用户(可选): " username
  local password=""
  if [ -n "$username" ]; then read -s -p "密码/密钥路径(可选): " password; echo; fi
  validate_path_exists "$source_path" "e" || return 1
  local timestamp source_basename backup_file tar_status
  timestamp=$(date '+%Y%m%d_%H%M%S'); source_basename=$(basename "$source_path"); backup_file="/tmp/backup_${source_basename}_$timestamp.tar.gz"
  echo "压缩 '$source_path' -> '$backup_file' ...";
  tar -czf "$backup_file" -C "$(dirname "$source_path")" "$source_basename" 2>"$TEMP_LOG"
  tar_status=$?
  if [ $tar_status -eq 0 ] && [ -s "$backup_file" ]; then
    echo "压缩成功"; upload_backup "$backup_file" "$target_path" "$username" "$password"
    if [ $? -eq 0 ]; then echo "✅ 备份上传成功"; log "手动数据备份成功: $source_path -> $target_path"; return 0;
    else echo "❌ 上传失败"; log "手动数据备份失败(上传): $source_path -> $target_path"; rm -f "$backup_file"; return 1; fi
  else
    echo "❌ 压缩失败(码:$tar_status)"; cat "$TEMP_LOG"; log "手动数据备份失败(压缩): $source_path Error: $(cat "$TEMP_LOG")"; rm -f "$backup_file"; return 1;
  fi; rm -f "$TEMP_LOG"
}
ManualBackupDB() {
  echo -e "\033[36m▶ 手动备份数据库...\033[0m"; log "手动备份数据库开始..."
  local db_type db_host db_port db_user db_pass target_path username password backup_failed=false default_port
  # Use loaded config or prompt
  if ! load_config; then # Uses corrected load_config
      echo "未加载配置,请手动输入"; read -p "类型(mysql/postgres): " db_type; case "$db_type" in mysql) default_port=3306;; postgres) default_port=5432;; *) echo "类型错误"; return 1;; esac; read -p "主机(127.0.0.1): " db_host; db_host=${db_host:-127.0.0.1}; read -p "端口[$default_port]: " db_port; db_port=${db_port:-$default_port}; validate_numeric "$db_port" "端口" || return 1; read -p "用户: " db_user; read -s -p "密码: " db_pass; echo; read -e -p "目标路径: " target_path; read -p "目标用户(可选): " username; if [ -n "$username" ]; then read -s -p "目标密码/密钥(可选): " password; echo; fi;
  else echo "✅ 已加载配置"; # Variables DB_TYPE etc are exported by load_config now
     # Assign exported vars to local scope if needed, or just use them directly if exported
     db_type=$DB_TYPE; db_host=$DB_HOST; db_port=$DB_PORT; db_user=$DB_USER; db_pass=$DB_PASS; target_path=$TARGET_PATH; username=$TARGET_USER; password=$TARGET_PASS;
  fi
  # Validate essentials
  if [[ "$db_type" != "mysql" && "$db_type" != "postgres" ]]; then echo "类型错误"; return 1; fi; install_db_client "$db_type" || return 1;
  if [[ -z "$db_host" || -z "$db_port" || -z "$db_user" || -z "$target_path" ]]; then echo "数据库/目标路径信息不全"; return 1; fi;

  echo "测试连接..."; local connection_ok=false; if [ "$db_type" = "mysql" ]; then echo "SHOW DATABASES;" | mysql -h "$db_host" -P "$db_port" -u "$db_user" -p"$db_pass" --connect-timeout=5 >"$TEMP_LOG" 2>&1; [ $? -eq 0 ] && connection_ok=true || cat "$TEMP_LOG" >&2; elif [ "$db_type" = "postgres" ]; then export PGPASSWORD="$db_pass"; echo "SELECT 1;" | psql -h "$db_host" -p "$db_port" -U "$db_user" -d "postgres" -t --command="SELECT 1" >"$TEMP_LOG" 2>&1; [ $? -eq 0 ] && grep -q "1" "$TEMP_LOG" && connection_ok=true || cat "$TEMP_LOG" >&2; unset PGPASSWORD; fi;
  if ! $connection_ok; then echo "❌ 连接失败"; log "DB连接失败"; rm -f "$TEMP_LOG"; return 1; fi; echo "✅ 连接成功"; rm -f "$TEMP_LOG";
  read -p "备份所有数据库?(y/n/a)[y]: " backup_scope; backup_scope=${backup_scope:-y}; local db_list="";
  if [[ "$backup_scope" == "y" || "$backup_scope" == "Y" ]]; then db_list="all"; elif [[ "$backup_scope" == "n" || "$backup_scope" == "N" ]]; then read -p "输入DB名(空格分隔): " db_names; if [ -z "$db_names" ]; then echo "未输入"; return 1; fi; db_list="$db_names"; else return 0; fi;
  local timestamp; timestamp=$(date '+%Y%m%d_%H%M%S');
  if [ "$db_list" = "all" ]; then
     local backup_file="/tmp/all_dbs_${db_type}_$timestamp.sql.gz"; echo "备份所有..."; local dump_cmd dump_status
     if [ "$db_type" = "mysql" ]; then dump_cmd="mysqldump -h \"$db_host\" -P \"$db_port\" -u \"$db_user\" -p\"$db_pass\" --all-databases --routines --triggers --single-transaction"; elif [ "$db_type" = "postgres" ]; then export PGPASSWORD="$db_pass"; dump_cmd="pg_dumpall -h \"$db_host\" -p \"$db_port\" -U \"$db_user\""; fi;
     eval "$dump_cmd" 2>"$TEMP_LOG" | gzip > "$backup_file"; dump_status=${PIPESTATUS[0]}; if [ "$db_type" = "postgres" ]; then unset PGPASSWORD; fi;
     if [ $dump_status -eq 0 ] && [ -s "$backup_file" ]; then echo "备份成功"; upload_backup "$backup_file" "$target_path" "$username" "$password" || backup_failed=true;
     else echo "❌ 备份失败(码:$dump_status)"; cat "$TEMP_LOG" >&2; log "备份所有DB失败: $(cat "$TEMP_LOG")"; backup_failed=true; rm -f "$backup_file"; fi;
  else
     for db_name in $db_list; do
         local backup_file="/tmp/${db_name}_${db_type}_$timestamp.sql.gz"; echo "备份 $db_name..."; local dump_cmd dump_status
         if [ "$db_type" = "mysql" ]; then dump_cmd="mysqldump -h \"$db_host\" -P \"$db_port\" -u \"$db_user\" -p\"$db_pass\" --routines --triggers --single-transaction \"$db_name\""; elif [ "$db_type" = "postgres" ]; then export PGPASSWORD="$db_pass"; dump_cmd="pg_dump -h \"$db_host\" -p \"$db_port\" -U \"$db_user\" \"$db_name\""; fi;
         eval "$dump_cmd" 2>"$TEMP_LOG" | gzip > "$backup_file"; dump_status=${PIPESTATUS[0]}; if [ "$db_type" = "postgres" ]; then unset PGPASSWORD; fi;
         if [ $dump_status -eq 0 ] && [ -s "$backup_file" ]; then echo "$db_name 备份成功"; upload_backup "$backup_file" "$target_path" "$username" "$password" || backup_failed=true;
         else echo "❌ $db_name 备份失败(码:$dump_status)"; cat "$TEMP_LOG" >&2; log "备份DB $db_name 失败: $(cat "$TEMP_LOG")"; backup_failed=true; rm -f "$backup_file"; fi;
     done
  fi; rm -f "$TEMP_LOG"; if ! $backup_failed; then echo "✅ 所有请求的备份完成"; log "手动DB备份完成"; return 0; else echo "❌ 部分备份失败"; return 1; fi
}
ManageBackupConfig() {
  log "运行备份配置管理"; echo "管理配置...";
  if [ -f "$CONFIG_FILE" ]; then echo "当前配置:"; cat "$CONFIG_FILE"; read -p "操作(e:编辑/c:重建/n:返回)[n]: " cfg_act; cfg_act=${cfg_act:-n}; if [ "$cfg_act" == "e" ]; then ${EDITOR:-nano} "$CONFIG_FILE"; elif [ "$cfg_act" == "c" ]; then create_config; fi; # Uses correct create_config
  else read -p "未找到配置,是否创建(y/N):" create_cfg; if [[ "$create_cfg" == "y" || "$create_cfg" == "Y" ]]; then create_config; fi; fi # Uses correct create_config
  return 0
}
ManageBackupCron() {
  log "运行备份 Cron 管理"; echo "管理计划...";
  echo "当前任务 (来自 $BACKUP_CRON):"; if [ -f "$BACKUP_CRON" ]; then local fc; fc=$(grep -vE '^[[:space:]]*#|^$' "$BACKUP_CRON"); if [ -n "$fc" ]; then echo "$fc" | nl; else echo "  (文件为空或只包含注释)"; fi; else echo "  (文件不存在)"; fi; echo ""; read -p "操作(a:添加/d:删除/e:编辑/n:返回)[n]: " cron_action; cron_action=${cron_action:-n}
  if [[ "$cron_action" == "a" ]]; then
      echo "添加任务..."; local backup_type backup_failed=false
      read -p "类型(1:数据/2:数据库): " backup_type; validate_numeric "$backup_type" "类型" || return 1
      if [ "$backup_type" = "1" ]; then
          read -p "源路径: " source_path; read -e -p "目标路径: " target_path; read -p "目标用户(可选): " username; local password=""; if [ -n "$username" ]; then read -s -p "密码/密钥路径(可选): " password; echo; fi;
          validate_path_exists "$source_path" "e" || return 1
          local source_basename timestamp_format backup_filename temp_backup_file tar_cmd cron_cmd_base
          source_basename=$(basename "$source_path"); timestamp_format='$(date +\%Y\%m\%d_\%H\%M\%S)'; backup_filename="backup_${source_basename}_${timestamp_format}.tar.gz"; temp_backup_file="/tmp/$backup_filename";
          tar_cmd="tar -czf '$temp_backup_file' -C '$(dirname "$source_path")' '$source_basename'"; cron_cmd_base="$tar_cmd && ";
          add_cron_job "$temp_backup_file" "$target_path" "$username" "$password" "$cron_cmd_base" || backup_failed=true;
      elif [ "$backup_type" = "2" ]; then
          if ! load_config; then echo "需先创建配置"; return 1; fi; local db_type db_host db_port db_user db_pass target_path username password; db_type=$DB_TYPE; db_host=$DB_HOST; db_port=$DB_PORT; db_user=$DB_USER; db_pass=$DB_PASS; target_path=$TARGET_PATH; username=$TARGET_USER; password=$TARGET_PASS; # Use exported vars
          install_db_client "$db_type" || return 1;
          read -p "备份所有?(y/n)[y]: " backup_scope_cron; backup_scope_cron=${backup_scope_cron:-y}; local db_list_cron="";
          if [[ "$backup_scope_cron" == "y" ]]; then db_list_cron="all";
          elif [[ "$backup_scope_cron" == "n" ]]; then read -p "输入DB名: " db_names_cron; if [ -z "$db_names_cron" ]; then echo "未输入"; return 1; fi; db_list_cron="$db_names_cron";
          else echo "无效选择"; return 1; fi;
          local timestamp_format='$(date +\%Y\%m\%d_\%H\%M\%S)'
          if [ "$db_list_cron" = "all" ]; then
              local backup_filename temp_backup_file dump_cmd cron_cmd_base
              backup_filename="all_dbs_${db_type}_${timestamp_format}.sql.gz"; temp_backup_file="/tmp/$backup_filename"; dump_cmd="";
              if [ "$db_type" = "mysql" ]; then dump_cmd="mysqldump -h '$db_host' -P '$db_port' -u '$db_user' -p'$db_pass' --all-databases --routines --triggers --single-transaction"; elif [ "$db_type" = "postgres" ]; then dump_cmd="PGPASSWORD='$db_pass' pg_dumpall -h '$db_host' -p '$db_port' -U '$db_user'"; fi;
              cron_cmd_base="$dump_cmd | gzip > '$temp_backup_file' && ";
              add_cron_job "$temp_backup_file" "$target_path" "$username" "$password" "$cron_cmd_base" || backup_failed=true;
          else
              for db_name in $db_list_cron; do
                  local backup_filename temp_backup_file dump_cmd cron_cmd_partial
                  backup_filename="${db_name}_${db_type}_${timestamp_format}.sql.gz"; temp_backup_file="/tmp/$backup_filename"; dump_cmd="";
                  if [ "$db_type" = "mysql" ]; then dump_cmd="mysqldump -h '$db_host' -P '$db_port' -u '$db_user' -p'$db_pass' --routines --triggers --single-transaction '$db_name'"; elif [ "$db_type" = "postgres" ]; then dump_cmd="PGPASSWORD='$db_pass' pg_dump -h '$db_host' -p '$db_port' -U '$db_user' '$db_name'"; fi;
                  cron_cmd_partial="$dump_cmd | gzip > '$temp_backup_file' && ";
                  add_cron_job "$temp_backup_file" "$target_path" "$username" "$password" "$cron_cmd_partial" || backup_failed=true;
              done
          fi
      else echo "类型错误"; return 1; fi;
      if ! $backup_failed; then echo "✅ Cron任务添加/更新完成"; else echo "❌ 部分Cron任务添加失败"; fi;
  elif [[ "$cron_action" == "d" ]]; then read -p "确定删除 $BACKUP_CRON 文件中的所有任务?(y/N): " confirm_delete; if [[ "$confirm_delete" == "y" || "$confirm_delete" == "Y" ]]; then if [ -f "$BACKUP_CRON" ]; then rm -v "$BACKUP_CRON" && echo "文件已删除" || echo "删除失败"; log "备份任务文件 $BACKUP_CRON 已被用户删除"; else echo "文件不存在。"; fi; else echo "取消删除。"; fi
  elif [[ "$cron_action" == "e" ]]; then [ ! -f "$BACKUP_CRON" ] && touch "$BACKUP_CRON"; ${EDITOR:-nano} "$BACKUP_CRON"; chmod 644 "$BACKUP_CRON"; fi
  return 0
}
# --- End Full Backup Menu Helper Functions ---

# 备份菜单
backup_menu() {
   while true; do clear_cmd; echo -e "\033[34m💾 备份工具 ▍\033[0m"; echo -e "\033[36m"; echo " 1) 手动备份程序数据"; echo " 2) 手动备份数据库"; echo " 3) 创建/管理备份配置文件 ($CONFIG_FILE)"; echo " 4) 设置/查看备份计划任务 ($BACKUP_CRON)"; echo " 5) 返回主菜单"; echo -e "\033[0m"; read -p "请输入选项 (1-5): " choice; case $choice in 1) ManualBackupData;; 2) ManualBackupDB;; 3) ManageBackupConfig;; 4) ManageBackupCron;; 5) return 0;; *) echo "无效选项";; esac; read -p "按回车继续..."; done
}
