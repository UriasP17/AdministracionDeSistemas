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
    echo "Configurando IP $1 en $INTERFACE..."
    nmcli con modify "$INTERFACE" ipv4.method manual ipv4.addresses "$1/24" 2>/dev/null
    nmcli dev set "$INTERFACE" managed yes
    nmcli con up "$INTERFACE" 2>/dev/null
}

install_dhcp() {
    echo "Instalando DHCP Server..."
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
    echo "Desinstalando..."
    sudo systemctl stop dhcpd 2>/dev/null
    sudo dnf remove -y dhcp-server
    sudo rm -f /etc/dhcp/dhcpd.conf
    sudo rm -f /etc/sysconfig/dhcpd
    sudo rm -rf /var/lib/dhcpd
}

while true; do
    clear
    echo -e "\n    GESTION DHCP FEDORA (Interfaz: $INTERFACE) "
    echo "1. Instalacion DHCP"
    echo "2. Verificacion de Estado"
    echo "3. Configurar Ambito DHCP (Simple)"
    echo "4. Ver Leases (Clientes)"
    echo "5. ELIMINAR LEASES (Resetear Clientes)"
    echo "6. Desinstalar DHCP"
    echo "7. Salir"
    read -p "Opcion: " opt

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
            echo -e "\n=== DHCP SIMPLE (Server fijo + Rango auto) ==="
            read -p "IP del SERVER (fija): " SERVER_IP
            read -p "IP FINAL del rango: " FINAL_IP
            
            if ! validate_ip "$SERVER_IP" || ! validate_ip "$FINAL_IP"; then
                echo "[X] IP(s) invalida(s)"
                read -p "Enter para continuar..."
                continue
            fi
            
            SERVER_NUM=$(echo $SERVER_IP | awk -F. '{print $4}')
            FINAL_NUM=$(echo $FINAL_IP | awk -F. '{print $4}')
            
            if [ $FINAL_NUM -le $SERVER_NUM ]; then
                echo "[X] El IP final debe ser MAYOR que el del server"
                echo "Server: $SERVER_IP ($SERVER_NUM)"
                echo "Final: $FINAL_IP ($FINAL_NUM)"
                read -p "Enter para continuar..."
                continue
            fi
            
            NET_BASE=$(echo $SERVER_IP | cut -d'.' -f1-3)
            CLIENT_START=$(echo $NET_BASE.$((SERVER_NUM + 1)))
            
            echo ""
            echo "CONFIGURACION:"
            echo "Server: $SERVER_IP"
            echo "Cliente: $CLIENT_START -> $FINAL_IP"
            echo ""
            
            read -p "Default lease (600 seg): " DEFAULT_LEASE
            read -p "Max lease (7200 seg): " MAX_LEASE
            [ -z "$DEFAULT_LEASE" ] && DEFAULT_LEASE="600"
            [ -z "$MAX_LEASE" ] && MAX_LEASE="7200"
            
            configure_network "$SERVER_IP"
            
            sudo bash -c "cat <<EOF > /etc/dhcp/dhcpd.conf
subnet $NET_BASE.0 netmask 255.255.255.0 {
    range $CLIENT_START $FINAL_IP;
    option routers $SERVER_IP;
    option domain-name-servers 8.8.8.8, 1.1.1.1;
    option domain-name \"local\";
    default-lease-time $DEFAULT_LEASE;
    max-lease-time $MAX_LEASE;
}
EOF"

            setup_dhcp_interface
            setup_leases
            sudo systemctl daemon-reload

            if sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf; then
                sudo systemctl restart dhcpd
                echo ""
                echo "DHCP CONFIGURADO!"
                echo "Server tiene: $SERVER_IP"
                echo "Cliente agarrara: $CLIENT_START -> $FINAL_IP"
                echo "Checa: sudo ss -tulpn | grep :67"
            else
                echo "Error config. Revisa: journalctl -u dhcpd"
            fi
            read -p "Enter para continuar..."
        ;;

        4)
            echo "------ LEASES DHCP ------"
            if [ -f /var/lib/dhcpd/dhcpd.leases ]; then
                cat /var/lib/dhcpd/dhcpd.leases
            else
                echo "Sin archivo de leases."
            fi
            echo "-------------------------"
            read -p "Enter para continuar..."
        ;;

        5)
            echo "Eliminando leases..."
            sudo systemctl stop dhcpd
            sudo rm -f /var/lib/dhcpd/dhcpd.leases
            sudo touch /var/lib/dhcpd/dhcpd.leases
            sudo chown dhcpd:dhcpd /var/lib/dhcpd/dhcpd.leases
            sudo restorecon -Rv /var/lib/dhcpd >/dev/null
            sudo systemctl start dhcpd
            echo "[OK] Leases eliminados. Clientes deben renovar."
            read -p "Enter para continuar..."
        ;;

        6)
            uninstall_dhcp
            echo "[OK] DHCP desinstalado"
            read -p "Enter para continuar..."
        ;;

        7)
            exit
        ;;
    esac
done
