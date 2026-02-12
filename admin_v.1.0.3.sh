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
    IP=$1
    CIDR=$2
    echo "Configurando IP $IP$CIDR en $INTERFACE..."
    nmcli con modify "$INTERFACE" ipv4.method manual ipv4.addresses "$IP$CIDR" 2>/dev/null
    nmcli dev set "$INTERFACE" managed yes
    nmcli con up "$INTERFACE" >/dev/null 2>&1
}

install_dhcp() {
    echo -n "Instalando DHCP Server... "
    sudo dnf install -y dhcp-server >/dev/null 2>&1
    sudo systemctl enable dhcpd >/dev/null 2>&1
    echo "[OK]"
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
    sudo restorecon -Rv /etc/dhcp /var/lib/dhcpd >/dev/null 2>&1
}

uninstall_dhcp() {
    echo -n "Desinstalando... "
    sudo systemctl stop dhcpd 2>/dev/null
    sudo dnf remove -y dhcp-server >/dev/null 2>&1
    sudo rm -f /etc/dhcp/dhcpd.conf
    sudo rm -f /etc/sysconfig/dhcpd
    sudo rm -rf /var/lib/dhcpd
    echo "[OK]"
}

detect_class_info() {
    IP=$1
    O1=$(cut -d. -f1 <<< "$IP")
    O2=$(cut -d. -f2 <<< "$IP")
    O3=$(cut -d. -f3 <<< "$IP")

    if [ "$O1" -ge 1 ] && [ "$O1" -le 126 ]; then
        echo "A 255.0.0.0 8 $O1.0.0.0"
    elif [ "$O1" -ge 128 ] && [ "$O1" -le 191 ]; then
        echo "B 255.255.0.0 16 $O1.$O2.0.0"
    elif [ "$O1" -ge 192 ] && [ "$O1" -le 223 ]; then
        echo "C 255.255.255.0 24 $O1.$O2.$O3.0"
    else
        echo "UNKNOWN 0 0 0"
    fi
}


while true; do
    clear
    echo -e "\n    GESTION DHCP FEDORA (Interfaz: $INTERFACE) "
    echo "1. Instalacion Silenciosa DHCP"
    echo "2. Verificacion de Estado"
    echo "3. Configurar Ambito (Auto Clase A, B, C)"
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
            echo "[OK] DHCP listo"
            read -p "Enter para continuar..."
        ;;

        2)
            systemctl status dhcpd
            read -p "Enter para continuar..."
        ;;

        3)
            echo -e "\n=== DHCP MULTI-CLASE AUTOMATICO ==="
            read -p "IP del SERVER (fija): " SERVER_IP
            read -p "IP FINAL del rango: " FINAL_IP
            
            if ! validate_ip "$SERVER_IP" || ! validate_ip "$FINAL_IP"; then
                echo "[X] IP(s) invalida(s)"
                read -p "Enter para continuar..."
                continue
            fi

            read CLASE MASK CIDR SUBNET <<< $(detect_class_info "$SERVER_IP")

            if [ "$CLASE" == "UNKNOWN" ]; then
                echo "[X] IP no valida o es Clase D/E (Multicast/Reservada)"
                read -p "Enter..."
                continue
            fi

            SERVER_LAST_OCTET=$(echo $SERVER_IP | awk -F. '{print $4}')
            CLIENT_START_OCTET=$((SERVER_LAST_OCTET + 1))
            
            BASE_IP_PART=$(echo $SERVER_IP | rev | cut -d'.' -f2- | rev)
            CLIENT_START="$BASE_IP_PART.$CLIENT_START_OCTET"

            echo ""
            echo "CLASE DETECTADA: $CLASE"
            echo "   Mascara: $MASK ($CIDR)"
            echo "   Subred:  $SUBNET"
            echo "--------------------------------"
            echo "Server:  $SERVER_IP"
            echo "Clientes: $CLIENT_START -> $FINAL_IP"
            echo ""
            
            read -p "Default lease (600 seg): " DEFAULT_LEASE
            read -p "Max lease (7200 seg): " MAX_LEASE
            [ -z "$DEFAULT_LEASE" ] && DEFAULT_LEASE="600"
            [ -z "$MAX_LEASE" ] && MAX_LEASE="7200"
            
            configure_network "$SERVER_IP" "$CIDR"
            
            sudo bash -c "cat <<EOF > /etc/dhcp/dhcpd.conf
subnet $SUBNET netmask $MASK {
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

            echo "Verificando configuracion..."
            if sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf >/dev/null 2>&1; then
                sudo systemctl restart dhcpd
                echo ""
                echo "DHCP CONFIGURADO CON EXITO ($CLASE)"
                echo "Checa puerto: sudo ss -tulpn | grep :67"
            else
                echo "Error en la configuracion generada."
                sudo dhcpd -t -cf /etc/dhcp/dhcpd.conf
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
            sudo systemctl stop dhcpd >/dev/null 2>&1
            sudo rm -f /var/lib/dhcpd/dhcpd.leases
            sudo touch /var/lib/dhcpd/dhcpd.leases
            sudo chown dhcpd:dhcpd /var/lib/dhcpd/dhcpd.leases
            sudo restorecon -Rv /var/lib/dhcpd >/dev/null 2>&1
            sudo systemctl start dhcpd
            echo "[OK] Clientes reseteados."
            read -p "Enter para continuar..."
        ;;

        6)
            uninstall_dhcp
            read -p "Enter para continuar..."
        ;;

        7)
            exit
        ;;
    esac
done
