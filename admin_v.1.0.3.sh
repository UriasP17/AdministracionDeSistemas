#!/bin/bash
INTERFACE="enp0s8"

if ! nmcli dev status | grep -q "^$INTERFACE"; then
    echo -e "\e[33m[WARN] No veo la $INTERFACE.\e[0m"
    ACTIVE_IF=$(nmcli -t -f DEVICE,STATE dev | grep ":connected" | head -n1 | cut -d: -f1)
    if [ -n "$ACTIVE_IF" ]; then
        INTERFACE="$ACTIVE_IF"
        echo -e "\e[36m--> Agarrando esta activa: $INTERFACE\e[0m"
        sleep 2
    else
        echo -e "\e[31m[FATAL] No hay red.\e[0m"
        exit 1
    fi
fi

validate_ip() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && [[ $1 != "0.0.0.0" ]] && [[ $1 != "255.255.255.255" ]]
}

ip_to_int() {
    local IFS=.
    read -r i1 i2 i3 i4 <<< "$1"
    echo $(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))
}

configure_network() {
    IP=$1
    CIDR=$2
    echo -e "\e[33mPoniendo IP $IP/$CIDR en $INTERFACE...\e[0m"
    nmcli con modify "$INTERFACE" ipv4.method manual ipv4.addresses "$IP/$CIDR" ipv4.gateway "" ipv4.dns "" 2>/dev/null
    nmcli dev set "$INTERFACE" managed yes
    nmcli con up "$INTERFACE" >/dev/null 2>&1
    
    echo -e "\e[32mAbriendo firewall (UDP 67)...\e[0m"
    sudo firewall-cmd --permanent --add-service=dhcp >/dev/null 2>&1
    sudo firewall-cmd --reload >/dev/null 2>&1
}

install_dhcp() {
    echo -n "Instalando DHCP... "
    if ! rpm -q dhcp-server &>/dev/null; then
        sudo dnf install -y dhcp-server >/dev/null 2>&1
        echo -e "\e[32m[LISTO]\e[0m"
    else
        echo -e "\e[33m[YA ESTABA]\e[0m"
    fi
    sudo systemctl enable dhcpd >/dev/null 2>&1
}

setup_leases() {
    sudo mkdir -p /var/lib/dhcpd
    [ ! -f /var/lib/dhcpd/dhcpd.leases ] && sudo touch /var/lib/dhcpd/dhcpd.leases
    sudo chown dhcpd:dhcpd /var/lib/dhcpd/dhcpd.leases
    sudo restorecon -Rv /etc/dhcp /var/lib/dhcpd >/dev/null 2>&1
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
    echo -e "\e[36m------------------------------------------\e[0m"
    echo -e "\e[36m    DHCP MANAGER - FEDORA ($INTERFACE)\e[0m"
    echo -e "\e[36m------------------------------------------\e[0m"
    echo "1. Instalar Server"
    echo "2. Ver Estado"
    echo "3. Configurar (Auto)"
    echo "4. Ver Clientes"
    echo "5. Limpiar Clientes"
    echo "6. Desinstalar"
    echo "7. Salir"
    echo -e "\e[36m------------------------------------------\e[0m"
    read -p "Opcion: " opt

    case $opt in
        1)
            install_dhcp
            setup_leases
            sudo bash -c "echo 'DHCPDARGS=$INTERFACE' > /etc/sysconfig/dhcpd"
            read -p "Dale Enter..."
        ;;

        2)
            systemctl status dhcpd --no-pager
            read -p "Dale Enter..."
        ;;

        3)
            echo -e "\n\e[33m--- CONFIGURACION ---\e[0m"
            
            while true; do
                read -p "IP del Server (ej: 10.0.0.1): " SERVER_IP
                if validate_ip "$SERVER_IP"; then break; fi
                echo -e "\e[31mEsa IP no sirve.\e[0m"
            done

            read CLASE MASK CIDR SUBNET <<< $(detect_class_info "$SERVER_IP")
            if [ "$CLASE" == "UNKNOWN" ]; then
                echo -e "\e[31mIP reservada o rara.\e[0m"
                read -p "Enter..."
                continue
            fi

            SERVER_LAST_OCTET=$(echo $SERVER_IP | awk -F. '{print $4}')
            CLIENT_START_OCTET=$((SERVER_LAST_OCTET + 1))
            BASE_IP_PART=$(echo $SERVER_IP | rev | cut -d'.' -f2- | rev)
            CLIENT_START="$BASE_IP_PART.$CLIENT_START_OCTET"

            echo -e "\e[90mEs Clase $CLASE. Empieza en $CLIENT_START\e[0m"

            while true; do
                read -p "IP Final: " FINAL_IP
                if validate_ip "$FINAL_IP"; then
                    N_START=$(ip_to_int "$CLIENT_START")
                    N_END=$(ip_to_int "$FINAL_IP")
                    N_SERVER=$(ip_to_int "$SERVER_IP")
                    
                    if [ "$N_END" -le "$N_START" ]; then
                        echo -e "\e[31mLa final debe ser mayor a la inicial.\e[0m"
                    elif [ "$N_END" -eq "$N_SERVER" ]; then
                        echo -e "\e[31mNo pongas la misma del server.\e[0m"
                    else
                        break
                    fi
                else
                    echo -e "\e[31mIP invalida.\e[0m"
                fi
            done

            configure_network "$SERVER_IP" "$CIDR"
            
            sudo bash -c "cat <<EOF > /etc/dhcp/dhcpd.conf
subnet $SUBNET netmask $MASK {
    range $CLIENT_START $FINAL_IP;
    option routers $SERVER_IP;
    option domain-name-servers $SERVER_IP, 8.8.8.8;
    option domain-name \"local\";
    default-lease-time 600;
    max-lease-time 7200;
}
EOF"

            sudo bash -c "echo 'DHCPDARGS=$INTERFACE' > /etc/sysconfig/dhcpd"
            sudo systemctl restart dhcpd
            
            if systemctl is-active --quiet dhcpd; then
                echo -e "\n\e[32mTodo listo en $INTERFACE.\e[0m"
            else
                echo -e "\n\e[31mTrono algo. Checa journalctl.\e[0m"
            fi
            read -p "Dale Enter..."
        ;;

        4)
            echo -e "\n\e[36m------ CLIENTES ------\e[0m"
            [ -f /var/lib/dhcpd/dhcpd.leases ] && cat /var/lib/dhcpd/dhcpd.leases | grep -E "lease|hostname" || echo "Nada aun."
            read -p "Dale Enter..."
        ;;

        5)
            echo -e "\e[33mBorrando leases...\e[0m"
            sudo systemctl stop dhcpd
            sudo rm -f /var/lib/dhcpd/dhcpd.leases
            setup_leases
            sudo systemctl start dhcpd
            echo -e "\e[32mLimpio.\e[0m"
            read -p "Dale Enter..."
        ;;

        6)
            echo -e "\e[33mQuitando todo...\e[0m"
            sudo systemctl stop dhcpd 2>/dev/null
            sudo dnf remove -y dhcp-server >/dev/null 2>&1
            sudo rm -rf /var/lib/dhcpd /etc/dhcp/dhcpd.conf
            sudo firewall-cmd --permanent --remove-service=dhcp >/dev/null 2>&1
            sudo firewall-cmd --reload >/dev/null 2>&1
            echo -e "\e[32mBye.\e[0m"
            read -p "Dale Enter..."
        ;;

        7) exit ;;
    esac
done
