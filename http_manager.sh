#!/bin/bash

# ==========================================
# SCRIPT DE GESTION DE SERVIDORES WEB (FEDORA)
# ==========================================

if [ "$EUID" -ne 0 ]; then
    echo "[!] Ejecuta el script con sudo."
    sleep 4
    exit 1
fi

# ==========================================
# DETECTAR IP DEL ADAPTADOR PUENTE (.20)
# ==========================================
# Busca cualquier IP que termine en .20 o que esté en la subred 192.168.56.
VM_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -E '\.20$|^192\.168\.56\.' | head -n 1)

# Si no la encuentra en automático, te la pide a mano para no regarla
if [ -z "$VM_IP" ]; then
    echo -e "\e[33m[!] No se detecto automaticamente la IP de la 3era red (.20).\e[0m"
    read -p "Ingresa tu IP puente manualmente (ej. 192.168.56.20): " VM_IP
fi

instalar_dependencias_base() {
    echo "[*] Verificando dependencias base..."
    dnf install -y curl net-tools firewalld psmisc iproute >/dev/null 2>&1
    systemctl enable firewalld --now 2>/dev/null
}

solicitarPuerto() {
    local servicio=$1
    local puerto
    local reservedPorts=(20 21 22 23 25 53 110 143 445 3306 3389 5432)
    
    while true; do
        read -p "Ingresa puerto para $servicio (ej. 8080, 81): " puerto
        [ -z "$puerto" ] && puerto=8080
        
        if [[ ! "$puerto" =~ ^[0-9]+$ ]] || [ "$puerto" -le 0 ] || [ "$puerto" -gt 65535 ]; then
            echo -e "\e[31m[!] Ingresa un numero de puerto valido.\e[0m" >&2; continue
        fi
        
        if [[ " ${reservedPorts[*]} " =~ " ${puerto} " ]]; then
            echo -e "\e[31m[!] Puerto $puerto esta reservado por el sistema. Elige otro.\e[0m" >&2; continue
        fi
        
        if ss -tuln | grep -q ":$puerto "; then
            echo -e "\e[31m[!] El puerto $puerto ya esta ocupado. Intenta con otro.\e[0m" >&2; continue
        fi
        
        break
    done
    echo "$puerto"
}

configurar_firewall() {
    local puerto=$1
    firewall-cmd --permanent --add-port="$puerto"/tcp > /dev/null 2>&1
    firewall-cmd --reload > /dev/null 2>&1
}

crear_index() {
    local ruta=$1 servicio=$2 version=$3 puerto=$4
    mkdir -p "$ruta"
    cat <<HTMLEOF > "$ruta/index.html"
<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <title>$servicio - Puerto $puerto</title>
  <style>
    body { font-family: Arial, sans-serif; background-color: #f4f4f9; color: #333; text-align: center; padding: 50px; }
    .container { background: white; padding: 30px; border-radius: 10px; box-shadow: 0px 0px 10px rgba(0,0,0,0.1); display: inline-block; }
    h1 { color: #0078D7; }
  </style>
</head>
<body>
  <div class="container">
      <h1>¡Servidor Activo!</h1>
      <p><strong>Servidor:</strong> $servicio</p>
      <p><strong>Version:</strong> $version</p>
      <p><strong>Puerto:</strong> $puerto</p>
      <p><strong>IP VirtualBox:</strong> $VM_IP</p>
      <p>URL: http://${VM_IP}:${puerto}</p>
  </div>
</body>
</html>
HTMLEOF
}

instalar_apache() {
    echo -e "\n\e[33m[*] Preparando instalacion de apache...\e[0m"
    instalar_dependencias_base
    local puerto=$(solicitarPuerto "apache")
    
    echo -e "\e[36m[*] Instalando apache (httpd) desde DNF...\e[0m"
    dnf install -y httpd >/dev/null 2>&1
    
    local version=$(rpm -q httpd --queryformat "%{version}")
    local vhost_dir="/var/www/html"
    
    # Configurar puerto
    sed -i "s/^Listen .*/Listen $puerto/" /etc/httpd/conf/httpd.conf
    
    crear_index "$vhost_dir" "Apache (httpd)" "$version" "$puerto"
    
    if command -v semanage &>/dev/null; then
        semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null
    fi
    
    configurar_firewall "$puerto"
    
    echo -e "\e[33m[*] Arrancando Apache en segundo plano...\e[0m"
    systemctl enable httpd --now >/dev/null 2>&1
    systemctl restart httpd >/dev/null 2>&1
    
    echo -e "\e[32m[+] apache instalado correctamente.\e[0m"
    echo -e "\e[33m[>] Abre en tu Host: http://${VM_IP}:${puerto}\e[0m"
}

instalar_nginx() {
    echo -e "\n\e[33m[*] Preparando instalacion de nginx...\e[0m"
    instalar_dependencias_base
    local puerto=$(solicitarPuerto "nginx")
    
    echo -e "\e[36m[*] Instalando nginx desde DNF...\e[0m"
    dnf install -y nginx >/dev/null 2>&1
    
    local version=$(rpm -q nginx --queryformat "%{version}")
    local vhost_dir="/usr/share/nginx/html"
    
    # ======= FIX PARA NGINX Y LA RED PUENTE =======
    # Forzamos a Nginx a escuchar especificamente en la IP puente y no en la NAT
    sed -i "s/listen       80;/listen       ${VM_IP}:${puerto};/" /etc/nginx/nginx.conf
    sed -i "s/listen       \[::\]:80;/#listen       \[::\]:80;/" /etc/nginx/nginx.conf
    
    crear_index "$vhost_dir" "Nginx" "$version" "$puerto"
    
    if command -v semanage &>/dev/null; then
        semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null
    fi
    
    configurar_firewall "$puerto"
    
    echo -e "\e[33m[*] Arrancando Nginx en segundo plano...\e[0m"
    systemctl enable nginx --now >/dev/null 2>&1
    systemctl restart nginx >/dev/null 2>&1
    
    echo -e "\e[32m[+] nginx instalado correctamente.\e[0m"
    echo -e "\e[33m[>] Abre en tu Host: http://${VM_IP}:${puerto}\e[0m"
}

instalar_tomcat() {
    echo -e "\n\e[33m[*] Preparando instalacion de tomcat...\e[0m"
    instalar_dependencias_base
    local puerto=$(solicitarPuerto "tomcat")
    
    echo -e "\e[36m[*] Instalando tomcat y java desde DNF...\e[0m"
    dnf install -y tomcat tomcat-webapps java-latest-openjdk-headless >/dev/null 2>&1
    
    local version=$(rpm -q tomcat --queryformat "%{version}")
    local vhost_dir="/var/lib/tomcat/webapps/ROOT"
    mkdir -p "$vhost_dir"
    
    sed -i "s/port=\"8080\"/port=\"$puerto\"/g" /etc/tomcat/server.xml
    
    crear_index "$vhost_dir" "Tomcat" "$version" "$puerto"
    
    if command -v semanage &>/dev/null; then
        semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null
    fi
    
    configurar_firewall "$puerto"
    
    echo -e "\e[33m[*] Arrancando Tomcat en segundo plano...\e[0m"
    systemctl enable tomcat --now >/dev/null 2>&1
    systemctl restart tomcat >/dev/null 2>&1
    
    echo -e "\e[32m[+] tomcat instalado correctamente.\e[0m"
    echo -e "\e[33m[>] Abre en tu Host: http://${VM_IP}:${puerto}\e[0m"
}

desinstalar_servicio() {
    local servicio=$1
    local paquete=$1
    [ "$servicio" == "apache" ] && paquete="httpd"
    
    echo -e "\n\e[33m[*] Desinstalando $servicio...\e[0m"
    
    systemctl stop "$paquete" >/dev/null 2>&1
    systemctl disable "$paquete" >/dev/null 2>&1
    pkill -f "$paquete" >/dev/null 2>&1
    
    dnf remove -y "$paquete" >/dev/null 2>&1
    
    if [ "$servicio" == "apache" ]; then
        rm -rf /etc/httpd /var/www/html/*
    elif [ "$servicio" == "nginx" ]; then
        rm -rf /etc/nginx /usr/share/nginx/html/*
    elif [ "$servicio" == "tomcat" ]; then
        rm -rf /etc/tomcat /var/lib/tomcat/webapps/*
    fi
    
    echo -e "\e[32m[-] $servicio desinstalado y carpetas limpias.\e[0m"
}

while true; do
    echo -e "\n\e[36m======= MENU FEDORA =======\e[0m"
    echo "1) Instalar Apache (httpd)"
    echo "2) Instalar Nginx"
    echo "3) Instalar Tomcat"
    echo "4) Desinstalar Apache"
    echo "5) Desinstalar Nginx"
    echo "6) Desinstalar Tomcat"
    echo "0) Salir"
    
    read -p "Elige una opcion: " opcion
    
    case "$opcion" in
        1) instalar_apache ;;
        2) instalar_nginx ;;
        3) instalar_tomcat ;;
        4) desinstalar_servicio "apache" ;;
        5) desinstalar_servicio "nginx" ;;
        6) desinstalar_servicio "tomcat" ;;
        0) echo "Saliendo del script..."; break ;;
        *) echo -e "\e[31m[X] Opcion no valida.\e[0m" ;;
    esac
done
