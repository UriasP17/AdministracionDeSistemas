#!/bin/bash

INTERFACE=$(nmcli -t -f NAME,TYPE connection show | grep ethernet | sed -n '2p' | cut -d: -f1)

if [ -z "$INTERFACE" ]; then
    echo "[ERROR] No se pudo detectar la segunda interfaz ethernet"
    nmcli device status
    exit 1
fi
validate_ip() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

configure_network() {
    nmcli con modify "$INTERFACE" ipv4.method manual ipv4.addresses "$1/24" 2>/dev/null
    nmcli dev set "$INTERFACE" managed yes
    nmcli con up "$INTERFACE" 2>/dev/null
}

install_dhcp() {
    sudo dnf install -y dhcp-server
    sudo systemctl enable dhcpd
}

setup_dhcp_interface() {
    sudo bash -c "cat <<EOF > /etc/sysconfig/dhcpd
DHCPDARGS=$INTERFACE
EOF"
}

setup_leases() {
    sudo mkdir -p /var/lib/dhcpd
    sudo touch /var/lib/dhcpd/dhcpd.leases
    sudo chown dhcpd:dhcpd /var/lib/dhcpd/dhcpd.leases
    sudo restorecon -Rv /etc/dhcp /var/lib/dhcpd >/dev/null
}

uninstall_dhcp() {
    sudo systemctl stop dhcpd 2>/dev/null
    sudo dnf remove -y dhcp-server
    sudo rm -f /etc/dhcp/dhcpd.conf
    sudo rm -f /etc/sysconfig/dhcpd
    sudo rm -rf /var/lib/dhcpd
}

while true; do
    clear
    echo -e "\n    GESTIÓN DHCP FEDORA (Interfaz: $INTERFACE) "
    echo "1. Instalación DHCP"
    echo "2. Verificación de Estado"
    echo "3. Configurar Ámbito DHCP"
    echo "4. Ver Leases"
    echo "5. Desinstalar DHCP"
    echo "6. Salir"
    read -p "Opción: " opt

    case $opt in
        1)
            install_dhcp
            setup_dhcp_interface
            setup_leases
            echo "[OK] DHCP instalado correctamente"
            read -p "Enter para continuar..."
        ;;

        2)
            systemctl status dhcpd
            read -p "Enter para continuar..."
        ;;

        3)
            read -p "IP del servidor DHCP (ej: 192.168.10.1): " SERVER_IP
            read -p "Inicio rango clientes (ej: 192.168.10.50): " RANGE_START
            read -p "Fin rango clientes (ej: 192.168.10.100): " RANGE_END
            read -p "Gateway real de la red (ej: 192.168.10.1): " GATEWAY

            if validate_ip "$SERVER_IP" && validate_ip "$RANGE_START" && validate_ip "$RANGE_END" && validate_ip "$GATEWAY"; then

                NET_BASE=$(echo $SERVER_IP | cut -d'.' -f1-3)

                configure_network "$SERVER_IP"

                sudo bash -c "cat <<EOF > /etc/dhcp/dhcpd.conf
subnet ${NET_BASE}.0 netmask 255.255.255.0 {
    range $RANGE_START $RANGE_END;
    option routers $GATEWAY;
    option domain-name-servers 8.8.8.8, 1.1.1.1;
    default-lease-time 600;
    max-lease-time 7200;
}
EOF"

                setup_dhcp_interface
                setup_leases

                sudo systemctl daemon-reload
                sudo systemctl restart dhcpd

                echo "[OK] DHCP configurado y activo en $INTERFACE"
            else
                echo "[X] IPs inválidas."
            fi

            read -p "Enter para continuar..."
        ;;

        4)
            echo "------ LEASES DHCP ------"
            cat /var/lib/dhcpd/dhcpd.leases 2>/dev/null || echo "Sin leases."
            echo "-------------------------"
            read -p "Enter para continuar..."
        ;;

        5)
            uninstall_dhcp
            echo "[OK] DHCP desinstalado"
            read -p "Enter para continuar..."
        ;;

        6)
            exit
        ;;
    esac
done
