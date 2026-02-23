#!/bin/bash

check_package_present() {
    rpm -q "$1" &>/dev/null
}

install_required_package() {
    sudo dnf install -y "$1" >/dev/null 2>&1
}

input() {
    read -p "$1" val
    echo "$val"
}

verificar_instalacion() {
    echo "Verificando instalación de DNS Server..."
    if check_package_present "bind"; then
        echo "[OK] DNS service está instalado"
    else
        echo "[Error] DNS service NO está instalado"
    fi

    verificar_setup
}

verificar_setup() {
    echo "Verificando configuración del servidor DNS..."

    if grep -q "allow-query { any; };" /etc/named.conf &&
       grep -q "listen-on port 53 { any; };" /etc/named.conf &&
       grep -q "listen-on-v6 port 53 { none; };" /etc/named.conf; then

        echo "[OK] Configuración de named.conf ya tiene allow-query y listen configurados"

    else
        echo "Actualizando bloque options en named.conf..."

        sudo sed -i '
/^[[:space:]]*options[[:space:]]*{/ {
    :a
    n
    /^[[:space:]]*};/ b
    /allow-query/d
    /listen-on port/d
    /listen-on-v6/d
    ba
}
' /etc/named.conf

        sudo sed -i '/^[[:space:]]*options[[:space:]]*{/a\
    allow-query { any; };\
    listen-on port 53 { any; };\
    listen-on-v6 port 53 { none; };' /etc/named.conf

        echo "[OK] Bloque options actualizado correctamente"
    fi

    # Validar configuración
    if sudo named-checkconf /etc/named.conf; then
        echo "[OK] Configuración de named.conf es válida"
    else
        echo "[Error] Configuración de named.conf es inválida"
        exit 1
    fi


    state_ip=$(ip -br addr show enp0s8 | awk '{print $2}')
    ip_value=$(ip -br addr show enp0s8 | awk '{print $3}')

    if [[ "$state_ip" == "UP" && -n "$ip_value" ]]; then
        echo "[OK] Interfaz enp0s8 está activa y tiene IP asignada"
    else
        echo "[Error] Interfaz enp0s8 no está activa o sin IP"

        ip_new=$(input "Ingresa una dirección IP válida para la interfaz enp0s8: ")
        prefix=$(input "Ingresa el prefijo de la máscara (ej. 24): ")

        network=$(ipcalc -n $ip_new/$prefix | awk -F= '{print $2}')
        mascara=$(ipcalc -m $ip_new/$prefix | awk -F= '{print $2}')

        sudo ip addr add $ip_new/$prefix dev enp0s8
        sudo route add -net $network netmask $mascara dev enp0s8

        exit 1
    fi


    if ! sudo firewall-cmd --list-services | grep -qw dns; then
        sudo firewall-cmd --add-service=dns --permanent >/dev/null 2>&1
        sudo firewall-cmd --reload >/dev/null 2>&1
        echo "[OK] Servicio DNS agregado al firewall"
    fi

    sudo systemctl restart named
    echo "[OK] Servicio named reiniciado"
}

instalar_dependencias() {
    echo "Instalando dependencias..."
    install_required_package "ipcalc"
    install_required_package "bind-utils"

    if ! check_package_present "bind"; then
        install_required_package "bind"
        if [[ $? -eq 0 ]]; then
            echo "[OK] bind instalado correctamente"
        else
            echo "[Error] Fallo al instalar bind"
            exit 1
        fi
    else
        echo "bind ya está instalado"
    fi

    verificar_setup
}

listar_dominios() {
    echo "Listando dominios configurados en el servidor DNS..."

    path="/var/named"
    zonas=$(ls $path/*.zone 2>/dev/null)

    if [ -n "$zonas" ]; then
        echo "Dominios configurados:"
        for file in $zonas; do
            echo "- $(basename "$file" .zone)"
        done
    else
        echo "No se encontraron dominios configurados."
    fi
}

agregar_dominio() {
    echo "Agregando nuevo dominio al servidor DNS..."   
    
    dominio=$(input "Ingresa el nombre del dominio a agregar: ")
    while [[ -z "$dominio" ]]; do
        echo "Error: El nombre del dominio no puede estar vacío"
        dominio=$(input "Ingresa el nombre del dominio a agregar: ")
    done  

    ip_dominio=$(input "Ingresa la IPv4 para el dominio (deja vacio para default server): ")


    if [[ -z "$ip_dominio" ]]; then
        ip_dominio=$(ip -br addr show enp0s8 | awk '{print $3}' | cut -d'/' -f1)
    fi

    # Rutas de Fedora
    zone_file="/var/named/$dominio.zone"
    name_file="named.rfc1912.zones"

    sudo touch $zone_file

    sudo bash -c "cat <<EOF > $zone_file
\$TTL 604800
@ IN SOA ns.$dominio. root.$dominio. (
    2;
    604800;
    86400;
    2419200;
    604800)
;
@ IN NS ns.$dominio.
ns IN A $ip_dominio
@ IN A $ip_dominio
www IN CNAME $dominio.
EOF"

    sudo chown root:named $zone_file
    sudo restorecon -Rv $zone_file >/dev/null 2>&1

    if ! grep -q "zone \"$dominio\"" /etc/$name_file; then
        sudo bash -c "cat <<EOF >> /etc/$name_file
zone \"$dominio\" IN {
    type master;
    file \"$zone_file\";
    allow-update { none; };
};
EOF"
    fi

    sudo systemctl restart named
    echo "Dominio agregado correctamente."
}

eliminar_dominio() {
    echo "Eliminando un dominio del servidor DNS" 

    zonas=$(ls /var/named/*.zone 2>/dev/null)
    if [ -n "$zonas" ]; then
        echo "Dominios configurados:"
        for file in $zonas; do
            echo "- $(basename "$file" .zone)"
        done

        dominio=$(input "Ingresa el nombre del dominio a eliminar: ")
        
        zone_file="/var/named/$dominio.zone"
        name_file="named.rfc1912.zones"

        if [ -f "$zone_file" ]; then
            sudo rm -f "$zone_file"

            sudo cp /etc/$name_file /etc/$name_file.bak
            sudo sed -i "/zone \"$dominio\" IN {/,/};/d" /etc/$name_file 

            sudo systemctl restart named
            echo "Dominio eliminado."
        else
            echo "El dominio no existe."
        fi
    else
        echo "No hay dominios para eliminar."
    fi      
}

mostrar_menu() {
    echo ""
    echo "========= MENÚ DNS ========="
    echo "1) Verificar instalación"
    echo "2) Instalar dependencias"
    echo "3) Listar Dominios configurados"
    echo "4) Agregar nuevo dominio"
    echo "5) Eliminar un dominio"
    echo "6) Salir"
    echo "============================="
}
