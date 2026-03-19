#!/bin/bash

# ==========================================
# SCRIPT DE GESTION DE SERVIDORES WEB (FEDORA)
# ==========================================

if [ "$EUID" -ne 0 ]; then
    echo "[-] Ejecuta el script con sudo."
    sleep 4
    exit 1
fi

# ==========================================
# DETECTAR IP DEL ADAPTADOR PUENTE (.20)
# ==========================================
VM_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -E '\.20$|^192\.168\.56\.' | head -n 1)

if [ -z "$VM_IP" ]; then
    echo -e "\e[33m[-] No se detecto automaticamente la IP de la red puente.\e[0m"
    read -p "Ingresa tu IP puente manualmente (ej. 192.168.56.20): " VM_IP
fi

instalar_dependencias_base() {
    echo "[*] Verificando dependencias base..."
    dnf install -y curl net-tools firewalld psmisc iproute >/dev/null 2>&1
    systemctl enable firewalld --now >/dev/null 2>&1
}

solicitarPuerto() {
    local servicio=$1
    local puerto
    local reservedPorts=(20 21 22 23 25 53 110 143 445 3306 3389 5432)
    
    while true; do
        read -p "Ingresa puerto para $servicio (ej. 8080, 81): " puerto
        [ -z "$puerto" ] && puerto=8080
        
        if [[ ! "$puerto" =~ ^[0-9]+$ ]] || [ "$puerto" -le 0 ] || [ "$puerto" -gt 65535 ]; then
            echo -e "\e[31m[-] Solo numeros permitidos.\e[0m" >&2; continue
        fi
        
        if [[ " ${reservedPorts[*]} " =~ " ${puerto} " ]]; then
            echo -e "\e[31m[-] Puerto $puerto reservado por el sistema. Elige otro.\e[0m" >&2; continue
        fi
        
        # Omitimos escanear con ss y dejamos que firewalld/semanage se quejen si de verdad esta en uso
        if ss -tuln | grep -q ":$puerto "; then
            echo -e "\e[31m[-] El puerto $puerto ya esta ocupado. Intenta con otro.\e[0m" >&2; continue
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

limpiar_firewall() {
    # Busca y remueve todos los puertos que se hayan abierto manuales (para liberar de verdad)
    local puertos_activos=$(firewall-cmd --list-ports | grep -oP '\d+(?=/tcp)')
    for p in $puertos_activos; do
        firewall-cmd --permanent --remove-port="$p"/tcp >/dev/null 2>&1
    done
    firewall-cmd --reload >/dev/null 2>&1
}

crear_index() {
    local ruta=$1 servicio=$2 version=$3 puerto=$4
    mkdir -p "$ruta"
    # ======== DISENO MINIMALISTA BLANCO (IGUAL AL DE WINDOWS) ========
    cat <<HTMLEOF > "$ruta/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>$servicio - Port $puerto</title>
  <style>
    body { 
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
        background-color: #f8f9fa; 
        color: #333; 
        display: flex;
        justify-content: center;
        align-items: center;
        height: 100vh;
        margin: 0;
    }
    .card { 
        background: #ffffff; 
        padding: 40px; 
        border-radius: 8px; 
        box-shadow: 0 4px 6px rgba(0,0,0,0.05); 
        text-align: left;
        min-width: 300px;
        border-top: 4px solid #0078D7;
    }
    h2 { 
        color: #333; 
        margin-top: 0;
        font-weight: 500;
        border-bottom: 1px solid #eee;
        padding-bottom: 10px;
    }
    .info-row {
        margin: 12px 0;
        font-size: 14px;
    }
    .label {
        color: #666;
        display: inline-block;
        width: 100px;
    }
    .value {
        font-weight: 500;
        color: #000;
    }
    .code-block {
        background: #f1f3f5;
        padding: 8px 12px;
        border-radius: 4px;
        font-family: monospace;
        font-size: 13px;
        color: #0078D7;
        margin-top: 20px;
    }
  </style>
</head>
<body>
  <div class="card">
      <h2>Servidor Activo</h2>
      <div class="info-row">
          <span class="label">Servicio:</span>
          <span class="value">$servicio</span>
      </div>
      <div class="info-row">
          <span class="label">Version:</span>
          <span class="value">$version</span>
      </div>
      <div class="info-row">
          <span class="label">Puerto:</span>
          <span class="value">$puerto</span>
      </div>
      <div class="code-block">http://${VM_IP}:${puerto}</div>
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
    
    sed -i "s/^Listen .*/Listen $puerto/" /etc/httpd/conf/httpd.conf
    
    crear_index "$vhost_dir" "Apache" "$version" "$puerto"
    
    if command -v semanage &>/dev/null; then
        semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null
    fi
    
    configurar_firewall "$puerto"
    
    echo -e "\e[33m[*] Arrancando motor de Apache...\e[0m"
    systemctl enable httpd --now >/dev/null 2>&1
    systemctl restart httpd >/dev/null 2>&1
    
    echo -e "\e[32m[+] apache instalado en puerto $puerto.\e[0m"
    echo -e "\e[33m[>] URL: http://${VM_IP}:${puerto}\e[0m"
}

instalar_nginx() {
    echo -e "\n\e[33m[*] Preparando instalacion de nginx...\e[0m"
    instalar_dependencias_base
    local puerto=$(solicitarPuerto "nginx")
    
    echo -e "\e[36m[*] Instalando nginx desde DNF...\e[0m"
    dnf install -y nginx >/dev/null 2>&1
    
    local version=$(rpm -q nginx --queryformat "%{version}")
    local vhost_dir="/usr/share/nginx/html"
    
    sed -i "s/listen       80;/listen       ${VM_IP}:${puerto};/" /etc/nginx/nginx.conf
    sed -i "s/listen       \[::\]:80;/#listen       \[::\]:80;/" /etc/nginx/nginx.conf
    
    crear_index "$vhost_dir" "Nginx" "$version" "$puerto"
    
    if command -v semanage &>/dev/null; then
        semanage port -a -t http_port_t -p tcp "$puerto" 2>/dev/null || \
        semanage port -m -t http_port_t -p tcp "$puerto" 2>/dev/null
    fi
    
    configurar_firewall "$puerto"
    
    echo -e "\e[33m[*] Arrancando motor de Nginx...\e[0m"
    systemctl enable nginx --now >/dev/null 2>&1
    systemctl restart nginx >/dev/null 2>&1
    
    echo -e "\e[32m[+] nginx instalado en puerto $puerto.\e[0m"
    echo -e "\e[33m[>] URL: http://${VM_IP}:${puerto}\e[0m"
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
    
    echo -e "\e[33m[*] Arrancando motor de Tomcat...\e[0m"
    systemctl enable tomcat --now >/dev/null 2>&1
    systemctl restart tomcat >/dev/null 2>&1
    
    echo -e "\e[32m[+] tomcat instalado en puerto $puerto.\e[0m"
    echo -e "\e[33m[>] URL: http://${VM_IP}:${puerto}\e[0m"
}

desinstalar_servicio() {
    local servicio=$1
    local paquete=$1
    [ "$servicio" == "apache" ] && paquete="httpd"
    
    echo -e "\n\e[33m[*] Desinstalando $servicio y liberando puerto...\e[0m"
    
    # 1. Parar el servicio civilizadamente
    systemctl stop "$paquete" >/dev/null 2>&1
    systemctl disable "$paquete" >/dev/null 2>&1
    
    # 2. Matar procesos zombies como en Windows
    if [ "$servicio" == "tomcat" ]; then
        pkill -9 -f "java.*tomcat" >/dev/null 2>&1
    else
        pkill -9 -f "$paquete" >/dev/null 2>&1
    fi
    
    # 3. Remover paquete
    dnf remove -y "$paquete" >/dev/null 2>&1
    
    # 4. Limpieza profunda de directorios
    if [ "$servicio" == "apache" ]; then
        rm -rf /etc/httpd /var/www/html/*
    elif [ "$servicio" == "nginx" ]; then
        rm -rf /etc/nginx /usr/share/nginx/html/*
    elif [ "$servicio" == "tomcat" ]; then
        rm -rf /etc/tomcat /var/lib/tomcat/webapps/*
    fi
    
    # 5. Limpiar reglas del firewall para reusar puertos
    limpiar_firewall
    
    echo -e "\e[32m[-] $servicio desinstalado. Puerto liberado.\e[0m"
}

while true; do
    echo -e "\n\e[36m=== MENU FEDORA SERVER ===\e[0m"
    echo "1) Instalar Apache"
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
        0) echo "Saliendo..."; break ;;
        *) echo -e "\e[31m[-] Opcion no valida.\e[0m" ;;
    esac
done
