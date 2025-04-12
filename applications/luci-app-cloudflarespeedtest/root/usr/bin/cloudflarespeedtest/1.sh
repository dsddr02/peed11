#!/bin/sh

LOG_FILE='/var/log/cloudflarespeedtest.log'
IP_FILE='/usr/share/cloudflarespeedtestresult.txt'
IPV4_TXT='/usr/share/CloudflareSpeedTest/ip.txt'
IPV6_TXT='/usr/share/CloudflareSpeedTest/ipv6.txt'
IP_URL='/ivv.txt'

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
    send_telegram_message "错误: 下载IP列表失败，已达最大重试次数 ($max_retries)"

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

    if [ $ipv6_enabled -eq "1" ]; then
        echolog "开始下载IPv6 IP列表..."
        if ! download_ip_file "$IP_URL" "$IPV6_TXT"; then
            echolog "错误: 无法获取IPv6 IP列表，测速终止"
            return 1
        fi
    else
        echolog "开始下载IPv4 IP列表..."
        if ! download_ip_file "$IP_URL" "$IPV4_TXT"; then
            echolog "错误: 无法获取IPv4 IP列表，测速终止"
            send_telegram_message "错误: 无法获取IPv4 IP列表，测速终止"
            return 1
        fi
    fi

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

    echo $command  >> $LOG_FILE 2>&1
    echolog "-----------开始测速----------"
    $command >> $LOG_FILE 2>&1
    echolog "-----------测速结束------------"
}

function ip_replace(){
    bestip=$(sed -n "2,1p" $IP_FILE | awk -F, '{print $1}')
    if [[ -z "${bestip}" ]]; then
        echolog "CloudflareST 测速结果 IP 数量为 0,跳过下面步骤..."
    else
        passwall2_best_ip
        restart_app
    fi
}

function passwall2_best_ip(){
    if [ "x${passwall2_enabled}" == "x1" ] ;then
        echolog "设置passwall2 IP"
        for ssrname in $passwall2_services
        do
            echo $ssrname
            uci set passwall2.$ssrname.address="${bestip}"
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
        sleep 10
        send_telegram_message "设置passwall2IP${bestip}"
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
