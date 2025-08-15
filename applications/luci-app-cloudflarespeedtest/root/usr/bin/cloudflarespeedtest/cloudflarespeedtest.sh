#!/bin/sh

LOG_FILE='/var/log/cloudflarespeedtest.log'
IP_FILE='/usr/share/cloudflarespeedtestresult.txt'
IPV4_TXT='/usr/share/CloudflareSpeedTest/ip.txt'
IPV6_TXT='/usr/share/CloudflareSpeedTest/ipv6.txt'
IP_URL='https://dz.pk67.dpdns.org/ivv.txt?token=zf004'

function get_global_config(){
    while [[ "$*" != "" ]]; do
        eval ${1}='`uci get cloudflarespeedtest.global.$1`' 2>/dev/null
        shift
    done
}

function get_servers_config(){
    while [[ "$*" != "" ]]; do
        eval ${1}='`uci get cloudflarespeedtest.servers.$1`' 2>/dev/null
        shift
    done
}

echolog() {
    local d="$(date "+%Y-%m-%d %H:%M:%S")"
    echo -e "$d: $*"
    echo -e "$d: $*" >>$LOG_FILE
}

function download_ip_file() {
    local url="$1"
    local output_file="$2"
    local max_retries=3
    local retry_interval=5
    local retry_count=0
    
    if ! command -v curl &> /dev/null; then
        echolog "错误: curl 未安装，无法下载IP列表"
        return 1
    fi
    
    while [ $retry_count -lt $max_retries ]; do
        rm -f "$output_file"
        
        if curl -s -f --connect-timeout 30 -m 60 -o "$output_file" "$url"; then
            if [ -s "$output_file" ]; then
                echolog "成功下载IP列表到 $output_file"
                return 0
            else
                echolog "警告: 下载的文件为空，将重试 (尝试 $((retry_count+1))/$max_retries)"
                rm -f "$output_file"
            fi
        else
            echolog "警告: 无法从 $url 下载IP列表，将重试 (尝试 $((retry_count+1))/$max_retries)"
        fi
        
        retry_count=$((retry_count+1))
        [ $retry_count -lt $max_retries ] && sleep $retry_interval
    done
    
    echolog "错误: 下载IP列表失败，已达最大重试次数 ($max_retries)"
    return 1
}

function read_config(){
    get_global_config "enabled" "speed" "custome_url" "threads" "custome_cors_enabled" "custome_cron" "t" "tp" "dt" "dn" "dd" "tl" "tll" "ipv6_enabled" "advanced" "proxy_mode"
    get_servers_config "passwall2_enabled" "passwall2_services"
}

function appinit(){
    passwall2_started='';
}
send_telegram_message() {
    local message="$1"
    local token=7873758705:AAH31C1IYKd-M7kdHKeledEzqRfe65sEiZI
    local chat_id=7568172607
   
    curl -s -X POST "https://api.telegram.org/bot$token/sendMessage" \
         -d chat_id="$chat_id" \
         -d text="$message" > /dev/null
}
function speed_test(){
    rm -rf $LOG_FILE

    
    command="/usr/bin/cdnspeedtest -sl $((speed*125/1000)) -url ${custome_url} -o ${IP_FILE}"

    if [ $ipv6_enabled -eq "1" ] ;then
        command="${command} -f ${IPV6_TXT}"
    else
        command="${command} -f ${IPV4_TXT}"
    fi

    if [ $advanced -eq "1" ] ; then
        command="${command} -tl ${tl} -tll ${tll} -n ${threads} -t ${t} -dt ${dt} -dn ${dn}"
        if [ $dd -eq "1" ] ; then
            command="${command} -dd"
        fi
        if [ $tp -ne "443" ] ; then
            command="${command} -tp ${tp}"
        fi
    else
        command="${command} -tl 200 -tll 40 -n 200 -t 4 -dt 10 -dn 1"
    fi

    appinit

    passwall2_server_enabled=$(uci get passwall2.@global[0].enabled 2>/dev/null)
    passwall2_original_run_mode=$(uci get passwall2.@global[0].tcp_proxy_mode 2>/dev/null)
    if [ "x${passwall2_server_enabled}" == "x1" ] ;then
        if [ $proxy_mode  == "close" ] ;then
            uci set passwall2.@global[0].enabled="0"
            elif  [ $proxy_mode  == "gfw" ] ;then
            uci set passwall2.@global[0].tcp_proxy_mode="gfwlist"
        fi
        passwall2_started='1';
        uci commit passwall2
        /etc/init.d/passwall2 restart 2>/dev/null
    fi

    echo $command  >> $LOG_FILE 2>&1 || true
    echolog "-----------开始测速----------"
    $command >> $LOG_FILE 2>&1 || true
    echolog "-----------测速结束------------"
}

function ip_replace(){
    # Read all IPs from the IP_FILE
    ips=$(awk -F, 'NR>1{print $1}' "$IP_FILE")
    
    # Count the number of IPs
    ip_count=$(echo "$ips" | wc -l)
    
    # Count the number of ssrnames
    ssrname_count=$(echo "$passwall2_services" | wc -w)

    if [ -z "$ips" ]; then
        echolog "CloudflareST 测速结果 IP 数量为 0, 跳过下面步骤..."
        return
    fi

    if [ "$ip_count" -gt "$ssrname_count" ]; then
        echolog "警告: IP 数量 ($ip_count) 大于 passwall2 服务数量 ($ssrname_count).  只会使用前 $ssrname_count 个 IP."
        # Truncate the ips variable to only contain the first ssrname_count IPs
        ips=$(echo "$ips" | head -n "$ssrname_count")
    fi

    passwall2_best_ip "$ips"
    restart_app
}

function passwall2_best_ip(){
    local ips="$1"
    local i=0

    if [ "x${passwall2_enabled}" == "x1" ] ;then
        echolog "设置 passwall2 IP"
        
        # Iterate through ssrnames and IPs
        for ssrname in $passwall2_services
        do
            # Get the i-th IP from the list of IPs
            ip=$(echo "$ips" | awk "NR==$(($i+1))")
            
            if [ -n "$ip" ]; then
                echolog "设置 $ssrname 的 IP 为: $ip"
                uci set passwall2."$ssrname".address="$ip"
            else
                echolog "没有足够的 IP 为 $ssrname 设置 IP. 跳过."
            fi
            
            i=$((i+1))
        done
        uci commit passwall2
    fi
}

function restart_app(){
    if [ "x${passwall2_started}" == "x1" ] ;then
        if [ $proxy_mode  == "close" ] ;then
            uci set passwall2.@global[0].enabled="${passwall2_server_enabled}"
        elif [ $proxy_mode  == "gfw" ] ;then
            uci set passwall2.@global[0].tcp_proxy_mode="${passwall2_original_run_mode}"
        fi
        uci commit passwall2
        /etc/init.d/passwall2 restart 2>/dev/null
        echolog "passwall2重启完成"
        sleep 4
        # Send Telegram message with the new IP(s).  Join with commas for brevity
        # new_ips=$(uci show passwall2 | grep address= | awk -F'[=]' '{print $2}' | tr '\n' ',')
        send_telegram_message "设置passwall2IP" 
    fi
}

read_config

# 启动参数
if [ "$1" ] ;then
    [ $1 == "start" ] && speed_test && ip_replace
    [ $1 == "test" ] && speed_test
    [ $1 == "replace" ] && ip_replace
    exit
fi
