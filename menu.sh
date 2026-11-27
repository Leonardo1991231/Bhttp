#!/bin/bash

# ==========================================
# SUITE DE ADMINISTRACIÓN - LeoLatam SSH
# Desarrollado por @Leonardo1991231
# ==========================================

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
PURPLE="\033[0;35m"
CYAN="\033[0;36m"
NC="\033[0m"

if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Ejecuta el panel como root (sudo menu).${NC}"
  exit 1
fi

# Obtener puertos activos de BHTTP
get_puertos() {
    PUERTOS_ACTIVOS=$(grep -h -oP '(?<=--port )\d+' /etc/systemd/system/bhttp*.service 2>/dev/null | tr '\n' ' ')
    if [ -z "$PUERTOS_ACTIVOS" ]; then
        PUERTOS_ACTIVOS="${RED}Ninguno activo${NC}"
    else
        PUERTOS_ACTIVOS="${GREEN}$PUERTOS_ACTIVOS${NC}"
    fi
}

# 1. Agregar puerto adicional (Multipuertos)
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
ExecStart=/usr/bin/python3 /usr/local/lib/bhttp/bhttp-server.py --host 0.0.0.0 --port $NUEVO_PUERTO --backend-host 127.0.0.1 --backend-port 22
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable bhttp-$NUEVO_PUERTO >/dev/null 2>&1
    systemctl start bhttp-$NUEVO_PUERTO
    echo -e "${GREEN}[✓] ¡Puerto $NUEVO_PUERTO abierto y funcionando en simultáneo!${NC}"
    sleep 2
}

# 2. Cambiar puerto principal o cerrar un puerto
gestionar_puertos() {
    echo -e "\n${CYAN}--- GESTIONAR / CERRAR PUERTOS ---${NC}"
    echo -e "Puertos configurados: $PUERTOS_ACTIVOS"
    echo -ne "${YELLOW}Escribe el puerto que deseas cerrar/eliminar (o Enter para volver): ${NC}"
    read PUERTO_DEL

    if [ -z "$PUERTO_DEL" ]; then return; fi

    if [ -f "/etc/systemd/system/bhttp-$PUERTO_DEL.service" ]; then
        systemctl stop bhttp-$PUERTO_DEL
        systemctl disable bhttp-$PUERTO_DEL >/dev/null 2>&1
        rm -f /etc/systemd/system/bhttp-$PUERTO_DEL.service
        systemctl daemon-reload
        echo -e "${GREEN}[✓] Puerto $PUERTO_DEL cerrado y eliminado.${NC}"
    elif grep -q -- "--port $PUERTO_DEL" /etc/systemd/system/bhttp.service 2>/dev/null; then
        echo -ne "${YELLOW}Ese es el puerto principal. Introduce el nuevo puerto para reemplazarlo: ${NC}"
        read REEMPLAZO
        if [[ "$REEMPLAZO" =~ ^[0-9]+$ ]] && ! lsof -i :"$REEMPLAZO" >/dev/null 2>&1; then
            sed -i "s/--port $PUERTO_DEL/--port $REEMPLAZO/g" /etc/systemd/system/bhttp.service
            sed -i "s/puerto $PUERTO_DEL/puerto $REEMPLAZO/g" /etc/systemd/system/bhttp.service
            systemctl daemon-reload
            systemctl restart bhttp
            echo -e "${GREEN}[✓] Puerto principal cambiado a $REEMPLAZO.${NC}"
        else
            echo -e "${RED}[!] Puerto inválido u ocupado.${NC}"
        fi
    else
        echo -e "${RED}[!] No se encontró ningún servicio BHTTP en el puerto $PUERTO_DEL.${NC}"
    fi
    sleep 2
}

# 3. Crear usuario SSH con días de vencimiento
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

    if ! [[ "$DIAS" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[!] Los días deben ser un número.${NC}"
        sleep 2; return
    fi

    # Asegurar que /bin/false sea válido para túneles SSH sin consola
    grep -qxF '/bin/false' /etc/shells || echo '/bin/false' >> /etc/shells

    FECHA_EXP=$(date -d "+$DIAS days" +%Y-%m-%d)
    useradd -M -s /bin/false -e "$FECHA_EXP" "$USUARIO"
    echo "$USUARIO:$PASS" | chpasswd

    IP_VPS=$(wget -qO- ifconfig.me || curl -s ifconfig.me)
    echo -e "\n${GREEN}=========================================${NC}"
    echo -e "${GREEN}   [✓] CUENTA CREADA - LeoLatam SSH      ${NC}"
    echo -e "${GREEN}=========================================${NC}"
    echo -e "  ${BLUE}Host / IP   :${NC} $IP_VPS"
    echo -e "  ${BLUE}Usuario     :${NC} $USUARIO"
    echo -e "  ${BLUE}Contraseña  :${NC} $PASS"
    echo -e "  ${BLUE}Vence el    :${NC} $FECHA_EXP ($DIAS días)"
    echo -e "${GREEN}=========================================${NC}"
    echo -ne "\nPresiona Enter para continuar..."
    read
}

# 4. Ver y eliminar usuarios SSH
gestionar_usuarios() {
    echo -e "\n${CYAN}--- USUARIOS SSH REGISTRADOS ---${NC}"
    awk -F: '$7 == "/bin/false" {print "  • Usuario: " $1}' /etc/passwd
    echo -e "${CYAN}---------------------------------${NC}"
    echo -ne "${YELLOW}Escribe el usuario a eliminar (o presiona Enter para volver): ${NC}"
    read USER_DEL

    if [ ! -z "$USER_DEL" ]; then
        if id "$USER_DEL" &>/dev/null; then
            pkill -u "$USER_DEL" 2>/dev/null
            userdel -f "$USER_DEL" 2>/dev/null
            echo -e "${GREEN}[✓] Usuario $USER_DEL eliminado.${NC}"
        else
            echo -e "${RED}[!] El usuario no existe.${NC}"
        fi
        sleep 2
    fi
}

# Bucle principal
while true; do
    get_puertos
    clear
    echo -e "${CYAN}=====================================================================${NC}"
    echo -e "${PURPLE}"'  _               _           _                     ____ ____ _   _ '
    echo -e ' | |    ___  ___ | |    __ _ | |_ __ _ _ __ ___    / ___/ ___| | | |'
    echo -e ' | |   / _ \/ _ \| |   / _` || __/ _` | '\''_ ` _ \   \___ \___ \ |_| |'
    echo -e ' | |__|  __/ (_) | |__| (_| || || (_| | | | | | |   ___) |__) |  _  |'
    echo -e ' |_____\___|\___/|_____\__,_| \__\__,_|_| |_| |_|  |____/____/|_| |_|'"${NC}"
    echo -e "                     ${YELLOW}Panel Oficial BHTTP - VPS${NC}"
    echo -e "${CYAN}=====================================================================${NC}"
    echo -e "  ${YELLOW}Puertos BHTTP Activos :${NC} $PUERTOS_ACTIVOS"
    echo -e "${CYAN}---------------------------------------------------------------------${NC}"
    echo -e "  ${GREEN}[1]${NC} Abrir Nuevo Puerto BHTTP (Multipuertos)"
    echo -e "  ${GREEN}[2]${NC} Cambiar Puerto Principal / Cerrar un Puerto"
    echo -e "  ${GREEN}[3]${NC} Crear Usuario SSH (Con vencimiento)"
    echo -e "  ${GREEN}[4]${NC} Ver / Eliminar Usuarios SSH"
    echo -e "  ${GREEN}[5]${NC} Reiniciar Todos los Servicios BHTTP"
    echo -e "  ${GREEN}[6]${NC} Ver Monitor de Conexiones (Logs en vivo)"
    echo -e "  ${RED}[7]${NC} Desinstalar LeoLatam SSH y BHTTP"
    echo -e "  ${YELLOW}[0]${NC} Salir del Panel"
    echo -e "${CYAN}=====================================================================${NC}"
    echo -ne "${YELLOW}Selecciona una opción [0-7]: ${NC}"
    read OPCION

    case $OPCION in
        1) agregar_puerto ;;
        2) gestionar_puertos ;;
        3) crear_usuario ;;
        4) gestionar_usuarios ;;
        5)
            echo -e "\n${BLUE}[*] Reiniciando servicios BHTTP...${NC}"
            systemctl restart bhttp* 2>/dev/null
            echo -e "${GREEN}[✓] Todos los puertos reiniciados.${NC}"
            sleep 1.5
            ;;
        6)
            echo -e "\n${CYAN}[*] Mostrando logs en vivo (Presiona Ctrl + C para salir)...${NC}\n"
            sleep 1
            journalctl -u 'bhttp*' -f
            ;;
        7)
            echo -ne "\n${RED}¿Seguro que deseas eliminar todo el sistema BHTTP y el menú? (s/n): ${NC}"
            read CONFIRMAR
            if [[ "$CONFIRMAR" == "s" || "$CONFIRMAR" == "S" ]]; then
                systemctl stop bhttp* 2>/dev/null
                systemctl disable bhttp* 2>/dev/null
                rm -f /etc/systemd/system/bhttp*.service
                rm -rf /usr/local/lib/bhttp
                rm -f /usr/local/bin/menu
                systemctl daemon-reload
                echo -e "${GREEN}[✓] Sistema desinstalado por completo.${NC}"
                exit 0
            fi
            ;;
        0)
            echo -e "\n${CYAN}¡Hasta luego! Escribe 'menu' cuando quieras volver.${NC}"
            exit 0
            ;;
        *)
            echo -e "\n${RED}[!] Opción inválida.${NC}"
            sleep 1
            ;;
    esac
done
