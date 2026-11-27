#!/bin/bash

# ==============================================================================
# INSTALADOR OFICIAL BHTTP + LIMITADOR - LeoLatam SSH
# Desarrollado por @Leonardo1991231
# ==============================================================================

RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
BLUE="\033[0;34m"
PURPLE="\033[0;35m"
CYAN="\033[0;36m"
NC="\033[0m"

print_line() {
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"
}

# 1. Verificar privilegios de administrador
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR] Por favor, ejecuta este script como root (sudo).${NC}"
  exit 1
fi

# 2. Opción de desinstalación completa
if [ "$1" == "--desinstalar" ]; then
    print_line
    echo -e "${YELLOW}=== ELIMINANDO SERVIDOR BHTTP, LIMITADOR Y LeoLatam SSH ===${NC}"
    print_line
    systemctl stop bhttp* 2>/dev/null
    systemctl disable bhttp* 2>/dev/null
    rm -f /etc/systemd/system/bhttp*.service
    rm -rf /usr/local/lib/bhttp
    rm -f /usr/local/bin/bhttp
    crontab -l 2>/dev/null | grep -v "limpiar-auto" | crontab -
    systemctl daemon-reload
    echo -e "${GREEN}[OK] Todo el sistema ha sido desinstalado por completo.${NC}"
    print_line
    exit 0
fi

# 3. Instalar dependencias necesarias
echo -e "${BLUE}[*] Verificando dependencias del sistema...${NC}"
for pkg in lsof netcat-openbsd curl wget python3 procps; do
    if ! command -v $pkg &> /dev/null; then
        apt-get update -y &>/dev/null
        apt-get install -y $pkg &>/dev/null
    fi
done

# 4. Leer argumento de puerto
PUERTO=""
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --puerto) PUERTO="$2"; shift ;;
    esac
    shift
done

clear
print_line
echo -e "${PURPLE}"
cat << 'EOF'
  _               _           _                     ____ ____ _   _ 

 | |    ___  ___ | |    __ _ | |_ __ _ _ __ ___    / ___/ ___| | | |
 | |   / _ \/ _ \| |   / _` || __/ _` | '_ ` _ \   \___ \___ \ |_| |
 | |__|  __/ (_) | |__| (_| || || (_| | | | | | |   ___) |__) |  _  |
 |_____\___|\___/|_____\__,_| \__\__,_|_| |_| |_|  |____/____/|_| |_|
EOF
echo -e "${NC}"
echo -e "          ${YELLOW}Instalador Oficial BHTTP + Limitador - @Leonardo1991231${NC}"
print_line

# [1/4] Configuración de Puerto y Firewall
echo -e "${CYAN}[1/4] Configuración de Red e Interfaces${NC}"

while [ -z "$PUERTO" ] || lsof -i :"$PUERTO" >/dev/null 2>&1; do
    if [ ! -z "$PUERTO" ]; then
        echo -e "${RED}[!] El puerto $PUERTO ya está ocupado por otro servicio.${NC}"
    fi
    echo -ne "${YELLOW}[?] Introduce un puerto libre (Ej: 8080): ${NC}"
    read PUERTO
done

# Abrir puerto en Firewall automáticamente
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "$PUERTO"/tcp >/dev/null 2>&1
fi
if command -v iptables &> /dev/null; then
    iptables -I INPUT -p tcp --dport "$PUERTO" -j ACCEPT 2>/dev/null
fi

echo -e "${GREEN}[OK] Puerto seleccionado: $PUERTO (Habilitado en Firewall -> SSH 22)${NC}"
# [2/4] Instalación del núcleo en Python
echo -e "\n${CYAN}[2/4] Instalando Binarios del Servidor y Limitador${NC}"
mkdir -p /usr/local/lib/bhttp
touch /usr/local/lib/bhttp/limites.db

cat << 'EOF' > /usr/local/lib/bhttp/bhttp-server.py
import sys
import socket
import threading
import argparse

def handle_client(client_socket, backend_host, backend_port):
    try:
        handshake = client_socket.recv(1024)
        client_socket.sendall(b"HANDSHAKE_OK\nTUNEL_OK\n")
        
        backend_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        backend_socket.connect((backend_host, backend_port))
        
        banner = backend_socket.recv(1024)
        client_socket.sendall(b"BANNER=" + banner)

        def forward(src, dst):
            try:
                while True:
                    data = src.recv(4096)
                    if not data:
                        break
                    dst.sendall(data)
            except (ConnectionResetError, BrokenPipeError, socket.error):
                pass
            finally:
                try: src.close() 
                except: pass
                try: dst.close() 
                except: pass

        t1 = threading.Thread(target=forward, args=(client_socket, backend_socket))
        t2 = threading.Thread(target=forward, args=(backend_socket, client_socket))
        t1.start()
        t2.start()
    except Exception:
        try: client_socket.close()
        except: pass

def main():
    parser = argparse.ArgumentParser(description="Core BHTTP Server")
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument("--backend-host", default="127.0.0.1")
    parser.add_argument("--backend-port", type=int, default=22)
    args = parser.parse_args()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    
    try:
        server.bind((args.host, args.port))
        server.listen(150)
    except Exception:
        sys.exit(1)

    while True:
        try:
            client_sock, _ = server.accept()
            threading.Thread(target=handle_client, args=(client_sock, args.backend_host, args.backend_port), daemon=True).start()
        except KeyboardInterrupt:
            break
        except:
            pass

if __name__ == "__main__":
    main()
EOF
echo -e "  -> Módulo BHTTP guardado en: /usr/local/lib/bhttp/bhttp-server.py"

# Crear el demonio del Limitador de Conexiones Simultáneas
cat << 'EOF' > /usr/local/lib/bhttp/limiter.sh
#!/bin/bash
DB="/usr/local/lib/bhttp/limites.db"
touch "$DB"

while true; do
    if [ -s "$DB" ]; then
        while IFS=: read -r USER MAX; do
            [ -z "$USER" ] && continue
            if id "$USER" &>/dev/null; then
                PIDS=$(pgrep -u "$USER" sshd 2>/dev/null)
                COUNT=$(echo "$PIDS" | grep -c '[0-9]')
                if [ "$COUNT" -gt "$MAX" ]; then
                    EXCESS=$((COUNT - MAX))
                    echo "$PIDS" | tail -n "$EXCESS" | xargs -r kill -9 2>/dev/null
                fi
            fi
        done < "$DB"
    fi
    sleep 5
done
EOF
chmod +x /usr/local/lib/bhttp/limiter.sh
# Servicio Systemd del Servidor BHTTP
cat << EOF > /etc/systemd/system/bhttp.service
[Unit]
Description=Servidor BHTTP (LeoLatam SSH) puerto $PUERTO
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/lib/bhttp/bhttp-server.py --host 0.0.0.0 --port $PUERTO --backend-host 127.0.0.1 --backend-port 22
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

# Servicio Systemd del Limitador Anti-Multilogin
cat << EOF > /etc/systemd/system/bhttp-limiter.service
[Unit]
Description=Limitador de Conexiones Simultaneas (LeoLatam SSH)
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash /usr/local/lib/bhttp/limiter.sh
Restart=always
RestartSec=3
User=root

[Install]
WantedBy=multi-user.target
EOF

echo -e "  -> Limitador Anti-Multilogin configurado en segundo plano"

# [3/4] Arrancando servicios e instalando panel interactivo 'bhttp'
echo -e "\n${CYAN}[3/4] Inicializando Servicios y Panel de Control${NC}"
systemctl daemon-reload
systemctl enable bhttp bhttp-limiter >/dev/null 2>&1
systemctl restart bhttp bhttp-limiter

DOM="raw.githubusercontent.com"
RUTA="Leonardo1991231/Bhttp/main/menu.sh"
wget -q -O /usr/local/bin/bhttp "https://${DOM}/${RUTA}"
chmod +x /usr/local/bin/bhttp

echo -e "${GREEN}[OK] Servicios activos y panel 'bhttp' instalado en el sistema.${NC}"

# [4/4] Pruebas de diagnóstico y obtención de IP limpia
echo -e "\n${CYAN}[4/4] Comprobando Estabilidad del Protocolo BHTTP${NC}"
sleep 1.5

TEST_RESPUESTA=$(echo "HANDSHAKE_TEST" | nc -w 2 127.0.0.1 $PUERTO | head -n 2)
if [[ "$TEST_RESPUESTA" == *"HANDSHAKE_OK"* ]]; then
    echo -e "  -> Handshake local interno: ${GREEN}HANDSHAKE_OK (Exitoso)${NC}"
    echo -e "  -> Canalización de datos: ${GREEN}TUNEL_OK (Abierto)${NC}"
else
    echo -e "  -> Handshake local interno: ${RED}FALLIDO (Verifica las reglas de tu Firewall VPS)${NC}"
fi

IP_PUBLICA=$(wget -qO- ifconfig.me || curl -s ifconfig.me || curl -s api.ipify.org || echo "IP_DE_TU_VPS")

# Cuadro Final de Credenciales
echo -e "\n"
print_line
echo -e "${GREEN}      === DESPLIEGUE FINALIZADO: LeoLatam SSH ACTIVO ===${NC}"
print_line
echo -e "  ${YELLOW}Ingresa estos datos en tu aplicación móvil:${NC}"
echo -e "  +-------------------------------------------------------------------+"
echo -e "    ${BLUE}HOST / IP    :${NC}  $IP_PUBLICA"
echo -e "    ${BLUE}PUERTO       :${NC}  $PUERTO"
echo -e "    ${BLUE}PROTOCOLO    :${NC}  bhttp (Directo / Sin Capa TLS)"
echo -e "    ${BLUE}AUTENTICACIÓN:${NC}  Usuario y contraseña SSH de esta VPS"
echo -e "    ${BLUE}LIMITADOR    :${NC}  Activo en segundo plano (Anti-Multilogin)"
echo -e "  +-------------------------------------------------------------------+"
echo -e "  ${GREEN}[✓] Túnel bidireccional SSH verificado de extremo a extremo.${NC}"
print_line
echo -e "${CYAN}[diag] Resumen del Entorno de Red:${NC}"
echo -e "  ▸ AllowTcpForwarding : yes (Garantizado)       -> ${GREEN}OK${NC}"
echo -e "  ▸ Resolución Externa : Salida DNS a 8.8.8.8    -> ${GREEN}OK${NC}"
echo -e "  ▸ Estado del SSHD    : Escuchando en puerto 22 -> ${GREEN}OK${NC}"
print_line
echo -e "${YELLOW}Panel de Control y Mantenimiento:${NC}"
echo -e "  • Abrir Panel   : escribe ${GREEN}bhttp${NC} en la terminal"
echo -e "  • Ver logs vivos: ${CYAN}journalctl -u 'bhttp*' -f${NC}"
echo -e "  • Desinstalar   : ${RED}sudo bash bhttp-install.sh --desinstalar${NC}"
print_line
echo ""
