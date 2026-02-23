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

install_dns() {
    echo -n "Instalando BIND9 (DNS)... "
    if ! rpm -q bind &>/dev/null; then
        sudo dnf install -y bind bind-utils >/dev/null 2>&1
        echo -e "\e[32m[LISTO]\e[0m"
    else
        echo -e "\e[33m[YA ESTABA]\e[0m"
    fi
    sudo systemctl enable named >/dev/null 2>&1
    
    echo -e "\e[32mAbriendo firewall (TCP/UDP 53)...\e[0m"
    sudo firewall-cmd --permanent --add-service=dns >/dev/null 2>&1
    sudo firewall-cmd --reload >/dev/null 2>&1
}

setup_dns() {
   
    if ! grep -q "allow-query.*any;" /etc/named.conf; then
        sudo cp /etc/named.conf /etc/named.conf.bak
        sudo sed -i -e 's/listen-on port 53 { 127.0.0.1; };/listen-on port 53 { any; };/g' /etc/named.conf
        sudo sed -i -e 's/listen-on-v6 port 53 { ::1; };/listen-on-v6 port 53 { none; };/g' /etc/named.conf
        sudo sed -i -e 's/allow-query     { localhost; };/allow-query     { any; };/g' /etc/named.conf
    fi
}

while true; do
    clear
    echo -e "\e[36m------------------------------------------\e[0m"
    echo -e "\e[36m      DNS MANAGER - FEDORA ($INTERFACE)\e[0m"
    echo -e "\e[36m------------------------------------------\e[0m"
    echo "1. Instalar Server"
    echo "2. Ver Estado"
    echo "3. Configurar Dominio"
    echo "4. Ver Dominios"
    echo "5. Borrar Dominio"
    echo "6. Desinstalar"
    echo "7. Salir"
    echo -e "\e[36m------------------------------------------\e[0m"
    read -p "Opcion: " opt

    case $opt in
        1)
            install_dns
            setup_dns
            sudo systemctl start named
            read -p "Dale Enter..."
        ;;

        2)
            systemctl status named --no-pager
            read -p "Dale Enter..."
        ;;

        3)
            echo -e "\n\e[33m--- CONFIGURACION ---\e[0m"
            
            read -p "Nombre del dominio: " DOMINIO
            if [ -z "$DOMINIO" ]; then
                echo -e "\e[31mEl dominio no puede estar vacio.\e[0m"
                read -p "Dale Enter..."
                continue
            fi
            
            while true; do
                read -p "IP de ESTE servidor DNS (ej: 192.168.1.10): " SERVER_IP
                if validate_ip "$SERVER_IP"; then break; fi
                echo -e "\e[31mEsa IP no sirve.\e[0m"
            done

            while true; do
                read -p "IP del Cliente (Hacia donde apuntara $DOMINIO): " CLIENT_IP
                if validate_ip "$CLIENT_IP"; then break; fi
                echo -e "\e[31mEsa IP no sirve.\e[0m"
            done

            ZONE_FILE="/var/named/$DOMINIO.zone"

        
            sudo bash -c "cat <<'EOF' > $ZONE_FILE
\$TTL 86400
@   IN  SOA     ns1.$DOMINIO. admin.$DOMINIO. (
                    2026022101 ; Serial
                    3600       ; Refresh
                    1800       ; Retry
                    604800     ; Expire
                    86400      ; Minimum TTL
)
@       IN  NS      ns1.$DOMINIO.
ns1     IN  A       $SERVER_IP
@       IN  A       $CLIENT_IP
www     IN  CNAME   $DOMINIO.
EOF"
            sudo chown root:named $ZONE_FILE
            sudo restorecon -Rv $ZONE_FILE >/dev/null 2>&1
            sudo touch /etc/named.rfc1912.zones
            sudo chown root:named /etc/named.rfc1912.zones
            
            if ! grep -q "zone \"$DOMINIO\"" /etc/named.rfc1912.zones; then
                sudo bash -c "cat <<EOF >> /etc/named.rfc1912.zones

zone \"$DOMINIO\" IN {
    type master;
    file \"$ZONE_FILE\";
    allow-update { none; };
};
EOF"
            fi

            sudo systemctl restart named
            
            if systemctl is-active --quiet named; then
                echo -e "\n\e[32mTodo listo! $DOMINIO apunta a $CLIENT_IP.\e[0m"
            else
                echo -e "\n\e[31mTrono algo. Checa journalctl -xeu named.\e[0m"
            fi
            read -p "Dale Enter..."
        ;;

        4)
            echo -e "\n\e[36m------ DOMINIOS ------\e[0m"
            DOMINIOS=$(ls /var/named/*.zone 2>/dev/null)
            if [ -n "$DOMINIOS" ]; then
                for f in $DOMINIOS; do
                    basename "$f" .zone
                done
            else
                echo "Nada aun."
            fi
            read -p "Dale Enter..."
        ;;

        5)
            echo -e "\n\e[33m--- BORRAR DOMINIO ---\e[0m"
            read -p "Cual dominio quieres borrar?: " DOMINIO
            
            if [ -f "/var/named/$DOMINIO.zone" ]; then
                sudo rm -f "/var/named/$DOMINIO.zone"
                sudo sed -i "/zone \"$DOMINIO\" IN {/,/};/d" /etc/named.rfc1912.zones
                sudo systemctl restart named
                echo -e "\e[32mLimpio. Se borro $DOMINIO.\e[0m"
            else
                echo -e "\e[31mEse dominio no existe.\e[0m"
            fi
            read -p "Dale Enter..."
        ;;

        6)
            echo -e "\e[33mQuitando todo...\e[0m"
            sudo systemctl stop named 2>/dev/null
            sudo dnf remove -y bind bind-utils >/dev/null 2>&1
            sudo rm -f /var/named/*.zone
        
            [ -f /etc/named.rfc1912.zones ] && sudo sed -i '/zone ".*" IN {/,/};/d' /etc/named.rfc1912.zones
            [ -f /etc/named.conf.bak ] && sudo mv /etc/named.conf.bak /etc/named.conf
            sudo firewall-cmd --permanent --remove-service=dns >/dev/null 2>&1
            sudo firewall-cmd --reload >/dev/null 2>&1
            echo -e "\e[32mBye.\e[0m"
            read -p "Dale Enter..."
        ;;


        7) exit ;;
    esac
done
