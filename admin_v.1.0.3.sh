#!/bin/bash

validate_ip() {
    local ip=$1
    if [[ $ip == "0.0.0.0" || $ip == "127.0.0.1" || $ip == "255.255.255.255" ]]; then return 1; fi
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS='.' read -r -a octets <<< "$ip"
    for o in "${octets[@]}"; do [[ $o -le 255 ]] || return 1; done
    return 0
}

validate_integer() { [[ $1 =~ ^[0-9]+$ ]]; }

calculate_mask() {
    local base=$(echo $1 | cut -d'.' -f1-2)
    
    if [[ $base == "10.0" ]]; then
        echo "255.0.0.0"
    elif [[ $base == "172.16" ]]; then
        echo "255.255.0.0"
    elif [[ $base == "192.168" ]]; then
        echo "255.255.255.0"
    else
        echo "255.255.255.0"
    fi
}


compare_ips() { [[ $(printf '%s\n' "$1" "$2" | sort -V | tail -n1) == "$2" ]]; }

uninstall_dhcp() {
    echo "[!] Desinstalando DHCP completamente"
    sudo systemctl stop dhcpd 2>/dev/null
    sudo rm -f /etc/dhcp/dhcpd.conf
    sudo rm -f /var/lib/dhcpd/dhcpd.leases
    sudo dnf remove -y dhcp-server
    echo "[+] DHCP eliminado completamente."
}

while true; do
    echo -e "\n    GESTIÓN DHCP FEDORA COMPLETA "
    echo "1. Instalacion"
    echo "2. Verificación de Estado"
    echo "3. Configurar Ambito Dinamico"
    echo "4. Monitorear Leases"
    echo "5. Desinstalar (Eliminar TODO)"
    echo "6. Salir"
    read -p "Opción: " opt

    case $opt in
        1)
            if rpm -q dhcp-server &> /dev/null; then
                read -p "Reinstalar? (s/N): " confirm
                [[ $confirm =~ ^[Ss]$ ]] && sudo dnf reinstall -y dhcp-server && echo "[+] Reinstalado."
            else
                sudo dnf install -y dhcp-server && echo "[+] Instalado."
            fi ;;
        2)
            echo "--- Estado ---"
            systemctl is-active --quiet dhcpd && echo "Activo" || echo "Inactivo" ;;
        
            read -p "IP Inicial (Gateway/Servidor): " START
            read -p "IP Final: " END
            
            if validate_ip $START && validate_ip $END && compare_ips $START $END; then
           
                MASK=$(calculate_mask $START)
                
          
                sudo ip addr flush dev enp0s3 2>/dev/null
                sudo ip addr add $START/24 dev enp0s3 2>/dev/null
                
              
                while true; do
                    read -p "Ingrese la duración de la sesión (Segundos): " LEASE_TIME
                    if [[ $LEASE_TIME =~ ^[0-9]+$ ]]; then
                        break
                    else
                        echo "[X] Error: Solo se permiten números enteros."
                    fi
                done
        
                NET_BASE=$(echo $START | cut -d'.' -f1-3)
                NEXT_IP=$(echo $START | awk -F. '{print $1"."$2"."$3"."($4+1)}')
                
             
                sudo tee /etc/dhcp/dhcpd.conf <<EOF
subnet ${NET_BASE}.0 netmask $MASK {
    range $NEXT_IP $END;
    option routers $START;
    option domain-name-servers 192.168.100.10;
    default-lease-time $LEASE_TIME;
    max-lease-time $LEASE_TIME;
}
EOF
                sudo systemctl restart dhcpd && echo "[+] Configuración aplicada exitosamente."
            else
                echo "[X] Error: IPs inválidas o rango incoherente."
            fi ;;

        4)
            echo "--- Leases ---"
            grep "lease" /var/lib/dhcpd/dhcpd.leases 2>/dev/null || echo "Sin leases." ;;
        5) uninstall_dhcp ;;
        6) exit ;;
    esac
done
