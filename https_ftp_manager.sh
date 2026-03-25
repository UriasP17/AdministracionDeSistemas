#!/bin/bash

# ==========================================
# SCRIPT DE GESTION DE SERVIDORES WEB (FEDORA)
# ==========================================

if [ "$EUID" -ne 0 ]; then
    echo "[!] Ejecuta el script con sudo."
    sleep 4
    exit
fi

# Detectar IP activa de la maquina virtual
IP=$(ip addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
if [ -z "$IP" ]; then IP="localhost"; fi

C_GREEN="\e[32m"
C_CYAN="\e[36m"
C_YELLOW="\e[33m"
C_RED="\e[31m"
C_RESET="\e[0m"

# Función general para limpiar puertos y servicios
limpiar_entorno() {
    local p="$1"
    echo -e "${C_CYAN}[*] Limpiando puerto $p...${C_RESET}"
    systemctl stop httpd nginx tomcat &>/dev/null
    
    local pid=$(fuser $p/tcp 2>/dev/null)
    if [ ! -z "$pid" ]; then
        kill -9 $pid &>/dev/null
    fi
    sleep 2
}

# ==================================
# APACHE
# ==================================
instalar_apache() {
    read -p "Ingresa puerto para Apache (ej. 80, 8080): " puerto
    if [[ ! "$puerto" =~ ^[0-9]+$ ]]; then puerto=80; fi

    limpiar_entorno $puerto
    
    echo -e "${C_YELLOW}[*] Verificando Apache (httpd)...${C_RESET}"
    if ! rpm -qa | grep -q httpd; then
        dnf install -y httpd
    fi

    # Configurar puerto en httpd.conf
    sed -i "s/^Listen .*/Listen $puerto/" /etc/httpd/conf/httpd.conf
    
    # Crear página estática chida
    cat <<EOF > /var/www/html/index.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>APACHE</title><style>
body { font-family: sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; background: #fafafa; margin: 0; }
.box { text-align: center; }
.dot { width: 15px; height: 15px; background: #D32F2F; border-radius: 50%; display: inline-block; margin-bottom: 20px; }
h1 { margin: 0 0 10px; }
</style></head><body><div class="box"><div class="dot"></div><h1>APACHE FEDORA</h1><p>www.reprobados.com - Puerto $puerto</p></div></body></html>
EOF

    systemctl restart httpd
    firewall-cmd --add-port=$puerto/tcp --permanent &>/dev/null
    firewall-cmd --reload &>/dev/null
    
    echo -e "${C_GREEN}[+] Apache corriendo en http://$IP:$puerto${C_RESET}"
    sleep 3
}

# ==================================
# NGINX
# ==================================
instalar_nginx() {
    read -p "Ingresa puerto para Nginx (ej. 80, 8080): " puerto
    if [[ ! "$puerto" =~ ^[0-9]+$ ]]; then puerto=80; fi

    limpiar_entorno $puerto
    
    echo -e "${C_YELLOW}[*] Verificando Nginx...${C_RESET}"
    if ! rpm -qa | grep -q nginx; then
        dnf install -y nginx
    fi

    # Configurar Nginx globalmente
    sed -i "s/listen       [0-9]* default_server;/listen       $puerto default_server;/" /etc/nginx/nginx.conf

    # Crear página estática chida
    cat <<EOF > /usr/share/nginx/html/index.html
<!DOCTYPE html><html><head><meta charset="UTF-8"><title>NGINX</title><style>
body { font-family: sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; background: #fafafa; margin: 0; }
.box { text-align: center; }
.dot { width: 15px; height: 15px; background: #009688; border-radius: 50%; display: inline-block; margin-bottom: 20px; }
h1 { margin: 0 0 10px; }
</style></head><body><div class="box"><div class="dot"></div><h1>NGINX FEDORA</h1><p>www.reprobados.com - Puerto $puerto</p></div></body></html>
EOF

    systemctl restart nginx
    firewall-cmd --add-port=$puerto/tcp --permanent &>/dev/null
    firewall-cmd --reload &>/dev/null
    
    echo -e "${C_GREEN}[+] Nginx corriendo en http://$IP:$puerto${C_RESET}"
    sleep 3
}

# ==================================
# TOMCAT (CON PARCHE DE PUERTOS BAJOS)
# ==================================
instalar_tomcat() {
    read -p "Ingresa puerto para Tomcat (ej. 80, 8080): " puerto
    if [[ ! "$puerto" =~ ^[0-9]+$ ]]; then puerto=8080; fi

    limpiar_entorno $puerto
    
    echo -e "${C_YELLOW}[*] Verificando Java y Tomcat...${C_RESET}"
    dnf install -y java-11-openjdk tomcat tomcat-webapps tomcat-admin-webapps &>/dev/null

    # 1. Tomcat SIEMPRE correra internamente en el 8080 (para que no llore por permisos root)
    sed -i 's/port="[0-9]\+" protocol="HTTP\/1.1"/port="8080" protocol="HTTP\/1.1"/' /etc/tomcat/server.xml

    # 2. Reemplazar la app ROOT por defecto de Tomcat con nuestra pagina
    mkdir -p /var/lib/tomcat/webapps/ROOT
    cat <<EOF > /var/lib/tomcat/webapps/ROOT/index.jsp
<%@ page language="java" contentType="text/html; charset=UTF-8" pageEncoding="UTF-8"%>
<!DOCTYPE html><html><head><title>TOMCAT</title><style>
body { font-family: sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; background: #fafafa; margin: 0; }
.box { text-align: center; }
.dot { width: 15px; height: 15px; background: #FFC107; border-radius: 50%; display: inline-block; margin-bottom: 20px; }
h1 { margin: 0 0 10px; }
</style></head><body><div class="box"><div class="dot"></div><h1>TOMCAT FEDORA</h1><p>www.reprobados.com - Puerto solicitado: $puerto</p></div></body></html>
EOF
    chown -R tomcat:tomcat /var/lib/tomcat/webapps/ROOT

    # 3. Arrancar Tomcat en su puerto natural (8080)
    systemctl restart tomcat
    
    # 4. TRUCO DE MAGIA: Si el usuario pidio un puerto menor a 1024, usamos firewalld para redirigir el trafico
    if [ "$puerto" -ne 8080 ]; then
        echo -e "${C_CYAN}[*] Enrutando puerto $puerto hacia 8080 internamente (Bypass de root)...${C_RESET}"
        firewall-cmd --add-forward-port=port=$puerto:proto=tcp:toport=8080 --permanent &>/dev/null
    fi
    
    firewall-cmd --add-port=8080/tcp --permanent &>/dev/null
    firewall-cmd --add-port=$puerto/tcp --permanent &>/dev/null
    firewall-cmd --reload &>/dev/null

    echo -e "${C_GREEN}[+] Tomcat corriendo en http://$IP:$puerto${C_RESET}"
    sleep 3
}

# ==================================
# DESINSTALAR
# ==================================
desinstalar_servicio() {
    local svc="$1"
    echo -e "${C_RED}[!] Desinstalando y borrando rastros de $svc...${C_RESET}"
    systemctl stop $svc &>/dev/null
    systemctl disable $svc &>/dev/null
    
    if [ "$svc" == "httpd" ] || [ "$svc" == "apache" ]; then
        dnf remove -y httpd
        rm -rf /etc/httpd /var/www/html
    elif [ "$svc" == "nginx" ]; then
        dnf remove -y nginx
        rm -rf /etc/nginx /usr/share/nginx/html
    elif [ "$svc" == "tomcat" ]; then
        dnf remove -y tomcat java-11-openjdk
        rm -rf /etc/tomcat /var/lib/tomcat
        # Limpiar posibles reglas de redireccion de firewall
        firewall-cmd --remove-forward-port=port=80:proto=tcp:toport=8080 --permanent &>/dev/null
        firewall-cmd --reload &>/dev/null
    fi
    echo -e "${C_GREEN}[OK] $svc eliminado del sistema.${C_RESET}"
    sleep 2
}

# ==================================
# MENU
# ==================================
while true; do
    clear
    echo -e "${C_CYAN}======================================================${C_RESET}"
    echo -e "   GESTOR WEB FEDORA (P07) - IP: $IP"
    echo -e "${C_CYAN}======================================================${C_RESET}"
    echo " 1) Instalar Apache"
    echo " 2) Instalar Nginx"
    echo " 3) Instalar Tomcat"
    echo "------------------------------------------------------"
    echo " 4) Desinstalar Apache"
    echo " 5) Desinstalar Nginx"
    echo " 6) Desinstalar Tomcat"
    echo " 0) Salir"
    echo -e "${C_CYAN}======================================================${C_RESET}"
    
    read -p "Elige una opcion: " opcion
    
    case "$opcion" in
        1) instalar_apache ;;
        2) instalar_nginx ;;
        3) instalar_tomcat ;;
        4) desinstalar_servicio "apache" ;;
        5) desinstalar_servicio "nginx" ;;
        6) desinstalar_servicio "tomcat" ;;
        0) echo "Saliendo del script..."; break ;;
        *) echo -e "${C_RED}[X] Opcion no valida.${C_RESET}" ; sleep 2 ;;
    esac
done
