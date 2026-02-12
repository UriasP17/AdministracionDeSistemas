#!/bin/bash
INTERFACE="enp0s8"

if ! nmcli dev status | grep -q "^$INTERFACE"; then
    echo "[FATAL] La interfaz $INTERFACE no existe"
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
            echo "\nCONFIGURACIÓN SIMPLE DHCP"
            read -p "IP inicial (SERVER) ej: 192.168.10.10: " START_IP
            read -p "IP final (CLIENTE) ej: 192.168.10.50: " END_IP

            read -p "Gateway (opcional, Enter para omitir): " GATEWAY
            read -p "DNS (opcional, ej: 8.8.8.8,1.1.1.1 | Enter para default): " DNS

            if ! validate_ip "$START_IP" || ! validate_ip "$END_IP"; then
                echo "[X] IPs inválidas"
                read -p "Enter para continuar..."
                continue
            fi

            SERVER_IP="$START_IP"
            NET_BASE=$(echo $SERVER_IP | cut -d'.' -f1-3)
            CLIENT_START=$(echo $SERVER_IP | awk -F. '{print $1"."$2"."$3"."($4+1)}')

            configure_network "$SERVER_IP"

            # Valores opcionales
            [ -z "$GATEWAY" ] && GATEWAY="$SERVER_IP"
            [ -z "$DNS" ] && DNS="8.8.8.8, 1.1.1.1"

            sudo bash -c "cat <<EOF > /etc/dhcp/dhcpd.conf
subnet ${NET_BASE}.0 netmask 255.255.255.0 {
    range $CLIENT_START $END_IP;
    option routers $GATEWAY;
    option domain-name-servers $DNS;
    default-lease-time 600;
    max-lease-time 7200;
}
EOF"

            setup_dhcp_interface
            setup_leases

            sudo systemctl daemon-reload

            # Validación antes de arrancar
            if sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf; then
                sudo systemctl restart dhcpd
                echo "[OK] DHCP activo"
                echo "SERVER IP : $SERVER_IP"
                echo "CLIENTES  : $CLIENT_START -> $END_IP"
                echo "GATEWAY   : $GATEWAY"
                echo "DNS       : $DNS"
            else
                echo "[ERROR] Configuración DHCP inválida"
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
