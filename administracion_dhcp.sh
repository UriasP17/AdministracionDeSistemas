#!/bin/bash

validate_ip() {
    local ip=$1
    if [[ $ip == "0.0.0.0" || $ip == "255.255.255.255" ]]; then return 1; fi
    [[ $ip =~ ^[0-9]{1,3}(\\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for o in "${octets[@]}"; do
        [[ $o -le 255 ]] || return 1
    done
    return 0
}

while true; do
    echo -e "\\n--- GESTIÓN DHCP FEDORA ---"
    echo "1. Verificar/Instalar DHCP"
    echo "2. Configurar Ámbito"
    echo "3. Monitorear Leases"
    echo "4. Salir"
    read -p "Opción: " opt

    case $opt in
        1)
            rpm -q dhcp-server &> /dev/null || sudo dnf install -y dhcp-server
            echo "Servicio verificado." ;;
        2)
            read -p "IP Inicial: " START
            read -p "IP Final: " END
            if validate_ip $START && validate_ip $END; then
               
                sudo tee /etc/dhcp/dhcpd.conf <<EOF
subnet 192.168.100.0 netmask 255.255.255.0 {
    range $START $END;
    option routers 192.168.100.1;
    default-lease-time 600;
}
EOF
                sudo systemctl restart dhcpd
            else
                echo "Error: IP inválida."
            fi ;;
        3)
            echo "--- Concesiones Activas ---"
            grep "lease" /var/lib/dhcpd/dhcpd.leases | sort -u ;;
        4) break ;;
    esac
done
