#!/bin/bash

get_interface() {
    ip -o link show | awk -F': ' '{print $2}' | grep -v 'lo' | head -n1
}

validate_ip() {
    [[ $1 =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
}

configure_network() {
    local interface=$(get_interface)
    sudo nmcli device modify "$interface" ipv4.addresses "$1/24" ipv4.method manual
    sudo nmcli device up "$interface"
}

uninstall_dhcp() {
    sudo systemctl stop dhcpd 2>/dev/null
    sudo rm -f /etc/dhcp/dhcpd.conf
    sudo dnf remove -y dhcp-server
}

while true; do
    echo -e "\n    GESTIÓN DHCP FEDORA "
    echo "1. Instalacion"
    echo "2. Verificación de Estado"
    echo "3. Configurar Ámbito (Server + Cliente)"
    echo "4. Monitorear Leases"
    echo "5. Desinstalar"
    echo "6. Salir"
    read -p "Opción: " opt

    case $opt in
        1) sudo dnf install -y dhcp-server ;;
        2) systemctl status dhcpd ;;
        3) 
            read -p "IP para este SERVIDOR: " START
            read -p "IP FINAL del rango: " END
            
            if validate_ip $START && validate_ip $END; then
                configure_network $START
                
                NET_BASE=$(echo $START | cut -d'.' -f1-3)
                CLIENT_START=$(echo $START | awk -F. '{print $1"."$2"."$3"."($4+1)}')
                
                sudo bash -c "cat <<EOF > /etc/dhcp/dhcpd.conf
subnet ${NET_BASE}.0 netmask 255.255.255.0 {
    range $CLIENT_START $END;
    option routers $START;
    option domain-name-servers 8.8.8.8;
    default-lease-time 600;
    max-lease-time 7200;
}
EOF"
                sudo restorecon -v /etc/dhcp/dhcpd.conf
                sudo systemctl restart dhcpd
                echo "[+] Server: $START | Clientes: $CLIENT_START - $END"
            else
                echo "[X] IPs inválidas."
            fi ;;
        4) cat /var/lib/dhcpd/dhcpd.leases 2>/dev/null || echo "Sin leases." ;;
        5) uninstall_dhcp ;;
        6) exit ;;
    esac
done
