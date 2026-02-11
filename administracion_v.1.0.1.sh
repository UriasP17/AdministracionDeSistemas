#!/bin/bash

validate_ip() {
    local ip=$1
    if [[ $ip == "0.0.0.0" || $ip == "255.255.255.255" ]]; then return 1; fi
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for o in "${octets[@]}"; do
        [[ $o -le 255 ]] || return 1
    done
    return 0
}

while true; do
    echo -e "         MENÚ"
    echo "1. InstalaciOn"
    echo "2. Verificacion de Estado (Diagnostico)"
    echo "3. Configurar Ambito y Parametros"
    echo "4. Monitorear Leases Activos"
    echo "5. Salir"
    read -p "Seleccione una opción: " opt

    case $opt in
        1)
            if rpm -q dhcp-server &> /dev/null; then
                echo "[!] El servicio ya está instalado."
            else
                echo "[+] Instalando dhcp-server"
                sudo dnf install -y dhcp-server
            fi ;;
        2)
            echo "    Diagnóstico del Servicio "
            if systemctl is-active --quiet dhcpd; then
                echo "ESTADO: Ejecutándose (Running)"
            else
                echo "ESTADO: Detenido o No Instalado"
                systemctl status dhcpd --no-pager | grep "Active:"
            fi ;;
        3)
            read -p "IP Inicial: " START
            read -p "IP Final: " END
            if validate_ip $START && validate_ip $END; then
                sudo tee /etc/dhcp/dhcpd.conf <<EOF
subnet 192.168.100.0 netmask 255.255.255.0 {
    range $START $END;
    option routers 192.168.100.1;
    option domain-name-servers 192.168.100.10;
    default-lease-time 600;
}
EOF
                sudo systemctl restart dhcpd
                echo "[+] Configuración aplicada y servicio reiniciado."
            else
                echo "[X] Error: IP inválida."
            fi ;;
        4)
            echo "   Concesiones (Leases)"
            [ -f /var/lib/dhcpd/dhcpd.leases ] && grep "lease" /var/lib/dhcpd/dhcpd.leases | sort -u || echo "Sin leases activos." ;;
        5) exit 0 ;;
    esac
done
