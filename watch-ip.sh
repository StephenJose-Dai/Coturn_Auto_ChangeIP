#!/bin/sh
# ================= 可配置项 =================
CONF="/coturn-conf/turnserver.conf"
LOCAL_IP="${LOCAL_IP:-172.16.227.1}"
IFACE="${IFACE:-eth0}"
DDNS_DOMAIN="${DDNS_DOMAIN:-chat.baidu.com}"
INTERVAL="${INTERVAL:-180}"
CONTAINER="${CONTAINER:-coturn}"
IP_MODE="${IP_MODE:-dual}"        # dual | v4 | v6
# ===========================================

log() { echo "[ipwatch] $(date '+%F %T') $*"; }

case "$IP_MODE" in
    dual) EN4=1; EN6=1 ;;
    v4)   EN4=1; EN6=0 ;;
    v6)   EN4=0; EN6=1 ;;
    *) log "错误: IP_MODE 非法 ($IP_MODE)，可选 dual / v4 / v6"; exit 1 ;;
esac

log "启动: IP_MODE=${IP_MODE} 间隔=${INTERVAL}s 网卡=${IFACE} DDNS=${DDNS_DOMAIN} 容器=${CONTAINER}"

while true; do
    CHANGED=0
    log "======== 开始本轮检测 (模式=${IP_MODE}) ========"

    if [ ! -f "$CONF" ]; then
        log "致命: 配置文件不存在 $CONF，跳过本轮"
        log "======== 本轮结束(changed=0)，休眠${INTERVAL}s ========"
        sleep "$INTERVAL"
        continue
    fi

    # ---------------- IPv4 ----------------
    if [ "$EN4" -eq 0 ]; then
        log "[IPv4] 跳过 -- 原因: IP_MODE=${IP_MODE} 未包含 v4"
    else
        HAS_EX4=0; HAS_RL4=0
        grep -q '^external-ip=[^:]*$' "$CONF" && HAS_EX4=1
        grep -q '^relay-ip=[^:]*$'    "$CONF" && HAS_RL4=1
        log "[IPv4] 配置行状态: external-ip=$( [ $HAS_EX4 -eq 1 ] && echo 启用 || echo 注释/缺失 ) relay-ip=$( [ $HAS_RL4 -eq 1 ] && echo 启用 || echo 注释/缺失 )"

        if [ "$HAS_EX4" -eq 0 ] && [ "$HAS_RL4" -eq 0 ]; then
            log "[IPv4] 跳过 -- 原因: external-ip 与 relay-ip 的 v4 行均未启用"
        else
            CUR_V4=$(timeout 10 nslookup "$DDNS_DOMAIN" 2>/dev/null | awk '/^Address/ {print $NF}' \
                     | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' | tail -n1)
            if [ -n "$CUR_V4" ]; then
                log "[IPv4] 取址成功(DDNS ${DDNS_DOMAIN}): $CUR_V4"
            else
                log "[IPv4] DDNS 查询无结果，回退 api.ipify.org"
                CUR_V4=$(wget -qO- --timeout=10 https://api.ipify.org 2>/dev/null \
                         | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$')
                [ -n "$CUR_V4" ] && log "[IPv4] 取址成功(API): $CUR_V4"
            fi

            if [ -z "$CUR_V4" ]; then
                log "[IPv4] 跳过 -- 原因: DDNS 与 API 均未取到地址，保留配置原值"
            else
                if [ "$HAS_EX4" -eq 1 ]; then
                    OLD_V4=$(grep '^external-ip=[^:]*$' "$CONF" | cut -d= -f2 | cut -d/ -f1)
                else
                    OLD_V4=$(grep '^relay-ip=[^:]*$' "$CONF" | cut -d= -f2)
                fi
                log "[IPv4] 配置当前值: ${OLD_V4:-空}"

                if [ "$CUR_V4" = "$OLD_V4" ]; then
                    log "[IPv4] 无变化，不改写"
                else
                    log "[IPv4] 地址变更: ${OLD_V4:-空} -> ${CUR_V4}"
                    if [ "$HAS_EX4" -eq 1 ]; then
                        sed -i "/^external-ip=[^:]*$/s|.*|external-ip=${CUR_V4}/${LOCAL_IP}|" "$CONF"
                        log "[IPv4]   已写入 external-ip=${CUR_V4}/${LOCAL_IP}"
                    else
                        log "[IPv4]   external-ip 未启用，不写"
                    fi
                    if [ "$HAS_RL4" -eq 1 ]; then
                        sed -i "/^relay-ip=[^:]*$/s|.*|relay-ip=${LOCAL_IP}|" "$CONF"
                        log "[IPv4]   已写入 relay-ip=${LOCAL_IP}"
                    else
                        log "[IPv4]   relay-ip 未启用，不写"
                    fi
                    CHANGED=1
                fi
            fi
        fi
    fi

    # ---------------- IPv6 ----------------
    if [ "$EN6" -eq 0 ]; then
        log "[IPv6] 跳过 -- 原因: IP_MODE=${IP_MODE} 未包含 v6"
    else
        HAS_EX6=0; HAS_RL6=0
        grep -q '^external-ip=.*:' "$CONF" && HAS_EX6=1
        grep -q '^relay-ip=.*:'    "$CONF" && HAS_RL6=1
        log "[IPv6] 配置行状态: external-ip=$( [ $HAS_EX6 -eq 1 ] && echo 启用 || echo 注释/缺失 ) relay-ip=$( [ $HAS_RL6 -eq 1 ] && echo 启用 || echo 注释/缺失 )"

        if [ "$HAS_EX6" -eq 0 ] && [ "$HAS_RL6" -eq 0 ]; then
            log "[IPv6] 跳过 -- 原因: external-ip 与 relay-ip 的 v6 行均未启用"
        else
            CUR_V6=$(ip -6 addr show dev "$IFACE" 2>/dev/null \
                     | grep 'scope global' | grep -v temporary \
                     | awk '{print $2}' | cut -d/ -f1 \
                     | grep -E '^[23]' | head -n1)

            if [ -z "$CUR_V6" ]; then
                log "[IPv6] 跳过 -- 原因: 网卡 ${IFACE} 上没有 scope global 的 2/3 开头地址"
            else
                log "[IPv6] 取址成功(网卡 ${IFACE}): $CUR_V6"
                if [ "$HAS_EX6" -eq 1 ]; then
                    OLD_V6=$(grep '^external-ip=.*:' "$CONF" | cut -d= -f2)
                else
                    OLD_V6=$(grep '^relay-ip=.*:' "$CONF" | cut -d= -f2)
                fi
                log "[IPv6] 配置当前值: ${OLD_V6:-空}"

                if [ "$CUR_V6" = "$OLD_V6" ]; then
                    log "[IPv6] 无变化，不改写"
                else
                    log "[IPv6] 地址变更: ${OLD_V6:-空} -> ${CUR_V6}"
                    if [ "$HAS_EX6" -eq 1 ]; then
                        sed -i "/^external-ip=.*:/s|.*|external-ip=${CUR_V6}|" "$CONF"
                        log "[IPv6]   已写入 external-ip=${CUR_V6}"
                    else
                        log "[IPv6]   external-ip 未启用，不写"
                    fi
                    if [ "$HAS_RL6" -eq 1 ]; then
                        sed -i "/^relay-ip=.*:/s|.*|relay-ip=${CUR_V6}|" "$CONF"
                        log "[IPv6]   已写入 relay-ip=${CUR_V6}"
                    else
                        log "[IPv6]   relay-ip 未启用，不写"
                    fi
                    CHANGED=1
                fi
            fi
        fi
    fi

    # ---------------- 重启 ----------------
    if [ "$CHANGED" -eq 1 ]; then
        log "[重启] 配置有变更，当前生效行:"
        grep -E '^(external-ip|relay-ip|listening-ip)=' "$CONF" | while read -r l; do log "[重启]     $l"; done
        if docker restart "$CONTAINER" >/dev/null 2>&1; then
            log "[重启] ${CONTAINER} 重启成功"
        else
            log "[重启] 错误: ${CONTAINER} 重启失败"
        fi
    else
        log "[重启] 无变更，不重启"
    fi

    log "======== 本轮结束(changed=${CHANGED})，休眠${INTERVAL}s ========"
    sleep "$INTERVAL"
done
