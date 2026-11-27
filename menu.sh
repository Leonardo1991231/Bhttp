#!/bin/bash

# ==========================================
# SUITE DE ADMINISTRACIÓN - LeoLatam SSH
# Comando de inicio: bhttp
# ==========================================

RED="\033[1;31m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
BLUE="\033[1;34m"
PURPLE="\033[1;35m"
CYAN="\033[1;36m"
DIM="\033[2m"
WHITE="\033[1;37m"
NC="\033[0m"

linea() { printf "${CYAN}%s${NC}\n" "──────────────────────────────────────────────────────────────────────"; }

DB_LIMITES="/usr/local/lib/bhttp/limites.db"
CPU_PREV_TOTAL=""
CPU_PREV_IDLE=""
mkdir -p /usr/local/lib/bhttp
touch "$DB_LIMITES"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Ejecuta el panel como root (sudo bhttp).${NC}"
  exit 1
fi

# Modo automático silencioso para el Cron (Limpieza de madrugada)
if [ "$1" == "--limpiar-auto" ]; then
    HOY=$(date +%s)
    for USER in $(awk -F: '$7 == "/bin/false" {print $1}' /etc/passwd); do
        EXP_STR=$(chage -l "$USER" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
        if [[ "$EXP_STR" != "never" && ! -z "$EXP_STR" ]]; then
            EXP_SEC=$(date -d "$EXP_STR" +%s 2>/dev/null)
            if [ ! -z "$EXP_SEC" ] && [ "$EXP_SEC" -lt "$HOY" ]; then
                pkill -u "$USER" 2>/dev/null
                userdel -f "$USER" 2>/dev/null
                sed -i "/^$USER:/d" "$DB_LIMITES" 2>/dev/null
            fi
        fi
    done
    exit 0
fi

# Obtener métricas del sistema, puertos y usuarios en vivo
get_stats() {
    PUERTOS_ACTIVOS=$(grep -h -oP '(?<=--port )\d+' /etc/systemd/system/bhttp*.service 2>/dev/null | tr '\n' ' ')
    PUERTO_PRINCIPAL=$(grep -h -oP '(?<=--port )\d+' /etc/systemd/system/bhttp.service 2>/dev/null | head -1)
    SSH_BACKEND_PORT=$(grep -h -oP '(?<=--backend-port )\d+' /etc/systemd/system/bhttp.service 2>/dev/null | head -1)
    if [ -z "$SSH_BACKEND_PORT" ]; then
        SSH_BACKEND_PORT=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')
    fi
    SSH_BACKEND_PORT=${SSH_BACKEND_PORT:-22}
    if [ -z "$PUERTOS_ACTIVOS" ]; then
        PUERTOS_ACTIVOS="${RED}Ninguno activo${NC}"
    else
        PUERTOS_ACTIVOS="${GREEN}$PUERTOS_ACTIVOS${NC}"
    fi

    read -r RAM_TOTAL RAM_USADA < <(free -m 2>/dev/null | awk '/Mem:/ {print $2, $3}')
    RAM_TOTAL=${RAM_TOTAL:-0}; RAM_USADA=${RAM_USADA:-0}
    if [ "$RAM_TOTAL" -gt 0 ]; then RAM_PORC=$((RAM_USADA * 100 / RAM_TOTAL)); else RAM_PORC=0; fi

    local cpu_label cpu_user cpu_nice cpu_system cpu_idle cpu_iowait cpu_irq cpu_softirq cpu_steal cpu_total cpu_idle_all
    if read -r cpu_label cpu_user cpu_nice cpu_system cpu_idle cpu_iowait cpu_irq cpu_softirq cpu_steal _ < /proc/stat; then
        cpu_total=$((cpu_user + cpu_nice + cpu_system + cpu_idle + cpu_iowait + cpu_irq + cpu_softirq + cpu_steal))
        cpu_idle_all=$((cpu_idle + cpu_iowait))
        if [ -n "$CPU_PREV_TOTAL" ] && [ "$cpu_total" -gt "$CPU_PREV_TOTAL" ]; then
            CPU_USO="$(( (cpu_total - CPU_PREV_TOTAL - cpu_idle_all + CPU_PREV_IDLE) * 100 / (cpu_total - CPU_PREV_TOTAL) ))%"
        else
            CPU_USO="N/D"
        fi
        CPU_PREV_TOTAL="$cpu_total"
        CPU_PREV_IDLE="$cpu_idle_all"
    else
        CPU_USO="N/D"
    fi
    CONECTADOS=$(ps -ef | grep "sshd:" | grep -v "grep\|root\|priv" | wc -l)

    if ! systemctl cat bhttp-limiter.service >/dev/null 2>&1; then
        LIMITER_ESTADO="${YELLOW}NO INSTALADO${NC}"
    elif systemctl is-active --quiet bhttp-limiter; then
        LIMITER_ESTADO="${GREEN}ACTIVO${NC}"
    else
        LIMITER_ESTADO="${RED}INACTIVO${NC}"
    fi

    if crontab -l 2>/dev/null | grep -q "limpiar-auto"; then
        CRON_ESTADO="${GREEN}ACTIVO (03:00 AM)${NC}"
    else
        CRON_ESTADO="${RED}INACTIVO${NC}"
    fi
}

esperar_tecla() {
    printf "\n${DIM}Presiona Enter para volver al panel...${NC}"
    IFS= read -r _
}

controlar_bhttp() {
    local estado inicio opcion
    estado=$(systemctl is-active bhttp 2>/dev/null)
    inicio=$(systemctl is-enabled bhttp 2>/dev/null)
    [ -z "$estado" ] && estado="inactivo"
    [ -z "$inicio" ] && inicio="no habilitado"
    echo -e "\n${CYAN}--- CONTROL DEL SERVICIO BHTTP ---${NC}"
    echo -e "Estado actual: ${WHITE}$estado${NC} | Inicio automático: ${WHITE}$inicio${NC}"
    echo -e "  ${GREEN}1)${NC} Encender ahora y al iniciar la VPS"
    echo -e "  ${RED}2)${NC} Apagar ahora y evitar que arranque con la VPS"
    echo -e "  ${YELLOW}0)${NC} Volver"
    echo -ne "\n${YELLOW}Elige una opción: ${NC}"
    IFS= read -r opcion
    case "$opcion" in
        1)
            if systemctl enable --now bhttp; then
                echo -e "${GREEN}[✓] BHTTP está encendido y habilitado al iniciar la VPS.${NC}"
            else
                echo -e "${RED}[!] No se pudo iniciar BHTTP. Revisa: systemctl status bhttp${NC}"
            fi
            esperar_tecla
            ;;
        2)
            if systemctl disable --now bhttp; then
                echo -e "${GREEN}[✓] BHTTP está apagado y no arrancará automáticamente.${NC}"
            else
                echo -e "${RED}[!] No se pudo detener BHTTP. Revisa: systemctl status bhttp${NC}"
            fi
            esperar_tecla
            ;;
    esac
}

controlar_limitador() {
    local opcion
    echo -e "\n${CYAN}--- LIMITADOR DE CONEXIONES ---${NC}"
    if ! systemctl cat bhttp-limiter.service >/dev/null 2>&1; then
        echo -e "${YELLOW}[!] El servicio bhttp-limiter no está instalado.${NC}"
        echo -e "Este repositorio guarda los límites de cuentas, pero no incluye el servicio que los aplica."
        echo -e "Por eso no se puede activar desde este menú todavía."
        esperar_tecla
        return
    fi
    echo -e "Estado: $(systemctl is-active bhttp-limiter 2>/dev/null || echo desconocido)"
    echo -e "  ${GREEN}1)${NC} Activar ahora y al iniciar la VPS"
    echo -e "  ${RED}2)${NC} Desactivar ahora y al iniciar la VPS"
    echo -e "  ${YELLOW}0)${NC} Volver"
    echo -ne "\n${YELLOW}Elige una opción: ${NC}"
    IFS= read -r opcion
    case "$opcion" in
        1)
            if systemctl enable --now bhttp-limiter; then echo -e "${GREEN}[✓] Limitador activado.${NC}"; else echo -e "${RED}[!] No se pudo activar el limitador.${NC}"; fi
            esperar_tecla
            ;;
        2)
            if systemctl disable --now bhttp-limiter; then echo -e "${GREEN}[✓] Limitador desactivado.${NC}"; else echo -e "${RED}[!] No se pudo desactivar el limitador.${NC}"; fi
            esperar_tecla
            ;;
    esac
}

# Abrir puerto en Firewall automáticamente (UFW e iptables)
abrir_firewall() {
    local PUERTO_FW=$1
    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        ufw allow "$PUERTO_FW"/tcp >/dev/null 2>&1
    fi
    if command -v iptables &> /dev/null; then
        iptables -I INPUT -p tcp --dport "$PUERTO_FW" -j ACCEPT 2>/dev/null
    fi
}

# 1. Agregar puerto adicional (Multipuertos + Firewall)
agregar_puerto() {
    echo -e "\n${CYAN}--- ABRIR NUEVO PUERTO BHTTP ---${NC}"
    echo -ne "${YELLOW}Introduce el puerto libre que deseas abrir (Ej: 8880): ${NC}"
    read NUEVO_PUERTO

    if ! [[ "$NUEVO_PUERTO" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[!] Debes ingresar un número válido.${NC}"
        sleep 2; return
    fi

    if lsof -i :"$NUEVO_PUERTO" >/dev/null 2>&1; then
        echo -e "${RED}[!] El puerto $NUEVO_PUERTO ya está ocupado.${NC}"
        sleep 2; return
    fi

    cat << EOF > /etc/systemd/system/bhttp-$NUEVO_PUERTO.service
[Unit]
Description=Servidor BHTTP (LeoLatam SSH) puerto $NUEVO_PUERTO
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/bhttp/bhttp-server.py --host 0.0.0.0 --port $NUEVO_PUERTO --backend-host 127.0.0.1 --backend-port $SSH_BACKEND_PORT
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    abrir_firewall "$NUEVO_PUERTO"
    systemctl daemon-reload
    systemctl enable bhttp-$NUEVO_PUERTO >/dev/null 2>&1
    systemctl start bhttp-$NUEVO_PUERTO
    echo -e "${GREEN}[✓] ¡Puerto $NUEVO_PUERTO abierto y habilitado en Firewall!${NC}"
    sleep 2
}

# 2. Cambiar puerto principal o cerrar un puerto
gestionar_puertos() {
    echo -e "\n${CYAN}--- GESTIONAR / CERRAR PUERTOS ---${NC}"
    echo -e "Puertos configurados: $PUERTOS_ACTIVOS"
    echo -ne "${YELLOW}Escribe el puerto que deseas cerrar/cambiar (o Enter para volver): ${NC}"
    read PUERTO_DEL

    if [ -z "$PUERTO_DEL" ]; then return; fi

    if [ -f "/etc/systemd/system/bhttp-$PUERTO_DEL.service" ]; then
        systemctl stop bhttp-$PUERTO_DEL
        systemctl disable bhttp-$PUERTO_DEL >/dev/null 2>&1
        rm -f /etc/systemd/system/bhttp-$PUERTO_DEL.service
        systemctl daemon-reload
        echo -e "${GREEN}[✓] Puerto $PUERTO_DEL cerrado y eliminado.${NC}"
    elif grep -q -- "--port $PUERTO_DEL" /etc/systemd/system/bhttp.service 2>/dev/null; then
        echo -ne "${YELLOW}Ese es el puerto principal. Introduce el nuevo puerto: ${NC}"
        read REEMPLAZO
        if [[ "$REEMPLAZO" =~ ^[0-9]+$ ]] && ! lsof -i :"$REEMPLAZO" >/dev/null 2>&1; then
            sed -i "s/--port $PUERTO_DEL/--port $REEMPLAZO/g" /etc/systemd/system/bhttp.service
            sed -i "s/puerto $PUERTO_DEL/puerto $REEMPLAZO/g" /etc/systemd/system/bhttp.service
            abrir_firewall "$REEMPLAZO"
            systemctl daemon-reload
            systemctl restart bhttp
            echo -e "${GREEN}[✓] Puerto principal cambiado a $REEMPLAZO y abierto en Firewall.${NC}"
        else
            echo -e "${RED}[!] Puerto inválido u ocupado.${NC}"
        fi
    else
        echo -e "${RED}[!] No se encontró ningún servicio BHTTP en el puerto $PUERTO_DEL.${NC}"
    fi
    sleep 2
}
# 3. Crear usuario SSH con días de vencimiento y límite de conexiones
crear_usuario() {
    echo -e "\n${CYAN}--- CREAR CUENTA SSH ---${NC}"
    echo -ne "${YELLOW}Nombre de usuario: ${NC}"
    read USUARIO
    if id "$USUARIO" &>/dev/null || [ -z "$USUARIO" ]; then
        echo -e "${RED}[!] El usuario ya existe o el nombre es inválido.${NC}"
        sleep 2; return
    fi

    echo -ne "${YELLOW}Contraseña: ${NC}"
    read PASS
    echo -ne "${YELLOW}Días de duración (Ej: 30): ${NC}"
    read DIAS
    echo -ne "${YELLOW}Límite de conexiones simultáneas (Ej: 1): ${NC}"
    read LIMITE

    if ! [[ "$DIAS" =~ ^[0-9]+$ ]] || ! [[ "$LIMITE" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[!] Los días y el límite deben ser números válidos.${NC}"
        sleep 2; return
    fi

    grep -qxF '/bin/false' /etc/shells || echo '/bin/false' >> /etc/shells

    FECHA_EXP=$(date -d "+$DIAS days" +%Y-%m-%d)
    useradd -M -s /bin/false -e "$FECHA_EXP" "$USUARIO"
    echo "$USUARIO:$PASS" | chpasswd

    # Guardar límite en la base de datos del limitador
    sed -i "/^$USUARIO:/d" "$DB_LIMITES"
    echo "$USUARIO:$LIMITE" >> "$DB_LIMITES"

    IP_VPS=$(wget -qO- ifconfig.me || curl -s ifconfig.me)
    echo -e "\n${GREEN}=========================================${NC}"
    echo -e "${GREEN}   [✓] CUENTA CREADA - LeoLatam SSH      ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "  ${BLUE}Host / IP   :${NC} $IP_VPS"
    echo -e "  ${BLUE}Usuario     :${NC} $USUARIO"
    echo -e "  ${BLUE}Contraseña  :${NC} $PASS"
    echo -e "  ${BLUE}Conexiones  :${NC} Máximo $LIMITE dispositivo(s)"
    echo -e "  ${BLUE}Vence el    :${NC} $FECHA_EXP ($DIAS días)"
    echo -e "${GREEN}=========================================${NC}"
    echo -ne "\nPresiona Enter para continuar..."
    read
}

# 4. Ver, cambiar límite o eliminar usuarios SSH
gestionar_usuarios() {
    echo -e "\n${CYAN}--- USUARIOS SSH REGISTRADOS ---${NC}"
    for USER in $(awk -F: '$7 == "/bin/false" {print $1}' /etc/passwd); do
        EXP=$(chage -l "$USER" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
        LIM=$(grep "^$USER:" "$DB_LIMITES" | cut -d: -f2)
        [ -z "$LIM" ] && LIM="Sin límite"
        echo -e "  • Usuario: ${GREEN}$USER${NC} | Límite: ${BLUE}$LIM${NC} | Vence: ${YELLOW}$EXP${NC}"
    done
    echo -e "${CYAN}---------------------------------${NC}"
    echo -e "  ${GREEN}1)${NC} Eliminar un usuario"
    echo -e "  ${GREEN}2)${NC} Cambiar límite de conexiones de un usuario"
    echo -e "  ${YELLOW}0)${NC} Volver"
    echo -ne "\n${YELLOW}Elige una opción: ${NC}"
    read SUB_USER

    case $SUB_USER in
        1)
            echo -ne "${YELLOW}Escribe el usuario a eliminar: ${NC}"
            read USER_DEL
            if [ ! -z "$USER_DEL" ] && id "$USER_DEL" &>/dev/null; then
                pkill -u "$USER_DEL" 2>/dev/null
                userdel -f "$USER_DEL" 2>/dev/null
                sed -i "/^$USER_DEL:/d" "$DB_LIMITES"
                echo -e "${GREEN}[✓] Usuario $USER_DEL eliminado por completo.${NC}"
            else
                echo -e "${RED}[!] Usuario no encontrado.${NC}"
            fi
            sleep 2
            ;;
        2)
            echo -ne "${YELLOW}Escribe el nombre del usuario: ${NC}"
            read USER_EDIT
            if [ ! -z "$USER_EDIT" ] && id "$USER_EDIT" &>/dev/null; then
                echo -ne "${YELLOW}Nuevo límite de conexiones (Ej: 2): ${NC}"
                read NUEVO_LIM
                if [[ "$NUEVO_LIM" =~ ^[0-9]+$ ]]; then
                    sed -i "/^$USER_EDIT:/d" "$DB_LIMITES"
                    echo "$USER_EDIT:$NUEVO_LIM" >> "$DB_LIMITES"
                    echo -e "${GREEN}[✓] Límite de $USER_EDIT actualizado a $NUEVO_LIM dispositivo(s).${NC}"
                else
                    echo -e "${RED}[!] Número inválido.${NC}"
                fi
            else
                echo -e "${RED}[!] Usuario no encontrado.${NC}"
            fi
            sleep 2
            ;;
    esac
}
# 5. Monitor de usuarios conectados en vivo
ver_conectados() {
    echo -e "\n${CYAN}--- USUARIOS CONECTADOS EN VIVO ---${NC}"
    LISTA=$(ps -ef | grep "sshd:" | grep -v "grep\|root\|priv" | awk '{print $9}' | cut -d@ -f1 | sort | uniq -c)
    if [ -z "$LISTA" ]; then
        echo -e "  ${YELLOW}No hay usuarios conectados en este momento.${NC}"
    else
        echo -e "${GREEN}Conexiones | Usuario${NC}"
        echo "$LISTA"
    fi
    echo -e "${CYAN}-----------------------------------${NC}"
    echo -ne "Presiona Enter para volver..."
    read
}

# 6. Limpiador de usuarios vencidos (Manual + Programador Automático)
limpiar_vencidos() {
    echo -e "\n${CYAN}--- LIMPIADOR DE CUENTAS VENCIDAS ---${NC}"
    echo -e "  ${GREEN}1)${NC} Limpiar cuentas vencidas AHORA"
    echo -e "  ${GREEN}2)${NC} Activar / Desactivar limpieza automática (03:00 AM)"
    echo -e "  ${YELLOW}0)${NC} Volver"
    echo -ne "\n${YELLOW}Elige una opción: ${NC}"
    read SUB_OPC

    case $SUB_OPC in
        1)
            echo -e "\n${BLUE}[*] Buscando cuentas expiradas...${NC}"
            HOY=$(date +%s)
            ELIMINADOS=0
            for USER in $(awk -F: '$7 == "/bin/false" {print $1}' /etc/passwd); do
                EXP_STR=$(chage -l "$USER" 2>/dev/null | grep "Account expires" | cut -d: -f2 | xargs)
                if [[ "$EXP_STR" != "never" && ! -z "$EXP_STR" ]]; then
                    EXP_SEC=$(date -d "$EXP_STR" +%s 2>/dev/null)
                    if [ ! -z "$EXP_SEC" ] && [ "$EXP_SEC" -lt "$HOY" ]; then
                        pkill -u "$USER" 2>/dev/null
                        userdel -f "$USER" 2>/dev/null
                        sed -i "/^$USER:/d" "$DB_LIMITES" 2>/dev/null
                        echo -e "  ${RED}[-] Eliminado:${NC} $USER (Venció el $EXP_STR)"
                        ELIMINADOS=$((ELIMINADOS + 1))
                    fi
                fi
            done
            echo -e "${GREEN}[✓] Limpieza terminada. Cuentas borradas: $ELIMINADOS${NC}"
            sleep 2.5
            ;;
        2)
            if crontab -l 2>/dev/null | grep -q "limpiar-auto"; then
                crontab -l 2>/dev/null | grep -v "limpiar-auto" | crontab -
                echo -e "${YELLOW}[!] Limpieza automática desactivada.${NC}"
            else
                (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/bhttp --limpiar-auto") | crontab -
                echo -e "${GREEN}[✓] Limpieza automática activada (se ejecutará diario a las 03:00 AM).${NC}"
            fi
            sleep 2
            ;;
    esac
}

# Bucle principal
while true; do
    get_stats
    if [ -t 1 ] && [ -n "${TERM:-}" ]; then clear; fi
    printf "${BLUE}╔════════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║${NC}  ${CYAN}LEOLATAM SSH${NC}  ${DIM}·${NC}  ${WHITE}PANEL DE ADMINISTRACIÓN BHTTP${NC}                   ${BLUE}║${NC}\n"
    printf "${BLUE}╚════════════════════════════════════════════════════════════════════╝${NC}\n"
    printf "  ${DIM}Servidor seguro · Gestión de puertos y cuentas SSH${NC}\n\n"

    ESTADO_BHTTP=$(systemctl is-active bhttp 2>/dev/null)
    [ -z "$ESTADO_BHTTP" ] && ESTADO_BHTTP="inactivo"
    if [ "$ESTADO_BHTTP" = "active" ]; then ESTADO_BHTTP="${GREEN}ACTIVO${NC}"; else ESTADO_BHTTP="${RED}INACTIVO${NC}"; fi
    printf "  ${WHITE}ESTADO DEL SISTEMA${NC}\n"
    linea
    printf "  BHTTP: %b   CPU: ${GREEN}%s${NC}   RAM: ${GREEN}%s/%s MB (%s%%)${NC}   SSH: ${BLUE}%s en línea${NC}\n" "$ESTADO_BHTTP" "$CPU_USO" "$RAM_USADA" "$RAM_TOTAL" "$RAM_PORC" "$CONECTADOS"
    printf "  Puerto BHTTP principal: ${GREEN}%s${NC}   SSH backend: ${GREEN}%s${NC}\n" "${PUERTO_PRINCIPAL:-no configurado}" "$SSH_BACKEND_PORT"
    printf "  Puertos configurados: %b   Limitador: %b   Limpieza automática: %b\n\n" "$PUERTOS_ACTIVOS" "$LIMITER_ESTADO" "$CRON_ESTADO"

    printf "  ${WHITE}SERVIDOR BHTTP${NC}\n"
    linea
    printf "  ${CYAN}[1]${NC}  Abrir un puerto BHTTP desde el menú\n"
    printf "  ${CYAN}[2]${NC}  Gestionar o cerrar puertos\n"
    printf "  ${CYAN}[7]${NC}  Encender o apagar el servicio BHTTP\n"
    printf "  ${CYAN}[8]${NC}  Activar o desactivar el limitador\n"
    printf "  ${CYAN}[9]${NC}  Reiniciar servicios\n"
    printf "  ${CYAN}[10]${NC} Ver registros en vivo\n\n"

    printf "  ${WHITE}CUENTAS SSH${NC}\n"
    linea
    printf "  ${CYAN}[3]${NC}  Crear una cuenta\n"
    printf "  ${CYAN}[4]${NC}  Ver, editar o eliminar cuentas\n"
    printf "  ${CYAN}[5]${NC}  Ver conexiones activas\n"
    printf "  ${CYAN}[6]${NC}  Gestionar cuentas vencidas\n\n"

    printf "  ${RED}[11]${NC} Desinstalar LeoLatam SSH y BHTTP\n"
    printf "  ${YELLOW}[0]${NC}  Salir\n"
    linea
    printf "  ${YELLOW}Elige una opción [0-11]: ${NC}"
    IFS= read -r OPCION

    case $OPCION in
        1) agregar_puerto ;;
        2) gestionar_puertos ;;
        3) crear_usuario ;;
        4) gestionar_usuarios ;;
        5) ver_conectados ;;
        6) limpiar_vencidos ;;
        7) controlar_bhttp ;;
        8) controlar_limitador ;;
        9)
            echo -e "\n${BLUE}[*] Reiniciando servicios BHTTP y Limitador...${NC}"
            systemctl restart 'bhttp*' 2>/dev/null
            echo -e "${GREEN}[✓] Todos los servicios reiniciados.${NC}"
            sleep 1.5
            ;;
        10)
            echo -e "\n${CYAN}[*] Mostrando logs en vivo (Presiona Ctrl + C para salir)...${NC}\n"
            sleep 1
            journalctl -u 'bhttp*' -f
            ;;
        11)
            echo -ne "\n${RED}¿Seguro que deseas eliminar todo el sistema BHTTP y el panel? (s/n): ${NC}"
            read CONFIRMAR
            if [[ "$CONFIRMAR" == "s" || "$CONFIRMAR" == "S" ]]; then
                systemctl stop 'bhttp*' 2>/dev/null
                systemctl disable 'bhttp*' 2>/dev/null
                rm -f /etc/systemd/system/bhttp*.service
                rm -rf /usr/local/lib/bhttp
                rm -f /usr/local/bin/bhttp
                crontab -l 2>/dev/null | grep -v "limpiar-auto" | crontab -
                systemctl daemon-reload
                echo -e "${GREEN}[✓] Sistema desinstalado por completo.${NC}"
                exit 0
            fi
            ;;
        0)
            echo -e "\n${CYAN}¡Hasta luego! Escribe 'bhttp' cuando quieras volver.${NC}"
            exit 0
            ;;
        *)
            echo -e "\n${RED}[!] Opción inválida.${NC}"
            sleep 1
            ;;
    esac
done
