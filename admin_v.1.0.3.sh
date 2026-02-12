3)
    echo "
=== DHCP SIMPLE (Server fijo + Rango auto) ==="
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
    
    configure_network "$SERVER_IP/24"
    
    sudo bash -c "cat <<EOF > /etc/dhcp/dhcpd.conf
subnet $NET_BASE.0 netmask 255.255.255.0 {
    range $CLIENT_START $FINAL_IP;
    option routers $SERVER_IP;
    option domain-name-servers 8.8.8.8, 1.1.1.1;
    option domain-name "local";
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
