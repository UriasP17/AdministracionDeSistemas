#!/bin/bash

# Colores para la consola
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

PUERTOS_BLOQUEADOS=(1 7 9 11 13 15 17 19 20 21 22 23 25 37 42 43 53 69 77 79 87 95 101 102 103 104 109 110 111 113 115 117 119 123 135 139 142 143 179 389 465 512 513 514 515 526 530 531 532 540 548 554 556 563 587 601 636 993 995 2049 3659 4045 6000 6665 6666 6667 6668 6669 6697)

PUERTO_ACTUAL="N/A"


if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[!] Por favor ejecuta este script como root (sudo su).${NC}"
  exit
fi

# Deshabilitar SELinux temporalmente para evitar problemas de permisos con puertos custom y certificados
setenforce 0 2>/dev/null
echo -e "${GRAY}[*] SELinux ajustado a Permissive para la practica.${NC}"

# ================================================================
# LIMPIEZA Y PAGINA
# ================================================================
Limpiar_Entorno() {
    local puerto=$1
    echo -e "${GRAY}[*] Limpiando servicios en puerto $puerto...${NC}"
    systemctl stop nginx httpd tomcat vsftpd 2>/dev/null
    fuser -k ${puerto}/tcp 2>/dev/null
    sleep 2
}

Crear_Pagina() {
    local servicio=$1
    local puerto=$2
    local path=""
    local color="#009688"
    
    if [ "$servicio" == "nginx" ]; then
        path="/usr/share/nginx/html/index.html"
        color="#009688" # Verde
    elif [ "$servicio" == "apache" ]; then
        path="/var/www/html/index.html"
        color="#D32F2F" # Rojo
    elif [ "$servicio" == "tomcat" ]; then
        mkdir -p /var/lib/tomcat/webapps/ROOT 2>/dev/null
        path="/var/lib/tomcat/webapps/ROOT/index.html"
        color="#F57C00" # Naranja para Tomcat
    fi

    mkdir -p "$(dirname "$path")" 2>/dev/null
    local servNombre=${servicio^^}

    # HTML Modificado: Texto ASCII limpio para evitar símbolos raros en los navegadores
    cat <<EOF > "$path"
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="UTF-8">
<title>$servNombre</title>
<style>
  body { margin: 0; font-family: sans-serif; display: flex; align-items: center; justify-content: center; min-height: 100vh; background: #fafafa; color: #111; }
  .wrap { text-align: center; }
  .dot { width: 10px; height: 10px; border-radius: 50%; background: $color; display: inline-block; margin-bottom: 2rem; }
  h1 { font-size: 1.6rem; font-weight: 600; margin: 0 0 .4rem; }
  .badge { display: inline-block; margin: 1.2rem 0; padding: .3rem .9rem; border: 1.5px solid $color; color: $color; font-size: .85rem; border-radius: 99px; }
  .meta { font-size: .85rem; color: #777; margin-top: .5rem; }
</style>
</head>
<body>
<div class="wrap">
  <div class="dot"></div>
  <h1>$servNombre</h1>
  <div class="badge">Servicio Activo</div>
  <div class="meta">www.reprobados.com - Puerto: $puerto</div>
</div>
</body>
</html>
EOF
}

# ================================================================
# CERTIFICADO SSL Y FIREWALL
# ================================================================
Generar_Certificado_SSL() {
    local dir="/etc/ssl/reprobados"
    local crt="$dir/reprobados.crt"
    local key="$dir/reprobados.key"

    mkdir -p $dir

    if [ -f "$crt" ] && [ -f "$key" ]; then
        echo -e "${YELLOW}[*] Reutilizando certificado existente en $dir${NC}"
        return 0
    fi

    echo -e "${CYAN}[*] Generando certificado SSL con OpenSSL...${NC}"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout $key -out $crt -subj "/C=MX/ST=Sinaloa/L=LosMochis/O=Reprobados/CN=www.reprobados.com" 2>/dev/null
    
    # Darle permisos para que otros servicios (como Tomcat) lo puedan leer
    chmod 644 $crt
    chmod 644 $key

    echo -e "${GREEN}[OK] Certificados creados en $dir${NC}"
}

Abrir_Firewall() {
    local puerto=$1
    echo -e "${GRAY}[*] Abriendo puerto $puerto en el firewall...${NC}"
    firewall-cmd --add-port=${puerto}/tcp --permanent >/dev/null 2>&1
    firewall-cmd --add-port=80/tcp --permanent >/dev/null 2>&1
    firewall-cmd --add-port=443/tcp --permanent >/dev/null 2>&1
    firewall-cmd --add-port=21/tcp --permanent >/dev/null 2>&1
    firewall-cmd --reload >/dev/null 2>&1
}

# ================================================================
# DESPLIEGUE POR SERVICIO
# ================================================================
Aplicar_Despliegue() {
    local servicio=$1

    echo ""
    read -p "Ingrese el puerto para $servicio (ej. 8080, 8443, 9090): " P_Ingresado
    
    if [[ "$P_Ingresado" =~ ^[0-9]+$ ]]; then
        P=$P_Ingresado
    else
        echo -e "${YELLOW}[!] Puerto invalido, usando puerto por defecto: $PUERTO_ACTUAL${NC}"
        P=$PUERTO_ACTUAL
    fi

    Generar_Certificado_SSL
    read -p "¿Desea activar SSL en este servicio? [S/N]: " respSSL
    usarSSL=false
    if [[ "$respSSL" =~ ^[Ss]$ ]]; then usarSSL=true; fi

    echo -e "${GRAY}[*] Preparando despliegue de $servicio en puerto $P...${NC}"
    Limpiar_Entorno $P
    Abrir_Firewall $P

    case $servicio in
        "nginx")
            local conf="/etc/nginx/nginx.conf"
            local certAbs="/etc/ssl/reprobados/reprobados.crt"
            local keyAbs="/etc/ssl/reprobados/reprobados.key"

            if [ "$usarSSL" = true ]; then
                cat <<EOF > $conf
events { worker_connections 1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    
    server {
        listen       80;
        server_name  www.reprobados.com;
        return 301   https://\$host:$P\$request_uri;
    }

    server {
        listen       $P ssl;
        server_name  www.reprobados.com;
        ssl_certificate      $certAbs;
        ssl_certificate_key  $keyAbs;
        add_header Strict-Transport-Security "max-age=31536000" always;
        location / { root /usr/share/nginx/html; index index.html; }
    }
}
EOF
            else
                cat <<EOF > $conf
events { worker_connections 1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    server {
        listen       $P;
        server_name  www.reprobados.com;
        location / { root /usr/share/nginx/html; index index.html; }
    }
}
EOF
            fi
            Crear_Pagina "nginx" $P
            systemctl start nginx
            ;;

        "apache")
            local conf="/etc/httpd/conf.d/reprobados.conf"
            local certAbs="/etc/ssl/reprobados/reprobados.crt"
            local keyAbs="/etc/ssl/reprobados/reprobados.key"

            # Limpiar configs por defecto de apache para que no choquen
            rm -f /etc/httpd/conf.d/ssl.conf 2>/dev/null
            rm -f /etc/httpd/conf.d/welcome.conf 2>/dev/null

            # Asegurarse de que escuche en los puertos necesarios
            sed -i '/^Listen/d' /etc/httpd/conf/httpd.conf
            echo "Listen $P" >> /etc/httpd/conf/httpd.conf
            if [ "$usarSSL" = true ]; then
                echo "Listen 80" >> /etc/httpd/conf/httpd.conf
            fi

            if [ "$usarSSL" = true ]; then
                cat <<EOF > $conf
<VirtualHost *:80>
    ServerName www.reprobados.com
    Redirect permanent / https://www.reprobados.com:$P/
</VirtualHost>

<VirtualHost *:$P>
    ServerName www.reprobados.com
    DocumentRoot "/var/www/html"
    SSLEngine on
    SSLCertificateFile    "$certAbs"
    SSLCertificateKeyFile "$keyAbs"
    Header always set Strict-Transport-Security "max-age=31536000"
</VirtualHost>
EOF
            else
                cat <<EOF > $conf
<VirtualHost *:$P>
    ServerName www.reprobados.com
    DocumentRoot "/var/www/html"
</VirtualHost>
EOF
            fi
            Crear_Pagina "apache" $P
            systemctl start httpd
            ;;

        "tomcat")
            local conf="/etc/tomcat/server.xml"
            local certAbs="/etc/ssl/reprobados/reprobados.crt"
            local keyAbs="/etc/ssl/reprobados/reprobados.key"

            echo -e "${CYAN}[*] Configurando Tomcat...${NC}"
            cp $conf "${conf}.backup" 2>/dev/null
            
            # Borrar conectores anteriores (limpieza sucia pero efectiva)
            sed -i '/<Connector/d' $conf
            sed -i '/<\/Connector>/d' $conf
            sed -i '/certificateFile/d' $conf
            sed -i '/SSLHostConfig/d' $conf

            if [ "$usarSSL" = true ]; then
                # Inyectar el conector SSL justo antes de </Service>
                sed -i "/<\/Service>/i \\
    <Connector port=\"$P\" protocol=\"org.apache.coyote.http11.Http11NioProtocol\" maxThreads=\"150\" SSLEnabled=\"true\" scheme=\"https\" secure=\"true\" defaultSSLHostConfigName=\"www.reprobados.com\">\\
        <SSLHostConfig hostName=\"www.reprobados.com\">\\
            <Certificate certificateFile=\"$certAbs\" certificateKeyFile=\"$keyAbs\" />\\
        </SSLHostConfig>\\
    </Connector>" $conf
            else
                # Conector HTTP normal
                sed -i "/<\/Service>/i \\
    <Connector port=\"$P\" protocol=\"HTTP/1.1\" connectionTimeout=\"20000\" redirectPort=\"8443\" />" $conf
            fi

            Crear_Pagina "tomcat" $P
            systemctl start tomcat
            ;;
    esac

    sleep 3
    if ss -tuln | grep -q ":$P\b"; then
        echo -e "${GREEN}[OK] $servicio ONLINE en puerto $P${NC}"
    else
        echo -e "${RED}[!] $servicio no pudo levantar en el puerto $P. Revisa los logs.${NC}"
    fi
    read -p "Presione Enter para continuar..."
}

# ================================================================
# FTP E INSTALACION
# ================================================================
Instalar_Servicio() {
    local servicio=$1
    local paquete=$servicio

    if [ "$servicio" == "apache" ]; then paquete="httpd mod_ssl"; fi
    if [ "$servicio" == "tomcat" ]; then paquete="tomcat tomcat-webapps"; fi

    echo ""
    echo -e "${CYAN}[I] --- Instalando: $servicio ---${NC}"
    echo "1) DNF (Gestor Oficial) | 2) FTP ($FTP_IP)"
    read -p "Elija origen: " origen

    if [ "$origen" == "1" ]; then
        echo -e "${GRAY}[...] Instalando $paquete por DNF...${NC}"
        dnf install -y $paquete >/dev/null 2>&1
        echo -e "${GREEN}[OK] Instalacion completada.${NC}"
    else
        # Lógica FTP dinámica
        local ftpDir="ftp://$FTP_IP/http/Linux/${servicio^}/"
        echo -e "${CYAN}[*] Listando archivos en $ftpDir...${NC}"
        
        # Descarga lista de archivos (omitiendo los sha256)
        archivos=$(curl -s -l -u "$FTP_USER:$FTP_PASS" "$ftpDir" | grep -v ".sha256" | tr -d '\r')
        
        if [ -z "$archivos" ]; then
            echo -e "${RED}[!] No hay archivos o FTP no conectado.${NC}"
            read -p "Enter para continuar..."
            return
        fi

        IFS=$'\n' read -r -d '' -a arrArchivos <<< "$archivos"
        for i in "${!arrArchivos[@]}"; do
            echo "$((i+1))) ${arrArchivos[$i]}"
        done

        read -p "Seleccione el archivo: " idx
        idx=$((idx-1))
        archivo="${arrArchivos[$idx]}"

        echo -e "${YELLOW}[*] Descargando $archivo...${NC}"
        curl -s -u "$FTP_USER:$FTP_PASS" -o "/tmp/$archivo" "$ftpDir$archivo"
        
        # Validación Hash
        echo -e "${YELLOW}[*] Validando integridad (Hash SHA256)...${NC}"
        curl -s -u "$FTP_USER:$FTP_PASS" -o "/tmp/$archivo.sha256" "$ftpDir$archivo.sha256"
        
        if [ -f "/tmp/$archivo.sha256" ]; then
            hashLocal=$(sha256sum "/tmp/$archivo" | awk '{print $1}' | tr 'a-z' 'A-Z')
            hashServer=$(cat "/tmp/$archivo.sha256" | awk '{print $1}' | tr 'a-z' 'A-Z')
            
            if [ "$hashLocal" != "$hashServer" ]; then
                echo -e "${RED}[!] HASH INVALIDO. Archivo corrupto.${NC}"
                read -p "Enter para continuar..."
                return
            fi
            echo -e "${GREEN}[OK] Hash verificado correctamente.${NC}"
        fi

        # Instalar localmente según la extensión
        if [[ "$archivo" == *.rpm ]]; then
            dnf install -y "/tmp/$archivo" >/dev/null 2>&1
        elif [[ "$archivo" == *.tar.gz ]]; then
            tar -xzf "/tmp/$archivo" -C "/opt/"
            echo -e "${GREEN}[OK] Extraído en /opt/${NC}"
        fi
    fi

    read -p "¿Desplegar ahora? [S/N]: " dep
    if [[ "$dep" =~ ^[Ss]$ ]]; then
        Aplicar_Despliegue "$servicio"
    fi
}

# ================================================================
# FTP SEGURO E INICIALIZACION (VSFTPD)
# ================================================================
Configurar_FTP_Seguro() {
    echo -e "${CYAN}[*] Configurando vsftpd seguro (TLS)...${NC}"
    dnf install -y vsftpd >/dev/null 2>&1
    
    Generar_Certificado_SSL
    local crt="/etc/ssl/reprobados/reprobados.crt"
    local key="/etc/ssl/reprobados/reprobados.key"

    local conf="/etc/vsftpd/vsftpd.conf"
    
    # Limpiar lineas SSL previas si existen
    sed -i '/ssl_enable/d' $conf
    sed -i '/allow_anon_ssl/d' $conf
    sed -i '/force_local_data_ssl/d' $conf
    sed -i '/force_local_logins_ssl/d' $conf
    sed -i '/ssl_tlsv1/d' $conf
    sed -i '/rsa_cert_file/d' $conf
    sed -i '/rsa_private_key_file/d' $conf

    # Agregar configuracion TLS
    cat <<EOF >> $conf

# --- Configuracion SSL/TLS Inyectada ---
ssl_enable=YES
allow_anon_ssl=YES
force_local_data_ssl=YES
force_local_logins_ssl=YES
ssl_tlsv1=YES
rsa_cert_file=$crt
rsa_private_key_file=$key
require_ssl_reuse=NO
EOF

    Abrir_Firewall 21
    systemctl restart vsftpd
    systemctl enable vsftpd >/dev/null 2>&1

    sleep 2
    if ss -tuln | grep -q ":21\b"; then
        echo -e "${GREEN}[OK] FTP (vsftpd) ONLINE en puerto 21 con TLS activado.${NC}"
    else
        echo -e "${RED}[!] FTP no levanto. Revisa /etc/vsftpd/vsftpd.conf${NC}"
    fi
    read -p "Presione Enter para continuar..."
}

# ================================================================
# MENU PRINCIPAL
# ================================================================
Menu_Principal() {
    # Definir variables de FTP (apuntando a tu maquina de Windows si la tienes en la red)
    export FTP_IP="192.168.56.1" # Cambia esto por la IP de tu servidor FTP si es otra
    export FTP_USER="anonymous"
    export FTP_PASS=""

    while true; do
        clear
        echo -e "${CYAN}====================================================${NC}"
        echo -e "${CYAN}      MODULO HTTP/FTP - LINUX (FEDORA SERVER)       ${NC}"
        echo -e "${YELLOW}      PUERTO CONFIGURADO: $PUERTO_ACTUAL             ${NC}"
        echo -e "${CYAN}====================================================${NC}"
        echo " 1) Instalar + Desplegar Nginx"
        echo " 2) Instalar + Desplegar Apache"
        echo " 3) Instalar + Desplegar Tomcat"
        echo " 4) Configurar FTP Seguro (vsftpd TLS)"
        echo " 5) Configurar Puerto por Defecto"
        echo "----------------------------------------------------"
        echo " 6) Mostrar Resumen de Puertos (Netstat)"
        echo " 7) Salir"
        echo -e "${CYAN}====================================================${NC}"
        read -p " Opcion: " opcion

        case $opcion in
            1) Instalar_Servicio "nginx" ;;
            2) Instalar_Servicio "apache" ;;
            3) Instalar_Servicio "tomcat" ;;
            4) Configurar_FTP_Seguro ;;
            5) 
                read -p "Ingrese el puerto (recomendado: 8080, 8443, 9090): " nuevo
                if [[ "$nuevo" =~ ^[0-9]+$ ]]; then
                    PUERTO_ACTUAL=$nuevo
                    echo -e "${GREEN}[OK] Puerto $nuevo asignado.${NC}"
                fi
                sleep 1
                ;;
            6) 
                echo -e "\n${CYAN}--- Puertos a la escucha ---${NC}"
                ss -tuln | grep -E ':(80|443|21|8080|8081|8082|8443|9090)'
                read -p "Enter para continuar..."
                ;;
            7) exit 0 ;;
            *) echo -e "${RED}Opcion invalida${NC}"; sleep 1 ;;
        esac
    done
}

Menu_Principal
