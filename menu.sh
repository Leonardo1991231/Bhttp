
#!/bin/bash

# ==========================================
# PANEL DE ADMINISTRACIÓN BHTTP
# Desarrollado por @Leonardo1991231
# ==========================================

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
PURPLE="\033[0;35m"
CYAN="\033[0;36m"
NC="\033[0m"

# Verificar permisos de root
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Ejecuta el menú como root (sudo menu).${NC}"
  exit 1
fi

# Función para obtener el estado y puerto actual
get_status() {
    if systemctl is-active --quiet bhttp; then
        ESTADO="${GREEN}ACTIVO (Corriendo)${NC}"
    else
        ESTADO="${RED}DETENIDO${NC}"
    fi

    # Extraer el puerto configurado en el servicio systemd
    if [ -f /etc/systemd/system/bhttp.service ]; then
        PUERTO_ACTUAL=$(grep -oP '(?<=--port )\d+' /etc/systemd/system/bhttp.service)
    else
        PUERTO_ACTUAL="No instalado"
    fi
}

# Función para cambiar el puerto
cambiar_puerto() {
    echo -e "\n${CYAN}--- CAMBIAR PUERTO DEL SERVIDOR ---${NC}"
    echo -ne "${YELLOW}Introduce el nuevo puerto libre (Ej: 8080, 8880): ${NC}"
    read NUEVO_PUERTO

    # Validar que sea un número
    if ! [[ "$NUEVO_PUERTO" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}[!] Por favor, introduce un número válido.${NC}"
        sleep 2
        return
    fi

    # Validar si está ocupado
    if lsof -i :"$NUEVO_PUERTO" >/dev/null 2>&1; then
        echo -e "${RED}[!] El puerto $NUEVO_PUERTO ya está ocupado por otro servicio.${NC}"
        sleep 2
        return
    fi

    # Modificar el archivo de servicio y reiniciar
    sed -i "s/--port [0-9]\+/--port $NUEVO_PUERTO/g" /etc/systemd/system/bhttp.service
    sed -i "s/puerto [0-9]\+/puerto $NUEVO_PUERTO/g" /etc/systemd/system/bhttp.service
    
    systemctl daemon-reload
    systemctl restart bhttp
    echo -e "${GREEN}[✓] ¡Puerto cambiado con éxito al $NUEVO_PUERTO!${NC}"
    sleep 2
}

# Bucle principal del menú
while true; do
    get_status
    clear
    echo -e "${CYAN}======================================================${NC}"
    echo -e "${PURPLE}          PANEL DE CONTROL BHTTP - VPS                ${NC}"
    echo -e "${CYAN}======================================================${NC}"
    echo -e "  ${YELLOW}Estado del Servicio :${NC} $ESTADO"
    echo -e "  ${YELLOW}Puerto Activo       :${NC} ${BLUE}$PUERTO_ACTUAL${NC}"
    echo -e "${CYAN}------------------------------------------------------${NC}"
    echo -e "  ${GREEN}[1]${NC} Cambiar Puerto de Escucha"
    echo -e "  ${GREEN}[2]${NC} Reiniciar Servidor BHTTP"
    echo -e "  ${GREEN}[3]${NC} Iniciar / Detener Servicio"
    echo -e "  ${GREEN}[4]${NC} Ver Monitor de Conexiones (Logs en vivo)"
    echo -e "  ${RED}[5]${NC} Desinstalar BHTTP por completo"
    echo -e "  ${YELLOW}[0]${NC} Salir del Panel"
    echo -e "${CYAN}======================================================${NC}"
    echo -ne "${YELLOW}Selecciona una opción [0-5]: ${NC}"
    read OPCION

    case $OPCION in
        1)
            cambiar_puerto
            ;;
        2)
            echo -e "\n${BLUE}[*] Reiniciando servicio...${NC}"
            systemctl restart bhttp
            echo -e "${GREEN}[✓] Servicio reiniciado.${NC}"
            sleep 1.5
            ;;
        3)
            if systemctl is-active --quiet bhttp; then
                systemctl stop bhttp
                echo -e "\n${YELLOW}[!] Servicio detenido.${NC}"
            else
                systemctl start bhttp
                echo -e "\n${GREEN}[✓] Servicio iniciado.${NC}"
            fi
            sleep 1.5
            ;;
        4)
            echo -e "\n${CYAN}[*] Mostrando logs en vivo (Presiona Ctrl + C para salir)...${NC}\n"
            sleep 1
            journalctl -u bhttp -f
            ;;
        5)
            echo -ne "\n${RED}¿Estás seguro de que quieres desinstalar BHTTP? (s/n): ${NC}"
            read CONFIRMAR
            if [[ "$CONFIRMAR" == "s" || "$CONFIRMAR" == "S" ]]; then
                systemctl stop bhttp 2>/dev/null
                systemctl disable bhttp 2>/dev/null
                rm -f /etc/systemd/system/bhttp.service
                rm -rf /usr/local/lib/bhttp
                rm -f /usr/local/bin/menu
                systemctl daemon-reload
                echo -e "${GREEN}[✓] BHTTP y el menú han sido eliminados.${NC}"
                exit 0
            fi
            ;;
        0)
            echo -e "\n${CYAN}¡Hasta luego!${NC}"
            exit 0
            ;;
        *)
            echo -e "\n${RED}[!] Opción inválida.${NC}"
            sleep 1
            ;;
    esac
done
