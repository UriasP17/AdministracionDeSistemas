#!/bin/bash

# Colores para la interfaz
C_ERROR='\033[0;31m'
C_EXITO='\033[0;32m'
C_INFO='\033[0;36m'
C_TITULO='\033[1;33m'
C_RESET='\033[0m'

preparar_entorno_ftp() {
    echo -e "${C_INFO}[*] Configurando servidor VSFTPD...${C_RESET}"
    sudo dnf install -y vsftpd util-linux acl &>/dev/null

    cat <<EOF | sudo tee /etc/vsftpd/vsftpd.conf > /dev/null
anonymous_enable=YES
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES
check_shell=NO
anon_root=/srv/ftp/anonymous
no_anon_password=YES
anon_world_readable_only=YES
anon_mkdir_write_enable=NO
anon_upload_enable=NO
anon_other_write_enable=NO
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40010
listen=NO
listen_ipv6=YES
pam_service_name=vsftpd
EOF

    sudo mkdir -p /srv/ftp/{grupos/reprobados,grupos/recursadores,publico,anonymous/general,users}
    
    sudo chown ftp:ftp /srv/ftp/anonymous
    sudo chmod 555 /srv/ftp/anonymous

    # Sincronización automática de carpeta general para anónimo
    if ! grep -q "/srv/ftp/publico /srv/ftp/anonymous/general" /etc/fstab; then
        echo "/srv/ftp/publico /srv/ftp/anonymous/general none bind,ro 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi
    sudo mount -a

    sudo groupadd -f reprobados
    sudo groupadd -f recursadores
    sudo groupadd -f grupo-ftp

    sudo chown root:grupo-ftp /srv/ftp/publico
    sudo chmod 775 /srv/ftp/publico
    
    sudo setfacl -R -m g:grupo-ftp:rwx /srv/ftp/publico
    sudo setfacl -R -d -m g:grupo-ftp:rwx /srv/ftp/publico

    sudo firewall-cmd --permanent --add-service=ftp &>/dev/null
    sudo firewall-cmd --permanent --add-port=40000-40010/tcp &>/dev/null
    sudo firewall-cmd --reload &>/dev/null

    sudo setsebool -P ftpd_full_access on &>/dev/null
    sudo setsebool -P tftp_home_dir on &>/dev/null
    
    if ! grep -q "/sbin/nologin" /etc/shells; then
        echo "/sbin/nologin" | sudo tee -a /etc/shells > /dev/null
    fi

    sudo systemctl restart vsftpd
    sudo systemctl enable vsftpd &>/dev/null
    echo -e "${C_EXITO}[✓] Servidor FTP configurado correctamente.${C_RESET}"
}

establecer_puntos_montaje() {
    local usuario=$1
    local grupo=$2
    local home_dir="/home/$usuario"

    sudo mkdir -p "$home_dir/general" "$home_dir/$grupo" "$home_dir/$usuario"

    sudo umount "$home_dir/general" 2>/dev/null
    sudo umount "$home_dir/reprobados" 2>/dev/null
    sudo umount "$home_dir/recursadores" 2>/dev/null

    # Sincronización automática de carpetas para el usuario (temporal)
    sudo mount --bind /srv/ftp/publico "$home_dir/general"
    sudo mount --bind /srv/ftp/grupos/"$grupo" "$home_dir/$grupo"

    sudo chown "$usuario":"$grupo" "$home_dir/$usuario"
    sudo chmod 700 "$home_dir/$usuario"

    sudo chown root:"$grupo" /srv/ftp/grupos/"$grupo"
    sudo chmod 775 /srv/ftp/grupos/"$grupo"
    sudo setfacl -R -m g:"$grupo":rwx /srv/ftp/grupos/"$grupo"
    sudo setfacl -R -d -m g:"$grupo":rwx /srv/ftp/grupos/"$grupo"
}

dar_alta_usuario() {
    local user=$1
    local pass=$2
    local group=$3

    if [[ -z "$user" || -z "$pass" ]]; then
        echo -e "${C_ERROR}[!] Error: Usuario y contraseña son obligatorios.${C_RESET}"
        return
    fi

    if id "$user" &>/dev/null; then
        echo -e "${C_ERROR}[!] Error: El usuario '$user' ya existe en el sistema.${C_RESET}"
        return
    fi

    sudo useradd -m -g grupo-ftp -G "$group" -s /sbin/nologin "$user"
    echo "$user:$pass" | sudo chpasswd

    establecer_puntos_montaje "$user" "$group"
    
    # Hacer que las carpetas del usuario resistan reinicios del servidor
    if ! grep -q "/srv/ftp/publico /home/$user/general" /etc/fstab; then
        echo "/srv/ftp/publico /home/$user/general none bind 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi
    if ! grep -q "/srv/ftp/grupos/$group /home/$user/$group" /etc/fstab; then
        echo "/srv/ftp/grupos/$group /home/$user/$group none bind 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi
    
    echo -e "${C_EXITO}[✓] Usuario '$user' creado y configurado en el grupo '$group'.${C_RESET}"
}

mover_usuario_grupo() {
    local user=$1
    local n_group=$2

    if ! id "$user" &>/dev/null; then
        echo -e "${C_ERROR}[!] Error: El usuario '$user' no existe.${C_RESET}"
        return
    fi

    sudo usermod -G "$n_group" "$user"
    
    sudo umount "/home/$user/reprobados" 2>/dev/null
    sudo umount "/home/$user/recursadores" 2>/dev/null
    sudo rm -rf "/home/$user/reprobados" "/home/$user/recursadores"

    # Actualizar fstab para que no monte la carpeta vieja al reiniciar
    sudo sed -i "/\/home\/$user\/reprobados/d" /etc/fstab
    sudo sed -i "/\/home\/$user\/recursadores/d" /etc/fstab
    echo "/srv/ftp/grupos/$n_group /home/$user/$n_group none bind 0 0" | sudo tee -a /etc/fstab > /dev/null

    establecer_puntos_montaje "$user" "$n_group"
    echo -e "${C_EXITO}[✓] Usuario '$user' movido al grupo '$n_group'.${C_RESET}"
}

eliminar_usuario() {
    local user=$1

    if ! id "$user" &>/dev/null; then
        echo -e "${C_ERROR}[!] Error: El usuario '$user' no existe.${C_RESET}"
        return
    fi

    sudo umount "/home/$user/general" 2>/dev/null
    sudo umount "/home/$user/reprobados" 2>/dev/null
    sudo umount "/home/$user/recursadores" 2>/dev/null

    # Limpiar el rastro en fstab
    sudo sed -i "/\/home\/$user\//d" /etc/fstab

    sudo userdel -r "$user" &>/dev/null
    echo -e "${C_EXITO}[✓] Usuario '$user' eliminado por completo del servidor.${C_RESET}"
}

mostrar_resumen_usuarios() {
    echo -e "\n${C_TITULO}=== LISTADO DE USUARIOS FTP ===${C_RESET}"
    printf "${C_INFO}%-20s | %-15s${C_RESET}\n" "NOMBRE DE USUARIO" "GRUPO ASIGNADO"
    echo "----------------------------------------"
    
    GID_FTP=$(grep "^grupo-ftp:" /etc/group | cut -d: -f3)
    if [ -z "$GID_FTP" ]; then
        echo -e "${C_ERROR}No se encontró el grupo principal FTP.${C_RESET}"
        return
    fi
    
    users_list=$(awk -F: -v gid="$GID_FTP" '$4 == gid {print $1}' /etc/passwd)
    
    if [ -z "$users_list" ]; then
        echo "No hay usuarios registrados actualmente."
    else
        for u in $users_list; do
            if id "$u" | grep -q "reprobados"; then 
                gr="reprobados"
            elif id "$u" | grep -q "recursadores"; then 
                gr="recursadores"
            else 
                gr="Sin asignar"
            fi
            printf "%-20s | %-15s\n" "$u" "$gr"
        done
    fi
    echo "----------------------------------------"
}

diagnostico_sistema() {
    echo -e "\n${C_TITULO}=== ESTADO DEL SERVIDOR FTP ===${C_RESET}"
    
    if systemctl is-active --quiet vsftpd; then
        echo -e "Servicio VSFTPD: ${C_EXITO}ACTIVO Y CORRIENDO${C_RESET}"
    else
        echo -e "Servicio VSFTPD: ${C_ERROR}INACTIVO / DETENIDO${C_RESET}"
    fi

    ip_addr=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -n 1)
    echo -e "Dirección IP: ${C_INFO}$ip_addr${C_RESET}"
    
    echo -n "Acceso Anónimo (Público): "
    if mountpoint -q /srv/ftp/anonymous/general; then
        echo -e "${C_EXITO}MONTADO CORRECTAMENTE${C_RESET}"
    else
        echo -e "${C_ERROR}ERROR DE MONTAJE${C_RESET}"
    fi
}

menu_principal() {
    if ! systemctl is-active --quiet vsftpd; then
        preparar_entorno_ftp
    fi

    while true; do
        echo -e "\n${C_TITULO}======================================="
        echo "      PANEL DE ADMINISTRACIÓN FTP"
        echo -e "=======================================${C_RESET}"
        echo -e " [1] ${C_INFO}Crear nuevos usuarios${C_RESET}"
        echo -e " [2] ${C_INFO}Ver lista de usuarios${C_RESET}"
        echo -e " [3] ${C_INFO}Cambiar grupo a un usuario${C_RESET}"
        echo -e " [4] ${C_INFO}Eliminar usuario del sistema${C_RESET}"
        echo -e " [5] ${C_INFO}Estado y Diagnóstico${C_RESET}"
        echo -e " [6] ${C_INFO}Forzar reinstalación/reseteo${C_RESET}"
        echo -e " [0] ${C_ERROR}Salir del panel${C_RESET}"
        echo "---------------------------------------"
        read -p "Elige una opción -> " opt

        case $opt in
            1)
                echo -e "\n${C_TITULO}--- CREACIÓN DE USUARIOS ---${C_RESET}"
                read -p "¿Cuántos usuarios deseas registrar?: " total
                if [[ ! "$total" =~ ^[0-9]+$ ]] || [[ "$total" -le 0 ]]; then
                    echo -e "${C_ERROR}Cantidad inválida.${C_RESET}"
                else
                    for (( i=1; i<=$total; i++ )); do
                        echo -e "\nUsuario [$i/$total]:"
                        read -p "  Nombre de usuario: " u_name
                        
                        while true; do
                            read -s -p "  Contraseña: " u_pass; echo
                            if [ -n "$u_pass" ]; then break; fi
                            echo -e "${C_ERROR}  La contraseña no puede estar vacía. Intenta de nuevo.${C_RESET}"
                        done

                        read -p "  Grupo (1: reprobados | 2: recursadores): " u_group
                        [[ "$u_group" == "1" ]] && grp="reprobados" || grp="recursadores"
                        dar_alta_usuario "$u_name" "$u_pass" "$grp"
                    done
                fi
                ;;
            2) mostrar_resumen_usuarios ;;
            3)
                echo -e "\n${C_TITULO}--- MODIFICAR GRUPO ---${C_RESET}"
                read -p "Nombre del usuario a modificar: " u_name
                read -p "Nuevo Grupo (1: reprobados | 2: recursadores): " u_group
                [[ "$u_group" == "1" ]] && grp="reprobados" || grp="recursadores"
                mover_usuario_grupo "$u_name" "$grp"
                ;;
            4)
                echo -e "\n${C_TITULO}--- ELIMINAR USUARIO ---${C_RESET}"
                read -p "Nombre del usuario que deseas borrar: " u_name
                read -p "¿Estás seguro de eliminar a '$u_name'? (s/n): " confirmar
                if [[ "$confirmar" == "s" || "$confirmar" == "S" ]]; then
                    eliminar_usuario "$u_name"
                else
                    echo "Operación cancelada."
                fi
                ;;
            5) diagnostico_sistema ;;
            6) preparar_entorno_ftp ;;
            0) echo -e "${C_INFO}Saliendo...${C_RESET}"; exit 0 ;;
            *) echo -e "${C_ERROR}Opción no válida. Intenta de nuevo.${C_RESET}" ;;
        esac
        echo ""
        read -p "Presiona ENTER para volver al menú principal..."
    done
}

menu_principal
