#!/bin/bash

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
    sudo setfacl -R -m u:ftp:rx /srv/ftp/publico
    sudo setfacl -R -d -m u:ftp:rx /srv/ftp/publico

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
    echo -e "${C_EXITO}[v] Servidor FTP configurado correctamente.${C_RESET}"
}

establecer_puntos_montaje() {
    local usuario=$1
    local grupo=$2
    local home_dir="/home/$usuario"

    sudo mkdir -p "$home_dir/general" "$home_dir/$grupo" "$home_dir/$usuario"

    sudo umount "$home_dir/general" 2>/dev/null
    sudo umount "$home_dir/reprobados" 2>/dev/null
    sudo umount "$home_dir/recursadores" 2>/dev/null

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
        echo -e "${C_ERROR}[!] Error: Usuario y contrasena obligatorios.${C_RESET}"
        return
    fi

    if id "$user" &>/dev/null; then
        echo -e "${C_ERROR}[!] Error: El usuario '$user' ya existe.${C_RESET}"
        return
    fi

    sudo useradd -m -g grupo-ftp -G "$group" -s /sbin/nologin "$user"
    echo "$user:$pass" | sudo chpasswd

    establecer_puntos_montaje "$user" "$group"
    
    if ! grep -q "/srv/ftp/publico /home/$user/general" /etc/fstab; then
        echo "/srv/ftp/publico /home/$user/general none bind 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi
    if ! grep -q "/srv/ftp/grupos/$group /home/$user/$group" /etc/fstab; then
        echo "/srv/ftp/grupos/$group /home/$user/$group none bind 0 0" | sudo tee -a /etc/fstab > /dev/null
    fi
    
    echo -e "${C_EXITO}[v] Usuario '$user' creado en el grupo '$group'.${C_RESET}"
}

mover_usuario_grupo() {
    local user=$1
    local n_group=$2

    if ! id "$user" &>/dev/null; then
        echo -e "${C_ERROR}[!] Error: Usuario no existe.${C_RESET}"
        return
    fi

    local grupo_actual=""
    if id "$user" | grep -q "reprobados"; then grupo_actual="reprobados"; fi
    if id "$user" | grep -q "recursadores"; then grupo_actual="recursadores"; fi

    if [[ "$grupo_actual" == "$n_group" ]]; then
        echo -e "${C_ERROR}[!] Error: El usuario ya esta en el grupo $n_group.${C_RESET}"
        return
    fi

    sudo usermod -G "$n_group" "$user"
    
    sudo umount "/home/$user/reprobados" 2>/dev/null
    sudo umount "/home/$user/recursadores" 2>/dev/null
    sudo rm -rf "/home/$user/reprobados" "/home/$user/recursadores"

    sudo sed -i "/\/home\/$user\/reprobados/d" /etc/fstab
    sudo sed -i "/\/home\/$user\/recursadores/d" /etc/fstab
    echo "/srv/ftp/grupos/$n_group /home/$user/$n_group none bind 0 0" | sudo tee -a /etc/fstab > /dev/null

    establecer_puntos_montaje "$user" "$n_group"
    echo -e "${C_EXITO}[v] Usuario '$user' movido al grupo '$n_group'.${C_RESET}"
}

eliminar_usuario() {
    local user=$1

    if ! id "$user" &>/dev/null; then
        echo -e "${C_ERROR}[!] Error: Usuario no existe.${C_RESET}"
        return
    fi

    sudo umount "/home/$user/general" 2>/dev/null
    sudo umount "/home/$user/reprobados" 2>/dev/null
    sudo umount "/home/$user/recursadores" 2>/dev/null

    sudo sed -i "/\/home\/$user\//d" /etc/fstab

    sudo userdel -r "$user" &>/dev/null
    echo -e "${C_EXITO}[v] Usuario '$user' eliminado.${C_RESET}"
}

mostrar_resumen_usuarios() {
    echo -e "\n${C_TITULO}=== LISTADO DE USUARIOS FTP ===${C_RESET}"
    printf "${C_INFO}%-20s | %-15s${C_RESET}\n" "NOMBRE DE USUARIO" "GRUPO ASIGNADO"
    echo "----------------------------------------"
    
    GID_FTP=$(grep "^grupo-ftp:" /etc/group | cut -d: -f3)
    if [ -z "$GID_FTP" ]; then
        echo -e "${C_ERROR}No se encontro el grupo FTP.${C_RESET}"
        return
    fi
    
    users_list=$(awk -F: -v gid="$GID_FTP" '$4 == gid {print $1}' /etc/passwd)
    
    if [ -z "$users_list" ]; then
        echo "No hay usuarios."
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

menu_principal() {
    if ! systemctl is-active --quiet vsftpd; then
        preparar_entorno_ftp
    fi

    while true; do
        clear
        echo -e "\n${C_TITULO}=== PANEL DE ADMINISTRACION FTP (FEDORA VSFTPD) ===${C_RESET}"
        echo -e " [1] ${C_INFO}Instalar componentes FTP${C_RESET}"
        echo -e " [2] ${C_INFO}Crear usuarios${C_RESET}"
        echo -e " [3] ${C_INFO}Cambiar grupo de usuario${C_RESET}"
        echo -e " [4] ${C_INFO}Eliminar usuario${C_RESET}"
        echo -e " [5] ${C_INFO}Ver usuarios registrados${C_RESET}"
        echo -e " [0] ${C_ERROR}Salir${C_RESET}"
        echo "---------------------------------------"
        read -p "Elige una opcion: " opt

        case $opt in
            1) preparar_entorno_ftp ;;
            2)
                echo -e "\n${C_TITULO}=== CREAR USUARIOS FTP ===${C_RESET}"
                read -p "Cuantos usuarios deseas crear?: " total
                if [[ ! "$total" =~ ^[0-9]+$ ]] || [[ "$total" -le 0 ]]; then
                    echo -e "${C_ERROR}Cantidad invalida.${C_RESET}"
                else
                    for (( i=1; i<=$total; i++ )); do
                        echo ""
                        read -p "Nombre de usuario $i: " u_name
                        while true; do
                            read -s -p "Contrasena: " u_pass; echo
                            if [ -n "$u_pass" ]; then break; fi
                            echo -e "${C_ERROR}La contrasena no puede estar vacia.${C_RESET}"
                        done
                        read -p "Grupo (1: reprobados | 2: recursadores): " u_group
                        [[ "$u_group" == "1" ]] && grp="reprobados" || grp="recursadores"
                        dar_alta_usuario "$u_name" "$u_pass" "$grp"
                    done
                fi
                ;;
            3)
                echo -e "\n${C_TITULO}=== CAMBIAR USUARIO DE GRUPO FTP ===${C_RESET}"
                read -p "Nombre del usuario: " u_name
                read -p "Nuevo Grupo (1: reprobados | 2: recursadores): " u_group
                [[ "$u_group" == "1" ]] && grp="reprobados" || grp="recursadores"
                mover_usuario_grupo "$u_name" "$grp"
                ;;
            4)
                echo -e "\n${C_TITULO}=== ELIMINAR USUARIOS FTP ===${C_RESET}"
                read -p "Nombre del usuario a eliminar: " u_name
                read -p "Estas seguro de eliminar a '$u_name'? Todo su FTP se borrara (s/n): " confirmar
                if [[ "$confirmar" == "s" || "$confirmar" == "S" ]]; then
                    eliminar_usuario "$u_name"
                fi
                ;;
            5) mostrar_resumen_usuarios ;;
            0) exit 0 ;;
            *) echo -e "${C_ERROR}Opcion no valida.${C_RESET}" ;;
        esac
        echo ""
        read -p "Presiona ENTER para continuar..."
    done
}

menu_principal
